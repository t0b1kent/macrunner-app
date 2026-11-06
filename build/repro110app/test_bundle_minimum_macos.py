import importlib.util
import pathlib
import plistlib
import struct
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "bundle_minimum_macos", pathlib.Path(__file__).with_name("bundle_minimum_macos.py")
)
minimum = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(minimum)


def packed(major, minor=0, patch=0):
    return major << 16 | minor << 8 | patch


def thin(commands, endian="<", wide=True):
    magic = 0xFEEDFACF if wide else 0xFEEDFACE
    header = struct.pack(endian + "7I", magic, 0x100000C, 0, 2, len(commands), sum(map(len, commands)), 0)
    return header + (b"\0" * 4 if wide else b"") + b"".join(commands)


def build(version, platform=1, sdk=packed(99), endian="<"):
    return struct.pack(endian + "6I", 0x32, 24, platform, version, sdk, 0)


def universal(slices, endian=">", wide=False):
    stride = 32 if wide else 20
    cursor = 8 + stride * len(slices)
    entries = []
    for data in slices:
        if wide:
            entries.append(struct.pack(endian + "IIQQII", 0x100000C, 0, cursor, len(data), 0, 0))
        else:
            entries.append(struct.pack(endian + "5I", 0x100000C, 0, cursor, len(data), 0))
        cursor += len(data)
    return struct.pack(endian + "II", 0xCAFEBABF if wide else 0xCAFEBABE, len(slices)) + b"".join(entries + slices)


class MinimumMacOSTests(unittest.TestCase):
    def test_build_version_uses_minimum_not_sdk(self):
        self.assertEqual(minimum.mach_o_minimums(thin([build(packed(14, 2, 1))])), [(14, 2, 1)])

    def test_legacy_macos_and_big_endian_header(self):
        command = struct.pack(">4I", 0x24, 16, packed(10, 13), packed(99))
        self.assertEqual(minimum.mach_o_minimums(thin([command], ">", False)), [(10, 13, 0)])

    def test_ignores_other_platforms_and_dylib_versions(self):
        dylib = struct.pack("<6I", 0xD, 24, 24, 0, packed(90), packed(90))
        data = thin([build(packed(99), platform=2), build(packed(98), platform=6), dylib])
        self.assertEqual(minimum.mach_o_minimums(data), [])

    def test_all_universal_layouts_include_every_slice(self):
        slices = [thin([build(packed(14))]), thin([build(packed(27))])]
        for endian in ("<", ">"):
            for wide in (False, True):
                with self.subTest(endian=endian, wide=wide):
                    self.assertEqual(minimum.mach_o_minimums(universal(slices, endian, wide)), [(14, 0, 0), (27, 0, 0)])

    def test_non_macho_is_ignored(self):
        self.assertEqual(minimum.mach_o_minimums(b"MZfake Windows executable"), [])

    def test_truncated_macho_and_fat_fail_closed(self):
        examples = [b"\xcf\xfa\xed\xfe", struct.pack(">II", 0xCAFEBABE, 2), thin([build(packed(14))])[:-1]]
        for data in examples:
            with self.subTest(data=data[:8]), self.assertRaises(ValueError):
                minimum.mach_o_minimums(data)

    def test_slice_cannot_read_past_its_own_boundary(self):
        data = bytearray(universal([thin([build(packed(27))]), thin([build(packed(14))])]))
        struct.pack_into(">I", data, 20, 32)  # First slice size ends before its load command.
        with self.assertRaises(ValueError):
            minimum.mach_o_minimums(bytes(data))

    def test_scan_preserves_baseline_and_apply_preserves_other_metadata(self):
        with tempfile.TemporaryDirectory() as folder:
            app = pathlib.Path(folder) / "Example.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            info = app / "Contents/Info.plist"
            info.write_bytes(plistlib.dumps({"LSMinimumSystemVersion": "14.0", "Keep": "value"}))
            exe = app / "Contents/MacOS/Example"
            exe.write_bytes(thin([build(packed(11))]))
            self.assertEqual(minimum.scan_bundle(app)[0], (14, 0, 0))
            exe.write_bytes(thin([build(packed(27))]))
            version, targets = minimum.scan_bundle(app)
            self.assertEqual(version, (27, 0, 0))
            self.assertEqual(targets, {"Contents/MacOS/Example": version})
            self.assertEqual(plistlib.loads(info.read_bytes())["LSMinimumSystemVersion"], "14.0")
            minimum.apply_minimum(app, version)
            self.assertEqual(plistlib.loads(info.read_bytes()), {"LSMinimumSystemVersion": "27.0", "Keep": "value"})

    def test_binary_plist_format_survives_apply(self):
        with tempfile.TemporaryDirectory() as folder:
            app = pathlib.Path(folder)
            (app / "Contents").mkdir()
            info = app / "Contents/Info.plist"
            info.write_bytes(plistlib.dumps({"Keep": True}, fmt=plistlib.FMT_BINARY))
            minimum.apply_minimum(app, (14, 2, 1))
            self.assertTrue(info.read_bytes().startswith(b"bplist"))
            self.assertEqual(plistlib.loads(info.read_bytes())["LSMinimumSystemVersion"], "14.2.1")


if __name__ == "__main__":
    unittest.main()
