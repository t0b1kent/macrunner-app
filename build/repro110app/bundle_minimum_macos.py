#!/usr/bin/env python3
"""Derive a bundle's macOS deployment floor before code signing.

Only macOS deployment load commands count; dylib compatibility versions and
SDK versions do not. The default invocation is read-only. --apply updates only
the root Info.plist and must run before the bundle is signed.
"""

from __future__ import annotations

import argparse
import json
import mmap
import pathlib
import plistlib
import struct

Version = tuple[int, int, int]
THIN = {
    b"\xce\xfa\xed\xfe": ("<", 28),
    b"\xfe\xed\xfa\xce": (">", 28),
    b"\xcf\xfa\xed\xfe": ("<", 32),
    b"\xfe\xed\xfa\xcf": (">", 32),
}
FAT = {
    b"\xca\xfe\xba\xbe": (">", 20, "I"),
    b"\xbe\xba\xfe\xca": ("<", 20, "I"),
    b"\xca\xfe\xba\xbf": (">", 32, "Q"),
    b"\xbf\xba\xfe\xca": ("<", 32, "Q"),
}


def version_string(version: Version) -> str:
    major, minor, patch = version
    return f"{major}.{minor}" + (f".{patch}" if patch else "")


def parse_version(text: str) -> Version:
    parts = text.split(".")
    if not 1 <= len(parts) <= 3 or not all(part.isdigit() for part in parts):
        raise ValueError(f"Invalid macOS version: {text}")
    values = tuple(int(part) for part in parts)
    return (values + (0, 0))[:3]


def _version(packed: int) -> Version:
    return packed >> 16, (packed >> 8) & 255, packed & 255


def mach_o_minimums(data: bytes | mmap.mmap) -> list[Version]:
    """Return all macOS deployment targets in a thin or universal Mach-O."""
    magic = data[:4]
    if magic not in THIN and magic not in FAT:
        return []

    def thin(start: int, size: int) -> list[Version]:
        if size < 4 or start < 0 or start + size > len(data):
            raise ValueError("Mach-O slice is out of bounds")
        layout = THIN.get(data[start : start + 4])
        if layout is None:
            raise ValueError("Universal binary contains a non-Mach-O slice")
        endian, header_size = layout
        if size < header_size:
            raise ValueError("Truncated Mach-O header")
        count, command_bytes = struct.unpack_from(endian + "II", data, start + 16)
        cursor = start + header_size
        command_end = cursor + command_bytes
        if command_end > start + size or count > command_bytes // 8:
            raise ValueError("Mach-O load commands exceed the slice")
        targets = []
        for _ in range(count):
            if cursor + 8 > command_end:
                raise ValueError("Truncated Mach-O load command")
            command, length = struct.unpack_from(endian + "II", data, cursor)
            if length < 8 or cursor + length > command_end:
                raise ValueError("Invalid Mach-O load command size")
            if command == 0x32:  # LC_BUILD_VERSION
                if length < 24:
                    raise ValueError("Truncated LC_BUILD_VERSION")
                platform, minimum = struct.unpack_from(endian + "II", data, cursor + 8)
                if platform == 1:  # PLATFORM_MACOS, not iOS or Catalyst
                    targets.append(_version(minimum))
            elif command == 0x24:  # LC_VERSION_MIN_MACOSX
                if length < 16:
                    raise ValueError("Truncated LC_VERSION_MIN_MACOSX")
                targets.append(_version(struct.unpack_from(endian + "I", data, cursor + 8)[0]))
            cursor += length
        if cursor != command_end:
            raise ValueError("Mach-O load command sizes do not match header")
        return targets

    if magic in THIN:
        return thin(0, len(data))
    endian, entry_size, offset_format = FAT[magic]
    if len(data) < 8:
        raise ValueError("Truncated universal binary header")
    count = struct.unpack_from(endian + "I", data, 4)[0]
    table_end = 8 + count * entry_size
    if count == 0 or table_end > len(data):
        raise ValueError("Invalid universal binary architecture table")
    targets = []
    for index in range(count):
        entry = 8 + index * entry_size
        start, size = struct.unpack_from(endian + offset_format * 2, data, entry + 8)
        if start < table_end:
            raise ValueError("Universal binary slice overlaps its header")
        targets.extend(thin(start, size))
    return targets


def scan_bundle(bundle: pathlib.Path, baseline: Version = (14, 0, 0)) -> tuple[Version, dict[str, Version]]:
    if not (bundle / "Contents/Info.plist").is_file():
        raise ValueError(f"Not an application bundle: {bundle}")
    targets = {}
    for path in sorted(bundle.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            if stream.read(4) not in THIN.keys() | FAT.keys():
                continue
            try:
                with mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
                    minimums = mach_o_minimums(data)
            except (ValueError, struct.error) as error:
                raise ValueError(f"{path.relative_to(bundle)}: {error}") from error
        if minimums:
            targets[str(path.relative_to(bundle))] = max(minimums)
    return max([baseline, *targets.values()]), targets


def apply_minimum(bundle: pathlib.Path, minimum: Version) -> None:
    path = bundle / "Contents/Info.plist"
    original = path.read_bytes()
    info = plistlib.loads(original)
    info["LSMinimumSystemVersion"] = version_string(minimum)
    format_ = plistlib.FMT_BINARY if original.startswith(b"bplist") else plistlib.FMT_XML
    path.write_bytes(plistlib.dumps(info, fmt=format_, sort_keys=False))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=pathlib.Path)
    parser.add_argument("--baseline", default="14.0")
    parser.add_argument("--apply", action="store_true", help="Update root Info.plist before signing")
    args = parser.parse_args()
    try:
        minimum, targets = scan_bundle(args.bundle, parse_version(args.baseline))
        if args.apply:
            apply_minimum(args.bundle, minimum)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(2, f"bundle minimum macOS: {error}\n")
    print(json.dumps({
        "minimum_macos": version_string(minimum),
        "mach_o_files_with_macos_target": len(targets),
        "floor_components": [path for path, version in targets.items() if version == minimum],
        "applied": args.apply,
    }))


if __name__ == "__main__":
    main()
