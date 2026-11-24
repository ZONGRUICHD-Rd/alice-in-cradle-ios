#!/usr/bin/env python3
"""Build all iOS 27 macOS compatibility shims and package the separated AliceCradleLauncher unsigned IPA."""
from pathlib import Path
import argparse
import hashlib
import plistlib
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parent.parent

# Complete iOS 27 macOS compatibility shim suite compiled directly against iPhoneOS SDK
SHIM_SPECS = [
    {
        "name": "AppKit",
        "sources": [
            "shims/overrides/AppKit.m",
            "shims/overrides/AppKit_RuntimeHooks.m",
            "shims/overrides/AppKit_AliceControls.m",
            "shims/overrides/AppKit_Stats.m",
        ],
        "flags": [
            "-framework", "UIKit",
            "-framework", "Foundation",
            "-framework", "QuartzCore",
            "-framework", "Metal",
            "-framework", "CoreGraphics",
            "-framework", "GameController",
        ],
    },
    {
        "name": "libSystem",
        "sources": ["shims/overrides/libSystem.m"],
        "flags": ["-framework", "Foundation", "-Wl,-reexport-lSystem"],
    },
    {
        "name": "CoreAudio",
        "sources": ["shims/overrides/CoreAudio_OutputCompat.m"],
        "flags": ["-framework", "Foundation", "-framework", "AVFoundation", "-framework", "AudioToolbox"],
    },
    {
        "name": "AudioUnit",
        "sources": ["shims/overrides/AudioUnit_OutputCompat.m"],
        "flags": ["-framework", "Foundation", "-framework", "AVFoundation", "-Wl,-reexport_framework,AudioToolbox"],
    },
    {
        "name": "CoreVideo",
        "sources": ["shims/overrides/CoreVideo_DisplayLink.m"],
        "flags": ["-framework", "Foundation", "-Wl,-reexport_framework,CoreVideo"],
    },
    {
        "name": "CoreGraphics",
        "sources": ["shims/overrides/CoreGraphics.m"],
        "flags": ["-framework", "UIKit", "-framework", "Foundation", "-Wl,-reexport_framework,CoreGraphics"],
    },
    {
        "name": "Carbon",
        "sources": ["shims/overrides/Carbon_Keyboard.m"],
        "flags": ["-framework", "Foundation"],
    },
    {
        "name": "CoreServices",
        "sources": ["shims/overrides/CoreServices_Keyboard.m"],
        "flags": ["-framework", "Foundation", "-Wl,-reexport_framework,CoreServices"],
    },
    {
        "name": "IOKit",
        "sources": ["shims/overrides/IOKit.m"],
        "flags": ["-framework", "Foundation"],
    },
    {
        "name": "Metal",
        "sources": ["shims/overrides/Metal.m"],
        "flags": ["-framework", "Foundation", "-Wl,-reexport_framework,Metal"],
    },
    {
        "name": "Security",
        "sources": ["shims/overrides/Security.m"],
        "flags": ["-framework", "Foundation", "-Wl,-reexport_framework,Security"],
    },
    {
        "name": "SystemConfiguration",
        "sources": ["shims/overrides/SystemConfiguration.m"],
        "flags": ["-framework", "Foundation", "-Wl,-reexport_framework,SystemConfiguration"],
    },
    {
        "name": "Foundation",
        "sources": ["shims/overrides/Foundation_Compat.m"],
        "flags": ["-Wl,-reexport_framework,Foundation"],
    },
]


def run(cmd: list[str]) -> str:
    print("+", " ".join(cmd))
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print(res.stdout)
        print(res.stderr, file=sys.stderr)
        raise SystemExit(f"Command failed ({res.returncode}): {' '.join(cmd[:6])}")
    return res.stdout


def build_shims(out_dir: Path, min_ios: str) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    built: list[Path] = []
    target = f"arm64-apple-ios{min_ios}"
    include_dir = str(ROOT / "shims/include")

    for spec in SHIM_SPECS:
        name = spec["name"]
        dylib = out_dir / f"libShim_{name}.dylib"
        sources = [str(ROOT / s) for s in spec["sources"]]
        cmd = [
            "xcrun", "--sdk", "iphoneos", "clang",
            "-O2", "-target", target,
            "-fobjc-arc", "-fmodules",
            "-Wno-deprecated-declarations",
            "-dynamiclib",
            f"-I{include_dir}",
            "-install_name", f"@rpath/libShim_{name}.dylib",
            "-Wl,-rpath,@executable_path/Frameworks",
            *sources,
            *spec["flags"],
            "-o", str(dylib),
        ]
        run(cmd)
        # Apply clean ad-hoc signature so LiveContainer / Sideloadly can re-sign cleanly
        run(["codesign", "-f", "-s", "-", str(dylib)])
        built.append(dylib)
    return built


def build_launcher_app(stage_dir: Path, shims_dir: Path, bundle_id: str, min_ios: str) -> Path:
    app_dir = stage_dir / "Payload" / "AliceCradleLauncher.app"
    if app_dir.exists():
        shutil.rmtree(app_dir)
    app_dir.mkdir(parents=True)

    launcher_sources = sorted((ROOT / "launcher/Sources").glob("*.m"))
    if not launcher_sources:
        raise SystemExit("No launcher Objective-C sources found")

    target = f"arm64-apple-ios{min_ios}"
    exe_path = app_dir / "AliceCradleLauncher"
    cmd = [
        "xcrun", "--sdk", "iphoneos", "clang",
        "-O2", "-target", target,
        "-fobjc-arc",
        "-Wno-deprecated-declarations",
        "-framework", "UIKit",
        "-framework", "Foundation",
        "-framework", "UniformTypeIdentifiers",
        "-framework", "QuartzCore",
        "-framework", "CoreGraphics",
        "-lz",
        "-Wl,-rpath,@executable_path/Frameworks",
        *[str(s) for s in launcher_sources],
        "-o", str(exe_path),
    ]
    run(cmd)
    run(["codesign", "-f", "-s", "-", str(exe_path)])

    # Embed compiled iOS 27 Shims inside Shims/ (injected into user-imported game IPAs at runtime)
    dst_shims = app_dir / "Shims"
    dst_shims.mkdir()
    for dylib in sorted(shims_dir.glob("libShim_*.dylib")):
        shutil.copy2(dylib, dst_shims / dylib.name)

    # Embed Info-game-ios.plist template
    dst_tpl = app_dir / "Templates"
    dst_tpl.mkdir()
    shutil.copy2(ROOT / "shims/resources/Info-game-ios.plist", dst_tpl / "Info-game-ios.plist")

    # Generate procedural vector icons
    run([sys.executable, str(ROOT / "tools/make_icon.py"), "--out-dir", str(app_dir)])

    # Write Launcher Info.plist
    info = plistlib.loads((ROOT / "launcher/Resources/Info-launcher.plist").read_bytes())
    info["CFBundleIdentifier"] = bundle_id
    info["MinimumOSVersion"] = min_ios
    info["CFBundleIcons"] = {
        "CFBundlePrimaryIcon": {
            "CFBundleIconFiles": ["AppIcon60x60"],
        }
    }
    (app_dir / "Info.plist").write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML))

    # Ad-hoc sign the launcher bundle so structure is valid unsigned IPA for sideloading
    run(["codesign", "-f", "-s", "-", str(app_dir)])
    return app_dir


def package_ipa(stage_dir: Path, output_ipa: Path) -> None:
    output_ipa.parent.mkdir(parents=True, exist_ok=True)
    payload_dir = stage_dir / "Payload"
    with zipfile.ZipFile(output_ipa, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        for path in sorted(payload_dir.rglob("*")):
            if path.is_file():
                arcname = path.relative_to(stage_dir).as_posix()
                zf.write(path, arcname)
    sha = hashlib.sha256(output_ipa.read_bytes()).hexdigest()
    size_mb = output_ipa.stat().st_size / (1024 * 1024)
    print(f"READY: {output_ipa} ({size_mb:.2f} MB) SHA-256={sha}")


def verify_outputs(app_dir: Path) -> None:
    exe = app_dir / "AliceCradleLauncher"
    print("=== Verify Launcher Binary ===")
    print(run(["file", str(exe)]))
    print(run(["xcrun", "vtool", "-show-build", str(exe)]))
    shims = sorted((app_dir / "Shims").glob("libShim_*.dylib"))
    print(f"=== Verified {len(shims)} bundled iOS 27 Shims ===")
    for s in shims:
        out = run(["xcrun", "otool", "-L", str(s)])
        first_line = out.splitlines()[1].strip() if len(out.splitlines()) > 1 else ""
        print(f"  OK {s.name} -> {first_line}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Build separated Alice in Cradle iOS 27 Launcher IPA.")
    parser.add_argument("--work", type=Path, default=ROOT / "build")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/AliceCradleLauncher-iOS27-Unsigned.ipa")
    parser.add_argument("--bundle-id", default="com.alicecradle.ios.launcher")
    parser.add_argument("--min-ios", default="17.0")
    args = parser.parse_args()

    work = args.work.resolve()
    shims_dir = work / "shims"
    stage_dir = work / "stage"
    if stage_dir.exists():
        shutil.rmtree(stage_dir)

    build_shims(shims_dir, args.min_ios)
    app_dir = build_launcher_app(stage_dir, shims_dir, args.bundle_id, args.min_ios)
    verify_outputs(app_dir)
    package_ipa(stage_dir, args.output.resolve())


if __name__ == "__main__":
    main()
