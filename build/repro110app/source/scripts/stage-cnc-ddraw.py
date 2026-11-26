#!/usr/bin/env python3
"""Prepare the reviewed cnc-ddraw payload for the MacRunner release build."""

import argparse
import hashlib
import json
import shutil
import tempfile
import zipfile
from pathlib import Path, PurePosixPath


VERSION = "7.1.0.0"
SOURCE = "https://github.com/FunkyFr3sh/cnc-ddraw"
ARCHIVE_SHA256 = "0b13ab89a64c9918189b1dadd449ef6ed3cb3b7b19cabd96d8adbd95505bb908"
LICENSE_SHA256 = "a705144535bbfccc05e8310c4f8ab5f0b6f0ec2c9371b76ca5a522cf90e031f5"
GRAPHICS = Path("engine/graphics/i386-windows/cnc-ddraw")
LICENSE = Path("licenses/cnc-ddraw-MIT.txt")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def configure(data: bytes) -> bytes:
    options = {b"windowed": b"true", b"fullscreen": b"true", b"maintas": b"true", b"renderer": b"opengl"}
    section = b""
    configured = set()
    lines = []
    for line in data.splitlines(keepends=True):
        if line.startswith(b"["):
            section = line.strip()
        key = line.partition(b"=")[0]
        if section == b"[ddraw]" and key in options:
            line = key + b"=" + options[key] + (b"\r\n" if line.endswith(b"\r\n") else b"\n")
            configured.add(key)
        lines.append(line)
    if configured != options.keys():
        raise ValueError("The upstream general configuration is missing required settings")
    return b"".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("license", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if digest(args.archive) != ARCHIVE_SHA256 or digest(args.license) != LICENSE_SHA256:
        parser.error("the source archive or MIT license checksum differs from the reviewed upstream release")
    if args.output.exists():
        parser.error("choose a new output directory")
    resources_parent = args.output.absolute().parent
    with tempfile.TemporaryDirectory(dir=resources_parent) as temp:
        staged = Path(temp) / "payload"
        resources = staged / "resources"
        graphics = resources / GRAPHICS
        graphics.mkdir(parents=True)
        with zipfile.ZipFile(args.archive) as archive:
            (graphics / "ddraw.dll").write_bytes(archive.read("ddraw.dll"))
            (graphics / "ddraw.ini").write_bytes(configure(archive.read("ddraw.ini")))
            for info in archive.infolist():
                path = PurePosixPath(info.filename)
                if path.parts[0] != "Shaders" or info.is_dir():
                    continue
                if ".." in path.parts:
                    raise ValueError(f"Unexpected archive path: {path}")
                destination = graphics / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(archive.read(info))
        license = resources / LICENSE
        license.parent.mkdir()
        shutil.copyfile(args.license, license)
        component = {
            "name": "cnc-ddraw",
            "version": VERSION,
            "architecture": "i386",
            "source": SOURCE,
            "archive": f"{SOURCE}/releases/download/v{VERSION}/cnc-ddraw.zip",
            "archiveSHA256": ARCHIVE_SHA256,
            "license": "MIT",
            "licensePath": LICENSE.as_posix(),
            "files": {
                p.relative_to(resources).as_posix(): digest(p)
                for p in sorted(resources.rglob("*")) if p.is_file()
            },
        }
        (staged / "component.json").write_text(json.dumps(component, indent=2) + "\n", encoding="utf-8")
        staged.rename(args.output)


if __name__ == "__main__":
    main()
