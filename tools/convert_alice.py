#!/usr/bin/env python3
"""Desktop / CI macOS-to-iOS 27 Mach-O converter for AliceInCradle.app.

Mirrors launcher/Sources/MachOConverter.m so you can either:
  - Convert AliceInCradle.app directly on a Mac into an unsigned iOS 27 IPA, OR
  - Unit-test the Mach-O rewriting & dependency-mapping logic cross-platform.
"""
from pathlib import Path
import argparse
import plistlib
import re
import shutil
import struct
import zipfile

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64_ALL = 0

LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_LAZY_LOAD_DYLIB = 0x20
LC_RPATH = 0x8000001C
LC_VERSION_MIN_MACOSX = 0x24
LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2

SHIM_MAP = {
    "AppKit": "@rpath/libShim_AppKit.dylib",
    "Cocoa": "@rpath/libShim_AppKit.dylib",
    "CoreAudio": "@rpath/libShim_CoreAudio.dylib",
    "AudioUnit": "@rpath/libShim_AudioUnit.dylib",
    "CoreVideo": "@rpath/libShim_CoreVideo.dylib",
    "CoreGraphics": "@rpath/libShim_CoreGraphics.dylib",
    "Carbon": "@rpath/libShim_Carbon.dylib",
    "CoreServices": "@rpath/libShim_CoreServices.dylib",
    "IOKit": "@rpath/libShim_IOKit.dylib",
    "Metal": "@rpath/libShim_Metal.dylib",
    "Security": "@rpath/libShim_Security.dylib",
    "SystemConfiguration": "@rpath/libShim_SystemConfiguration.dylib",
    "Foundation": "@rpath/libShim_Foundation.dylib",
}


def rewrite_dylib_path(orig: str) -> str:
    if orig.startswith("@executable_path/../"):
        return "@executable_path/Mac/Contents/" + orig[len("@executable_path/../"):]
    if orig == "/usr/lib/libSystem.B.dylib":
        return "@rpath/libShim_libSystem.dylib"
    if orig.startswith("/System/Library/Frameworks/"):
        rest = orig[len("/System/Library/Frameworks/"):]
        if ".framework" in rest:
            fw = rest.split(".framework", 1)[0]
            if fw in SHIM_MAP:
                return SHIM_MAP[fw]
            return f"/System/Library/Frameworks/{fw}.framework/{fw}"
    if ".framework/Versions/" in orig:
        return re.sub(r"([^/]+)\.framework/Versions/[^/]+/\1$", r"\1.framework/\1", orig)
    return orig


def extract_arm64_slice(data: bytes) -> bytes:
    if len(data) < 32:
        raise ValueError("Truncated Mach-O input")
    be_magic = struct.unpack_from(">I", data, 0)[0]
    if be_magic in (FAT_MAGIC, FAT_MAGIC_64):
        count = struct.unpack_from(">I", data, 4)[0]
        stride = 20 if be_magic == FAT_MAGIC else 32
        for i in range(count):
            off = 8 + i * stride
            cpu, sub = struct.unpack_from(">II", data, off)
            if cpu == CPU_TYPE_ARM64 and (sub & 0x00FFFFFF) == CPU_SUBTYPE_ARM64_ALL:
                if be_magic == FAT_MAGIC:
                    sl_off, sl_len = struct.unpack_from(">II", data, off + 8)
                else:
                    sl_off, sl_len = struct.unpack_from(">QQ", data, off + 8)
                return data[sl_off : sl_off + sl_len]
        raise ValueError("Missing ARM64 slice in Universal binary")
    le_magic, cpu = struct.unpack_from("<II", data, 0)
    if le_magic == MH_MAGIC_64 and cpu == CPU_TYPE_ARM64:
        return data
    raise ValueError("Not an ARM64 Mach-O binary")


def _build_dylib_cmd(cmd: int, dylib_fields: bytes, path: str) -> bytes:
    raw = path.encode("utf-8") + b"\x00"
    total = (24 + len(raw) + 7) & ~7
    return struct.pack("<III", cmd, total, 24) + dylib_fields + raw + b"\x00" * (total - 24 - len(raw))


def _build_rpath_cmd(path: str) -> bytes:
    raw = path.encode("utf-8") + b"\x00"
    total = (12 + len(raw) + 7) & ~7
    return struct.pack("<III", LC_RPATH, total, 12) + raw + b"\x00" * (total - 12 - len(raw))


def convert_macho_bytes(
    data: bytes,
    *,
    add_launcher_rpaths: bool = False,
    alias_mono_mmap: bool = False,
) -> bytes:
    buf = bytearray(extract_arm64_slice(data))
    magic, cpu, sub, ftype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from("<IIIIIIII", buf, 0)
    if magic != MH_MAGIC_64 or cpu != CPU_TYPE_ARM64:
        raise ValueError("Unexpected Mach-O header")

    orig_end = 32 + sizeofcmds
    first_sect_off = len(buf)
    link_start = link_end = 0

    pos = 32
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", buf, pos)
        if cmd == LC_SEGMENT_64:
            segname = bytes(buf[pos + 8 : pos + 24]).split(b"\x00", 1)[0].decode("ascii", "ignore")
            fileoff, filesize = struct.unpack_from("<QQ", buf, pos + 40)
            nsects = struct.unpack_from("<I", buf, pos + 64)[0]
            if segname == "__LINKEDIT":
                link_start, link_end = fileoff, fileoff + filesize
            for s in range(nsects):
                soff = struct.unpack_from("<I", buf, pos + 72 + s * 80 + 48)[0]
                if 0 < soff < first_sect_off:
                    first_sect_off = soff
        pos += sz

    new_cmds = bytearray()
    existing_rpaths: set[str] = set()
    new_count = 0
    saw_build = False

    pos = 32
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", buf, pos)
        raw_cmd = bytes(buf[pos : pos + sz])
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB):
            name_off = struct.unpack_from("<I", raw_cmd, 8)[0]
            orig_path = raw_cmd[name_off:].split(b"\x00", 1)[0].decode("utf-8")
            mapped = rewrite_dylib_path(orig_path)
            new_cmds.extend(_build_dylib_cmd(cmd, raw_cmd[12:24], mapped))
            new_count += 1
        elif cmd == LC_RPATH:
            name_off = struct.unpack_from("<I", raw_cmd, 8)[0]
            rp = raw_cmd[name_off:].split(b"\x00", 1)[0].decode("utf-8")
            if rp.startswith("@executable_path/../"):
                rp = "@executable_path/Mac/Contents/" + rp[len("@executable_path/../"):]
            existing_rpaths.add(rp)
            new_cmds.extend(_build_rpath_cmd(rp))
            new_count += 1
        elif cmd == LC_BUILD_VERSION:
            patched = bytearray(raw_cmd)
            struct.pack_into("<III", patched, 8, PLATFORM_IOS, 17 << 16, 27 << 16)
            new_cmds.extend(patched)
            new_count += 1
            saw_build = True
        elif cmd == LC_VERSION_MIN_MACOSX:
            new_cmds.extend(struct.pack("<IIIIII", LC_BUILD_VERSION, 24, PLATFORM_IOS, 17 << 16, 27 << 16, 0))
            new_count += 1
            saw_build = True
        else:
            new_cmds.extend(raw_cmd)
            new_count += 1
        pos += sz

    if not saw_build:
        new_cmds.extend(struct.pack("<IIIIII", LC_BUILD_VERSION, 24, PLATFORM_IOS, 17 << 16, 27 << 16, 0))
        new_count += 1

    req_rpaths = (
        ["@executable_path/Frameworks", "@executable_path/Mac/Contents/Frameworks", "@loader_path/Frameworks"]
        if add_launcher_rpaths
        else ["@executable_path/Frameworks"]
    )
    for rp in req_rpaths:
        if rp not in existing_rpaths:
            new_cmds.extend(_build_rpath_cmd(rp))
            existing_rpaths.add(rp)
            new_count += 1

    new_end = 32 + len(new_cmds)
    if new_end > first_sect_off:
        raise ValueError(f"Mach-O header padding exceeded ({new_end} > {first_sect_off})")
    if new_end > orig_end and any(b != 0 for b in buf[orig_end:new_end]):
        raise ValueError("Mach-O header expansion would overwrite non-zero bytes")

    buf[32 : max(orig_end, new_end)] = b"\x00" * (max(orig_end, new_end) - 32)
    buf[32:new_end] = new_cmds
    struct.pack_into("<II", buf, 16, new_count, len(new_cmds))

    if alias_mono_mmap and link_end > link_start:
        idx = link_start
        while True:
            hit = buf.find(b"_mmap\x00", idx, link_end)
            if hit < 0:
                break
            prev = buf[hit - 1] if hit > link_start else 0
            if prev == 0 or prev < 0x20:
                buf[hit : hit + 5] = b"_smmp"
            idx = hit + 6

    return bytes(buf)


def convert_app_to_ipa(
    mac_app: Path,
    shims_dir: Path,
    output_ipa: Path,
    mono_mode: str = "interp",
    bundle_id: str = "com.alicecradle.ios.game",
) -> None:
    root = Path(__file__).resolve().parent.parent
    contents = mac_app / "Contents"
    mac_plist = plistlib.loads((contents / "Info.plist").read_bytes())
    exe_name = mac_plist["CFBundleExecutable"]

    stage = output_ipa.parent / f".stage-{mac_app.stem}"
    if stage.exists():
        shutil.rmtree(stage)
    app_out = stage / "Payload" / "AliceInCradle.app"
    shutil.copytree(contents, app_out / "Mac" / "Contents")
    shutil.rmtree(app_out / "Mac" / "Contents" / "_CodeSignature", ignore_errors=True)

    fw_out = app_out / "Frameworks"
    fw_out.mkdir(parents=True, exist_ok=True)
    for dylib in sorted(shims_dir.glob("libShim_*.dylib")):
        shutil.copy2(dylib, fw_out / dylib.name)

    main_exe_src = app_out / "Mac" / "Contents" / "MacOS" / exe_name
    conv_main = convert_macho_bytes(main_exe_src.read_bytes(), add_launcher_rpaths=True)
    (app_out / exe_name).write_bytes(conv_main)
    main_exe_src.write_bytes(conv_main)

    for p in sorted((app_out / "Mac" / "Contents").rglob("*")):
        if not p.is_file() or p == main_exe_src:
            continue
        head = p.read_bytes()[:4]
        if len(head) < 4:
            continue
        be = struct.unpack(">I", head)[0]
        le = struct.unpack("<I", head)[0]
        if le == MH_MAGIC_64 or be in (FAT_MAGIC, FAT_MAGIC_64):
            try:
                alias = (mono_mode == "interp" and "libmonobdwgc" in p.name)
                p.write_bytes(convert_macho_bytes(p.read_bytes(), alias_mono_mmap=alias))
            except ValueError as exc:
                print(f"[Skip] {p.name}: {exc}")

    ios_plist = plistlib.loads((root / "shims/resources/Info-game-ios.plist").read_bytes())
    ios_plist["CFBundleExecutable"] = exe_name
    ios_plist["CFBundleIdentifier"] = bundle_id
    ios_plist["CFBundleShortVersionString"] = mac_plist.get("CFBundleShortVersionString", "1.0")
    ios_plist["AICMonoMode"] = mono_mode
    (app_out / "Info.plist").write_bytes(plistlib.dumps(ios_plist, fmt=plistlib.FMT_XML))

    output_ipa.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output_ipa, "w", compression=zipfile.ZIP_DEFLATED, allowZip64=True) as zf:
        for p in sorted((stage / "Payload").rglob("*")):
            if p.is_file():
                zf.write(p, p.relative_to(stage).as_posix())
    shutil.rmtree(stage)
    print(f"Exported unsigned iOS 27 IPA: {output_ipa}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Convert macOS AliceInCradle.app to unsigned iOS 27 IPA.")
    parser.add_argument("--input", type=Path, required=True, help="Path to AliceInCradle.app")
    parser.add_argument("--shims", type=Path, default=Path("build/shims"), help="Directory containing libShim_*.dylib")
    parser.add_argument("--output", type=Path, required=True, help="Destination .ipa path")
    parser.add_argument("--mono-mode", choices=["interp", "jit", "aot", "none"], default="interp")
    parser.add_argument("--bundle-id", default="com.alicecradle.ios.game")
    args = parser.parse_args()
    convert_app_to_ipa(args.input.resolve(), args.shims.resolve(), args.output.resolve(), args.mono_mode, args.bundle_id)


if __name__ == "__main__":
    main()
