"""Read-only native PSE PF3 previews using the user's installed Canon software.

No Canon binaries are distributed. The stdlib-only bridge generates the same
native custom ICC as PSE, then a disposable process develops the original RAW.
"""
from __future__ import annotations

import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile

from .bridge import Parser


PSE = Path("/Applications/Canon Utilities/Picture Style Editor/PictureStyleEditor.app")
PARSER = PSE / "Contents/PlugIns/EdsCFParse.bundle/Contents/MacOS/EdsCFParse"
MLIB = PSE / "Contents/PlugIns/DppCore.bundle/Contents/PlugIns/MLib.bundle/Contents/MacOS/MLib"
BASES = {0x81: "Standard", 0x82: "Portrait", 0x83: "Landscape",
         0x84: "Neutral", 0x85: "Faithful", 0x88: "Fine Detail"}
SCHEMA = "r6lut-pf3-preview-v1"
RAW_EXTENSIONS = {".cr2", ".cr3", ".crw"}
SETTINGS = ("contrast", "sharpness", "saturation", "colorTone", "filterEffect",
            "toningEffect", "fineness", "threshold")
ICC_PROPERTIES = (0x40001018, 0x40001065, 0x40001019, 0x40001021,
                  0x40001061, 0x40001023)


def file_sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class _Renderer:
    """Keep SIGTERM/SIGINT cancellation from leaving a DppCore child behind."""
    def __init__(self):
        self.child = None
        self.previous = {}

    def __enter__(self):
        for sig in (signal.SIGTERM, signal.SIGINT):
            self.previous[sig] = signal.signal(sig, self.cancel)
        return self

    def stop(self):
        child = self.child
        if child is not None:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            else:
                child.wait()
            self.child = None

    def cancel(self, signum, frame):
        self.stop()
        raise RuntimeError("PF3 预览已取消。")

    def __exit__(self, kind, value, traceback):
        self.stop()
        for sig, handler in self.previous.items():
            signal.signal(sig, handler)

    def run(self, arguments, log_path):
        # PSE diagnostic environment variables from experimental scripts must
        # never influence this production helper's explicit argument contract.
        environment = {k: v for k, v in os.environ.items()
                       if k not in {"PSE_USER_ICC", "PSE_SOURCE_SETTINGS", "PSE_PER_STYLE"}}
        self.child = subprocess.Popen([str(value) for value in arguments],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                      text=True, encoding="utf-8", errors="replace", env=environment)
        try:
            stdout, stderr = self.child.communicate(timeout=120)
            returncode = self.child.returncode
        except subprocess.TimeoutExpired as error:
            self.stop()
            raise RuntimeError("Canon 离线显影超时，已停止预览进程。") from error
        finally:
            if self.child is not None and self.child.poll() is not None:
                self.child.wait()
                self.child = None
        log_path.write_text(stdout + ("\nSTDERR:\n" + stderr if stderr else ""), encoding="utf-8")
        events = []
        for line in stdout.splitlines():
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(event, dict):
                events.append(event)
        result = next((event for event in events if event.get("event") == "render_complete"), None)
        if returncode or not result or not result.get("originalsUnchanged"):
            failed = next((event for event in events if event.get("rc", 0) != 0), None)
            detail = f"（{failed['event']}: {failed['rc']}）" if failed else f"（退出状态 {returncode}）"
            raise RuntimeError("Canon 无法显影这张照片或应用此 PF3 " + detail + "。请使用受本机 Picture Style Editor 支持的佳能 RAW，并查看预览日志。")
        return result


def _make_profile(source, ascii_copy, work):
    """Generate ICC through the installed public MLib C export, not old CUBEs."""
    import struct

    original = source.read_bytes()
    ascii_copy.write_bytes(original)
    parser = Parser(PARSER)
    try:
        # Checks the complete envelope, stored records, checksum and terminator,
        # including protected files which the installed parser can read.
        parser.file_records(original)
        properties = parser.read(ascii_copy)
    finally:
        parser.call("Terminate")
    if source.read_bytes() != original:
        raise RuntimeError("源 PF3 在读取过程中发生变化，请重新预览。")
    base = int.from_bytes(properties[0x114], "little")
    if base not in BASES:
        raise ValueError(f"此 PF3 的基础照片风格 0x{base:x} 暂不支持原生预览；支持 Standard、Portrait、Landscape、Fine Detail、Neutral、Faithful。")
    values = struct.unpack("<8i", properties[0x115])
    settings = dict(zip(SETTINGS, values))
    if settings["filterEffect"] or settings["toningEffect"]:
        raise ValueError("此 PF3 包含未支持的单色滤镜或色调参数，无法可靠预览。")
    library = C.CDLL(str(MLIB))

    class Profile(C.Structure):
        _fields_ = [("data", C.c_void_p), ("size", C.c_uint64)]

    create = library.MLIBcreateCustomMLDataEXForPF3forDotNet
    create.argtypes = [C.c_void_p] * 4 + [C.c_int, C.c_long, C.c_void_p, C.c_void_p]
    create.restype = C.POINTER(Profile)
    release = library.MLIBreleaseCustomMLData
    release.argtypes, release.restype = [C.POINTER(Profile)], None
    buffers = [C.create_string_buffer(properties[key], len(properties[key])) for key in ICC_PROPERTIES]
    profile = create(buffers[0], buffers[1], buffers[2], buffers[3], 1, 0, buffers[4], buffers[5])
    if not profile:
        raise RuntimeError("Canon 无法从此 PF3 生成原生颜色配置。")
    try:
        size = profile.contents.size
        if not 128 <= size <= 16 * 1024 * 1024:
            raise RuntimeError("Canon 返回的 PF3 颜色配置长度异常。")
        icc = C.string_at(profile.contents.data, size)
    finally:
        release(profile)
    if icc[36:40] != b"acsp":
        raise RuntimeError("Canon 返回的 PF3 颜色配置无效。")
    icc_path = work / "profile.icc"
    icc_path.write_bytes(icc)
    binding = {"sourceSha256": hashlib.sha256(original).hexdigest(), "baseStyle": base,
               "baseStyleName": BASES[base], "iccSha256": hashlib.sha256(icc).hexdigest(),
               "settings": settings, "iccIncludesBasicSettings": False,
               "iccInputPropertyIDs": [f"0x{key:08x}" for key in ICC_PROPERTIES]}
    settings_path = work / "settings.json"
    settings_path.write_text(json.dumps(binding, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return icc_path, settings_path, binding


def preview_pf3(input_path, photo_path, output_path, helper_path):
    source, photo = Path(input_path).resolve(), Path(photo_path).resolve()
    destination, helper = Path(output_path).resolve(), Path(helper_path).resolve()
    if not source.is_file() or source.suffix.lower() != ".pf3":
        raise ValueError("请选择存在的 PF3 文件。")
    if not photo.is_file():
        raise ValueError("请选择存在的照片文件。")
    if destination.exists() and (not destination.is_dir() or any(destination.iterdir())):
        raise ValueError("预览输出目录必须为空，避免覆盖已有文件。")
    pf3_hash, photo_hash = file_sha256(source), file_sha256(photo)
    # Dense full33 PF3s from this tool have their color effect in 1070/1071;
    # they must not fall through to native parameter ICC and silently lose it.
    from .pf3_embedded_preview import prepare_embedded_pf3_lookup
    embedded = prepare_embedded_pf3_lookup(source, destination)
    if embedded is not None:
        embedded.update(schema=SCHEMA, pf3Sha256=pf3_hash, photoSha256=photo_hash,
                        photo=str(photo), isRaw=photo.suffix.lower() in RAW_EXTENSIONS)
        if file_sha256(source) != pf3_hash or file_sha256(photo) != photo_hash:
            raise RuntimeError("源照片或 PF3 已变化，请重新预览。")
        (destination / "metadata.json").write_text(json.dumps(embedded, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return embedded
    if photo.suffix.lower() not in RAW_EXTENSIONS:
        raise ValueError("原生 PF3 预览需要对应的佳能 RAW（CR3／CR2），Canon 显影接口不支持将 PF3 应用于 JPEG。JPEG 照片可继续使用 CUBE 近似预览。")
    if not all(path.is_file() for path in (PARSER, MLIB)):
        raise RuntimeError("原生 PF3 预览需要在此 Mac 安装佳能 Picture Style Editor；未找到完整的本机离线显影组件。")
    if not helper.is_file() or not os.access(helper, os.X_OK):
        raise RuntimeError("应用缺少可执行的原生 PF3 预览组件，请重新安装完整工具。")
    destination.mkdir(parents=True, exist_ok=True)
    with _Renderer() as renderer, tempfile.TemporaryDirectory(prefix="canon-pf3-preview-", dir="/tmp") as folder:
        work = Path(folder)
        ascii_copy = work / "source.pf3"
        icc, settings, binding = _make_profile(source, ascii_copy, work)
        before = renderer.run([helper, photo, destination / "before.png", "Canon Neutral"], destination / "before-render.log")
        after = renderer.run([helper, photo, destination / "after.png", source.stem, ascii_copy, icc, settings], destination / "after-render.log")
        if any(before[key] != after[key] for key in ("width", "height", "sourceWidth", "sourceHeight", "orientation", "photoSha256")):
            raise RuntimeError("前后预览的照片尺寸或来源不一致，已停止。")
        if binding["sourceSha256"] != pf3_hash or before["photoSha256"] != photo_hash:
            raise RuntimeError("预览来源校验失败，请重新预览。")
        if file_sha256(source) != pf3_hash or file_sha256(photo) != photo_hash:
            raise RuntimeError("源照片或 PF3 已变化，请重新预览。")
        metadata = {
            "schema": SCHEMA, "renderMode": "native", "label": source.stem,
            "pf3": str(source), "photo": str(photo), "pf3Sha256": pf3_hash, "photoSha256": photo_hash,
            "isRaw": True, "width": after["width"], "height": after["height"],
            "sourceWidth": after["sourceWidth"], "sourceHeight": after["sourceHeight"], "orientation": after["orientation"],
            "method": "Canon 原生 PF3 离线显影（非机内实拍）",
            "beforeBaseline": "Canon Neutral；曝光补偿 0 EV；拍摄白平衡；sRGB；锐度 2／精细度 2／阈值 3",
            "exposureEV": 0, "whiteBalance": "As Shot", "workingColorSpace": "sRGB",
            "nativeProfile": binding, "beforeRGBSha256": before["rgbSha256"], "afterRGBSha256": after["rgbSha256"],
            "originalsUnchanged": True, "cameraAccess": False,
            "scope": "Canon PSE 参数型 PF3 的原生离线显影；相机固件及拍摄设置可能影响机内输出。",
        }
        (destination / "metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return metadata
