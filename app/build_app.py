#!/usr/bin/env python3
"""Build the public Apple Silicon app from source, without camera/user resources."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP_ID = "dev.jiesu.canonluttool.r63"
PYTHON_SOURCE = Path("/Library/Frameworks/Python.framework/Versions/3.13")
BUILD = ROOT / "app" / "build"
RUNTIME = BUILD / "python"
ICON_SOURCE = ROOT / "app" / "make_app_icon.swift"
ICON = ROOT / "app" / "assets" / "AppIcon.icns"


def run(*args: str | Path, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def prepare_icon() -> None:
    if not ICON_SOURCE.is_file():
        raise SystemExit(f"App icon source is missing: {ICON_SOURCE}")
    if not ICON.is_file() or ICON_SOURCE.stat().st_mtime > ICON.stat().st_mtime:
        run("/usr/bin/swift", ICON_SOURCE, ICON.parent)
    if not ICON.is_file() or ICON.read_bytes()[:4] != b"icns":
        raise SystemExit(f"App icon is missing or invalid: {ICON}")


def is_macho(path: Path) -> bool:
    if not path.is_file() or path.is_symlink():
        return False
    with path.open("rb") as handle:
        return handle.read(4) in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")


def package_python() -> None:
    marker = RUNTIME / ".relocated-runtime-v1"
    if marker.exists():
        print("Using previously verified private Python runtime.", flush=True)
        return
    if not (PYTHON_SOURCE / "bin/python3.13").is_file():
        raise SystemExit(f"Build prerequisite not found: {PYTHON_SOURCE}/bin/python3.13")
    if RUNTIME.exists():
        shutil.rmtree(RUNTIME)
    (RUNTIME / "bin").mkdir(parents=True)
    (RUNTIME / "lib").mkdir()
    # python.org's bin/python3.13 is a launcher for Resources/Python.app.
    # Bundle the actual interpreter directly so there is no launcher path dependency.
    shutil.copy2(PYTHON_SOURCE / "Resources/Python.app/Contents/MacOS/Python", RUNTIME / "bin/python3.13")
    shutil.copy2(PYTHON_SOURCE / "Python", RUNTIME / "Python")
    excluded = {"site-packages", "test", "tests", "__pycache__", "tkinter", "idlelib", "turtledemo", "ensurepip"}

    def ignore(directory, names):
        return [name for name in names if name in excluded or name.startswith(("_test", "_tkinter", "config-")) or name.endswith((".pyc", ".a"))]

    shutil.copytree(PYTHON_SOURCE / "lib/python3.13", RUNTIME / "lib/python3.13", ignore=ignore)
    for path in (PYTHON_SOURCE / "lib").glob("*.dylib"):
        if path.is_file() and not path.is_symlink():
            shutil.copy2(path, RUNTIME / "lib" / path.name)
    machos = [path for path in RUNTIME.rglob("*") if is_macho(path)]
    print(f"Relocating {len(machos)} private Python binaries (arm64).", flush=True)
    for path in machos:
        architectures = subprocess.check_output(["/usr/bin/lipo", "-archs", str(path)], text=True).split()
        if "arm64" not in architectures:
            raise SystemExit(f"arm64 missing: {path}")
        if len(architectures) > 1:
            thin = path.with_name(path.name + ".arm64-tmp")
            run("/usr/bin/lipo", path, "-thin", "arm64", "-output", thin, stdout=subprocess.DEVNULL)
            thin.chmod(path.stat().st_mode)
            thin.replace(path)
        dependencies = subprocess.check_output(["/usr/bin/otool", "-L", str(path)], text=True).splitlines()[1:]
        for line in dependencies:
            dependency = line.strip().split(" (", 1)[0]
            if dependency.startswith(str(PYTHON_SOURCE) + "/"):
                relative = Path(dependency).relative_to(PYTHON_SOURCE)
                destination = RUNTIME / relative
                if destination == path:
                    continue
                if not destination.is_file():
                    raise SystemExit(f"Unbundled Python dependency: {dependency} (from {path})")
                replacement = "@loader_path/" + os.path.relpath(destination, path.parent)
                run("/usr/bin/install_name_tool", "-change", dependency, replacement, path, stderr=subprocess.DEVNULL)
        if path.name == "Python" or path.suffix == ".dylib":
            run("/usr/bin/install_name_tool", "-id", "@rpath/" + path.name, path, stderr=subprocess.DEVNULL)
        run("/usr/bin/codesign", "--force", "--sign", "-", path, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    environment = dict(os.environ, PYTHONHOME=str(RUNTIME), PYTHONNOUSERSITE="1", PYTHONDONTWRITEBYTECODE="1")
    output = subprocess.check_output([str(RUNTIME / "bin/python3.13"), "-B", "-I", "-c",
        "import ctypes,hashlib,json,pathlib,tempfile,math,struct,zlib,ssl; print('private-runtime-ok')"], env=environment, text=True)
    if output.strip() != "private-runtime-ok":
        raise SystemExit("Private Python runtime smoke check failed")
    for path in machos:
        dependencies = subprocess.check_output(["/usr/bin/otool", "-L", str(path)], text=True)
        if str(PYTHON_SOURCE) in dependencies:
            raise SystemExit(f"Unrelocated Python dependency remains: {path}")
    marker.write_text("Python 3.13; arm64; relocated local dependencies; stdlib only\n", encoding="utf-8")
    print("Private runtime smoke check passed.", flush=True)


def build_app(output: Path) -> None:
    prepare_icon()
    backend = ROOT / "src/r6lut"
    if not (backend / "__main__.py").is_file():
        raise SystemExit("Backend CLI is not ready: src/r6lut/__main__.py")
    if (backend / "resources").exists():
        raise SystemExit("Public builds must not contain private backend/resources")
    if output.exists():
        try:
            identity = plistlib.loads((output / "Contents/Info.plist").read_bytes()).get("CFBundleIdentifier")
        except Exception:
            identity = None
        if identity != APP_ID:
            raise SystemExit(f"Refusing to replace unrelated application: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".canon-lut-build-", dir=output.parent)) / output.name
    contents = stage / "Contents"
    macos = contents / "MacOS"
    resources = contents / "Resources"
    macos.mkdir(parents=True)
    resources.mkdir()
    info = {
        "CFBundleDevelopmentRegion": "zh_CN", "CFBundleName": "Canon LUT 工具",
        "CFBundleDisplayName": "Canon LUT 工具", "CFBundleIdentifier": APP_ID,
        "CFBundleExecutable": "CanonLUTTool", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.3.7", "CFBundleVersion": "13",
        "CFBundleIconFile": "AppIcon.icns",
        "LSMinimumSystemVersion": "13.0", "NSHighResolutionCapable": True,
        "NSCameraUsageDescription": "备份并写入您选择的佳能相机用户照片风格。",
        "NSPrincipalClass": "NSApplication",
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(info, sort_keys=True))
    run("/usr/bin/swiftc", "-parse-as-library", "-swift-version", "5", "-target", "arm64-apple-macosx13.0",
        "-file-prefix-map", str(ROOT) + "=.",
        "-O", "-framework", "SwiftUI", "-framework", "AppKit", "-framework", "CryptoKit",
        "-framework", "IOKit", "-framework", "CoreImage", "-framework", "ImageIO",
        ROOT / "app/CanonLUTTool.swift", ROOT / "app/CameraConnectionMonitor.swift",
        ROOT / "app/PhotoPreview.swift", ROOT / "app/PhotoPreviewPanel.swift", ROOT / "app/PreviewPhotoView.swift", ROOT / "app/ComparisonLayout.swift", "-o", macos / "CanonLUTTool")
    run("/usr/bin/clang", "-fobjc-arc", "-O2", "-arch", "arm64", "-mmacosx-version-min=13.0",
        "-ffile-prefix-map=" + str(ROOT) + "=.",
        "-framework", "Foundation", "-framework", "AppKit", "-framework", "ImageIO",
        "-framework", "CoreGraphics", "-framework", "UniformTypeIdentifiers",
        ROOT / "app/NativePF3Preview/native_pf3_preview.m", "-o", macos / "native_pf3_preview")
    run("/usr/bin/clang", "-fobjc-arc", "-O2", "-arch", "arm64", "-mmacosx-version-min=13.0",
        "-ffile-prefix-map=" + str(ROOT) + "=.",
        "-framework", "Foundation", "-framework", "AppKit",
        ROOT / "src/eds_r6_tool.m", "-o", macos / "eds_r6_tool")
    shutil.copy2(ICON, resources / "AppIcon.icns")
    shutil.copytree(RUNTIME, resources / "python", ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    packaged_backend = resources / "backend/r6lut"
    packaged_backend.mkdir(parents=True)
    for source in backend.glob("*.py"):
        if not source.name.startswith("test_"):
            shutil.copy2(source, packaged_backend / source.name)
    shutil.copy2(ROOT / "app/使用说明.txt", resources / "使用说明.txt")
    for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
        shutil.copy2(ROOT / name, resources / name)
    shutil.copytree(ROOT / "licenses", resources / "licenses")
    environment = dict(os.environ, PYTHONHOME=str(resources / "python"), PYTHONPATH=str(resources / "backend"),
                       PYTHONNOUSERSITE="1", PYTHONDONTWRITEBYTECODE="1")
    run(resources / "python/bin/python3.13", "-B", "-m", "r6lut", "--help", env=environment, stdout=subprocess.DEVNULL)
    # Nested Python extension modules and dylibs are signed above; sign the helper and final bundle.
    run("/usr/bin/codesign", "--force", "--sign", "-", macos / "eds_r6_tool", stderr=subprocess.DEVNULL)
    run("/usr/bin/codesign", "--force", "--sign", "-", macos / "native_pf3_preview", stderr=subprocess.DEVNULL)
    run("/usr/bin/codesign", "--force", "--deep", "--sign", "-", stage, stderr=subprocess.DEVNULL)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", stage)
    stage_parent = stage.parent
    if output.exists():
        shutil.rmtree(output)
    stage.replace(output)
    stage_parent.rmdir()
    print(json.dumps({"app": str(output), "status": "built", "canonBinariesBundled": False}, ensure_ascii=False), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist/Canon LUT 工具.app")
    parser.add_argument("--runtime-only", action="store_true")
    args = parser.parse_args()
    BUILD.mkdir(parents=True, exist_ok=True)
    package_python()
    if not args.runtime_only:
        output = args.output.resolve()
        build_app(output)


if __name__ == "__main__":
    main()
