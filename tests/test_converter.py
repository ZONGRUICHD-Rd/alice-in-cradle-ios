#!/usr/bin/env python3
"""Unit tests for Mach-O ARM64 -> iOS 27 converter, plist templates, and shim manifest."""
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import build_launcher_ipa  # noqa: E402
import convert_alice  # noqa: E402
import make_icon  # noqa: E402


def build_synthetic_mac_arm64_macho(
    dylibs: list[str],
    *,
    use_legacy_min_macosx: bool = False,
    include_mmap_linkedit: bool = False,
) -> bytes:
    cmds = bytearray()
    ncmds = 0

    # __TEXT segment with 1 section starting at offset 0x1000
    text_sect = struct.pack(
        "<16s16sQQIIIIIIII",
        b"__text".ljust(16, b"\x00"),
        b"__TEXT".ljust(16, b"\x00"),
        0x100001000, 0x100, 0x1000, 2, 0, 0, 0, 0, 0, 0,
    )
    text_seg = struct.pack(
        "<II16sQQQQIIII",
        convert_alice.LC_SEGMENT_64, 72 + 80,
        b"__TEXT".ljust(16, b"\x00"),
        0x100000000, 0x2000, 0, 0x2000, 5, 5, 1, 0,
    ) + text_sect
    cmds.extend(text_seg)
    ncmds += 1

    # __LINKEDIT segment at offset 0x2000, size 0x100
    link_seg = struct.pack(
        "<II16sQQQQIIII",
        convert_alice.LC_SEGMENT_64, 72,
        b"__LINKEDIT".ljust(16, b"\x00"),
        0x100002000, 0x1000, 0x2000, 0x100, 1, 1, 0, 0,
    )
    cmds.extend(link_seg)
    ncmds += 1

    if use_legacy_min_macosx:
        cmds.extend(struct.pack("<IIII", convert_alice.LC_VERSION_MIN_MACOSX, 16, 11 << 16, 14 << 16))
        ncmds += 1
    else:
        cmds.extend(struct.pack("<IIIIII", convert_alice.LC_BUILD_VERSION, 24, 1, 11 << 16, 14 << 16, 0))
        ncmds += 1

    for d in dylibs:
        raw = d.encode("utf-8") + b"\x00"
        total = (24 + len(raw) + 7) & ~7
        cmds.extend(struct.pack("<IIIIII", convert_alice.LC_LOAD_DYLIB, total, 24, 2, 0x10000, 0x10000))
        cmds.extend(raw + b"\x00" * (total - 24 - len(raw)))
        ncmds += 1

    header = struct.pack(
        "<IIIIIIII",
        convert_alice.MH_MAGIC_64,
        convert_alice.CPU_TYPE_ARM64,
        convert_alice.CPU_SUBTYPE_ARM64_ALL,
        2,  # MH_EXECUTE
        ncmds,
        len(cmds),
        0,
        0,
    )
    buf = bytearray(0x2100)
    buf[0:32] = header
    buf[32 : 32 + len(cmds)] = cmds
    if include_mmap_linkedit:
        symtab = b"\x00_printf\x00_mmap\x00_munmap\x00_mmap\x00"
        buf[0x2000 : 0x2000 + len(symtab)] = symtab
    return bytes(buf)


def wrap_universal(arm64_slice: bytes) -> bytes:
    x86_dummy = b"\xcf\xfa\xed\xfe" + b"\x00" * 60
    off_x86 = 0x1000
    off_arm = 0x2000
    fat_hdr = struct.pack(">II", convert_alice.FAT_MAGIC, 2)
    arch_x86 = struct.pack(">IIIII", 0x01000007, 3, off_x86, len(x86_dummy), 12)
    arch_arm = struct.pack(">IIIII", convert_alice.CPU_TYPE_ARM64, 0, off_arm, len(arm64_slice), 12)
    out = bytearray(off_arm + len(arm64_slice))
    out[0:8] = fat_hdr
    out[8:28] = arch_x86
    out[28:48] = arch_arm
    out[off_x86 : off_x86 + len(x86_dummy)] = x86_dummy
    out[off_arm : off_arm + len(arm64_slice)] = arm64_slice
    return bytes(out)


class ConverterTests(unittest.TestCase):
    def test_universal_extract_and_rewrite_to_ios27(self) -> None:
        mac_bin = build_synthetic_mac_arm64_macho(
            [
                "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
                "/System/Library/Frameworks/CoreAudio.framework/Versions/A/CoreAudio",
                "/System/Library/Frameworks/AudioUnit.framework/Versions/A/AudioUnit",
                "/usr/lib/libSystem.B.dylib",
                "@executable_path/../Frameworks/UnityPlayer.dylib",
            ]
        )
        universal = wrap_universal(mac_bin)
        converted = convert_alice.convert_macho_bytes(universal, add_launcher_rpaths=True)

        magic, cpu, _, _, ncmds, sizeofcmds, _, _ = struct.unpack_from("<IIIIIIII", converted, 0)
        self.assertEqual(magic, convert_alice.MH_MAGIC_64)
        self.assertEqual(cpu, convert_alice.CPU_TYPE_ARM64)

        found_ios27 = False
        dylibs = []
        rpaths = []
        pos = 32
        for _ in range(ncmds):
            cmd, sz = struct.unpack_from("<II", converted, pos)
            if cmd == convert_alice.LC_BUILD_VERSION:
                plat, minos, sdk = struct.unpack_from("<III", converted, pos + 8)
                self.assertEqual(plat, convert_alice.PLATFORM_IOS)
                self.assertEqual(minos, 17 << 16)
                self.assertEqual(sdk, 27 << 16)
                found_ios27 = True
            elif cmd == convert_alice.LC_LOAD_DYLIB:
                off = struct.unpack_from("<I", converted, pos + 8)[0]
                dylibs.append(converted[pos + off : pos + sz].split(b"\x00", 1)[0].decode("utf-8"))
            elif cmd == convert_alice.LC_RPATH:
                off = struct.unpack_from("<I", converted, pos + 8)[0]
                rpaths.append(converted[pos + off : pos + sz].split(b"\x00", 1)[0].decode("utf-8"))
            pos += sz

        self.assertTrue(found_ios27)
        self.assertIn("@rpath/libShim_AppKit.dylib", dylibs)
        self.assertIn("@rpath/libShim_CoreAudio.dylib", dylibs)
        self.assertIn("@rpath/libShim_AudioUnit.dylib", dylibs)
        self.assertIn("@rpath/libShim_libSystem.dylib", dylibs)
        self.assertIn("@executable_path/Mac/Contents/Frameworks/UnityPlayer.dylib", dylibs)
        self.assertIn("@executable_path/Frameworks", rpaths)

    def test_legacy_min_macosx_upgrade_and_mono_smmp_alias(self) -> None:
        mac_mono = build_synthetic_mac_arm64_macho(
            ["/usr/lib/libSystem.B.dylib"],
            use_legacy_min_macosx=True,
            include_mmap_linkedit=True,
        )
        converted = convert_alice.convert_macho_bytes(mac_mono, alias_mono_mmap=True)
        linkedit = converted[0x2000:0x2100]
        self.assertEqual(linkedit.count(b"\x00_smmp\x00"), 2)
        self.assertNotIn(b"\x00_mmap\x00", linkedit)
        # Ensure _munmap was not touched
        self.assertIn(b"\x00_munmap\x00", linkedit)

    def test_all_shim_sources_and_plists_exist_and_valid(self) -> None:
        self.assertGreaterEqual(len(build_launcher_ipa.SHIM_SPECS), 13)
        for spec in build_launcher_ipa.SHIM_SPECS:
            for src in spec["sources"]:
                self.assertTrue((ROOT / src).is_file(), f"Missing shim source: {src}")

        for plist_rel in [
            "launcher/Resources/Info-launcher.plist",
            "shims/resources/Info-game-ios.plist",
            "shims/resources/entitlements-ios.plist",
        ]:
            data = plistlib.loads((ROOT / plist_rel).read_bytes())
            self.assertIsInstance(data, dict)

    def test_procedural_icon_png(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "icon.png"
            make_icon.write_png(out, 64, 64, make_icon.render_icon(64))
            raw = out.read_bytes()
            self.assertTrue(raw.startswith(b"\x89PNG\r\n\x1a\n"))


if __name__ == "__main__":
    unittest.main()
