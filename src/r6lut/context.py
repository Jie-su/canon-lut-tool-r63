"""User-owned, local conversion contexts. No camera data ships with the app.

Setup consumes a saved read-only snapshot and a PF3 which the user has already
registered as User Def. 1 through Canon's official software. It never initializes
EDSDK or accesses a connected camera.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import struct
import tempfile

from .bridge import Parser, validate_table
from .native import (DESCRIPTOR_SHA256, HEADER_BYTES, LIBRARY, MODEL, PARSER_SHA256,
                     Native, build_dense, require, sha, snapshot)

SCHEMA = "r6lut-local-context-v1"
SNAPSHOT_SCHEMA = "r6m3-fresh-snapshot-v1"
CAMERA_FILES = (
    "property-01000001-param-0.bin",
    "property-00000007-param-0.bin",
    "property-01000210-param-0.bin",
    "property-00000114-param-33.bin",
    "property-00000115-param-33.bin",
    "property-01000203-param-33.bin",
)


def default_context_path():
    override = os.environ.get("R6LUT_CONTEXT")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library/Application Support/Canon LUT Tool R63/profile"


def _require_file(path, maximum=16 * 1024 * 1024):
    require(path.is_file() and not path.is_symlink(), "本地配置中的文件缺失或不是普通文件。")
    require(0 < path.stat().st_size <= maximum, "本地配置文件大小无效。")
    return path.read_bytes()


def _bound_path(directory, spec):
    require(isinstance(spec, dict), "本地配置文件记录无效。")
    filename = spec.get("file")
    require(isinstance(filename, str) and filename and not Path(filename).is_absolute(),
            "本地配置只允许相对文件路径。")
    require(all(part not in (".", "..") for part in Path(filename).parts), "本地配置包含无效的文件路径。")
    path = directory / filename
    try:
        path.resolve().relative_to(directory.resolve())
    except ValueError as error:
        raise ValueError("本地配置文件越出了配置目录。") from error
    data = _require_file(path)
    require(type(spec.get("bytes")) is int and spec["bytes"] == len(data)
            and spec.get("sha256") == sha(data), "本地配置文件校验失败，请重新初始化。")
    return path, data


def _record(path, relative):
    data = path.read_bytes()
    return {"file": relative, "bytes": len(data), "sha256": sha(data)}


def _parser_path(library_path):
    library = Path(library_path or LIBRARY).resolve()
    require(library.is_file() and sha(library.read_bytes()) == PARSER_SHA256,
            "需要本机安装的已验证 Canon EdsCFParse 版本。")
    return library


def _saved_snapshot(directory):
    """Require source bytes to match the helper's fresh-device manifest."""
    manifest_path = directory / "manifest.json"
    raw = _require_file(manifest_path, maximum=1024 * 1024)
    try:
        manifest = json.loads(raw)
    except (ValueError, UnicodeError) as error:
        raise ValueError("相机只读快照清单无效。") from error
    require(isinstance(manifest, dict) and manifest.get("schema") == SNAPSHOT_SCHEMA,
            "请使用当前工具的只读相机快照创建本地配置。")
    require(manifest.get("freshReadOpcode") == 0x9189
            and manifest.get("cachedFallbackAllowed") is False,
            "初始化需要独立设备读取的快照，不能使用 SDK 缓存。")
    require(manifest.get("model") == "0x80000518" and manifest.get("firmware") == "1.1.2"
            and manifest.get("descriptorSha256") == DESCRIPTOR_SHA256
            and manifest.get("sdkSha256") == "35a425fc84460bac539eb051b921362c142dfcde966514b18249be8c393529ea",
            "快照不属于当前已验证的 R6 III／1.1.2／SDK 兼容范围。")
    records = manifest.get("properties")
    require(isinstance(records, list), "相机快照缺少文件清单。")
    wanted = {}
    for item in records:
        require(isinstance(item, dict) and isinstance(item.get("file"), str), "相机快照文件清单无效。")
        require(item["file"] not in wanted, "相机快照包含重复文件记录。")
        wanted[item["file"]] = item
    bound_data = {}
    for filename in CAMERA_FILES:
        require(filename in wanted, "相机快照缺少初始化所需属性。")
        _, bound_data[filename] = _bound_path(directory, wanted[filename])
    live = snapshot(directory)
    require(all((directory / filename).read_bytes() == data for filename, data in bound_data.items())
            and manifest_path.read_bytes() == raw, "相机快照在校验期间发生变化。")
    require(struct.unpack_from("<H", live["readback"], 44)[0] == 0x81,
            "请先用官方 EOS Utility 将同一份 Standard 基础 PF3 注册到用户槽 1，再重新建立只读快照。")
    return live, sha(raw)


def _validate_baseline(base, live, library):
    original = _require_file(base)
    api = None
    with tempfile.TemporaryDirectory(prefix="r6lut-context-native-", dir="/private/tmp") as temporary:
        native_base = Path(temporary) / "baseline.pf3"
        native_base.write_bytes(original)
        try:
            api = Parser(library)
            records = api.file_records(original)
            properties = api.read(native_base)
            require(len(records) == 26, "基础 PF3 的记录结构不在已验证范围。")
            require(properties[0x114] == struct.pack("<I", 0x81), "初始化需要 Standard 基础照片风格。")
            require(properties[0x115] == live["settings"], "PF3 设置与快照中的用户槽 1 不一致。")
            for key in (0x40001070, 0x40001071):
                validate_table(properties[key])
            normal, checked, checks, tables = Native(api).compile_normal(native_base, live)
            _, dense_tables = build_dense(normal, checked)
            require(all(t["normalNativeVsDense"]["maxSampleDelta"] <= 5 for t in dense_tables),
                    "基础 PF3 的原生色表与源色表不一致；请导出未叠加任意 LUT 的 Standard 基础风格。")
            header = bytearray(normal[:HEADER_BYTES])
            struct.pack_into("<I", header, 4, 83036)
            struct.pack_into("<I", header, 40, 83036)
            header[8:40] = bytes(32)
            require(bytes(header) == live["readback"][:HEADER_BYTES],
                    "基础 PF3 与官方注册快照不匹配，请向用户槽 1 注册同一份文件后重试。")
            require(base.read_bytes() == original, "基础 PF3 在校验期间发生变化。")
            return {"baseStyle": 0x81, "recordCount": len(records), "nativeHeaderMatchesOfficialReadback": True,
                    "baselineNativeVsDenseMaxDelta": [t["normalNativeVsDense"]["maxSampleDelta"] for t in dense_tables],
                    "realModelChecks": checks, "nativeTables": tables}
        except KeyError as error:
            raise ValueError("基础 PF3 缺少初始化所需的照片风格属性。") from error
        finally:
            if api is not None:
                api.call("Terminate")


def setup_context(base_path, camera_data, output_path, library_path=None):
    """Validate and copy this user's own PF3/snapshot into a new local profile."""
    base = Path(base_path).expanduser().resolve()
    camera = Path(camera_data).expanduser().resolve()
    output = Path(output_path).expanduser().resolve()
    require(not output.exists(), "本地配置输出目录已存在；请选择新目录，保留原配置。")
    require(base.suffix.lower() == ".pf3", "请选择自己的 Standard 基础 PF3。")
    library = _parser_path(library_path)
    original_base_hash = sha(_require_file(base))
    live, snapshot_hash = _saved_snapshot(camera)
    original_files = {filename: (camera / filename).read_bytes() for filename in CAMERA_FILES}
    validation = _validate_baseline(base, live, library)
    require(sha(base.read_bytes()) == original_base_hash, "基础 PF3 在校验期间发生变化。")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".r6lut-context-", dir=output.parent) as temporary:
        stage = Path(temporary) / "profile"
        (stage / "camera").mkdir(parents=True, mode=0o700)
        shutil.copyfile(base, stage / "baseline.pf3")
        (stage / "baseline.pf3").chmod(0o600)
        for filename, data in original_files.items():
            target = stage / "camera" / filename
            target.write_bytes(data)
            target.chmod(0o600)
        manifest = {
            "schema": SCHEMA, "model": "0x80000518", "firmware": "1.1.2",
            "serializerType": 10, "parserSha256": PARSER_SHA256,
            "descriptorSha256": sha(live["descriptor"]), "settingsSha256": sha(live["settings"]),
            "base": _record(stage / "baseline.pf3", "baseline.pf3"),
            "cameraFiles": [_record(stage / "camera" / filename, "camera/" + filename) for filename in CAMERA_FILES],
            "sourceSnapshotManifestSha256": snapshot_hash, "validation": validation,
            "containsUserOwnedLocalData": True, "cameraAccessDuringSetup": False,
            "notes": "Local conversion input, not a fresh write authorization or a restorable full33 backup. Do not publish this directory.",
        }
        (stage / "context.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        (stage / "context.json").chmod(0o600)
        require(sha(base.read_bytes()) == original_base_hash
                and all((camera / filename).read_bytes() == data for filename, data in original_files.items()),
                "源基础文件或相机快照在初始化期间发生变化。")
        # Re-read the completed binding before publishing it atomically.
        load_context(stage, library_path=library)
        require(not output.exists(), "本地配置输出目录在初始化期间发生变化。")
        os.rename(stage, output)
    return {"schema": SCHEMA, "status": "ready", "context": str(output),
            "contextManifest": str(output / "context.json"), "baseSha256": original_base_hash,
            "descriptorSha256": sha(live["descriptor"]), "cameraAccess": False}


def load_context(context_path=None, library_path=None):
    """Verify every bound local file before conversion or standalone preview."""
    directory = Path(context_path or default_context_path()).expanduser().resolve()
    if directory.name == "context.json":
        directory = directory.parent
    manifest_file = directory / "context.json"
    require(manifest_file.is_file(), "尚未初始化本机转换配置。请先导入自己的 Standard 基础 PF3 和只读相机快照，执行 setup-context。")
    raw = _require_file(manifest_file, maximum=1024 * 1024)
    try:
        manifest = json.loads(raw)
    except (ValueError, UnicodeError) as error:
        raise ValueError("本地转换配置清单无效，请重新初始化。") from error
    require(isinstance(manifest, dict) and manifest.get("schema") == SCHEMA,
            "本地转换配置版本无效，请重新初始化。")
    require(manifest.get("model") == "0x80000518" and manifest.get("firmware") == "1.1.2"
            and manifest.get("serializerType") == 10
            and manifest.get("parserSha256") == PARSER_SHA256
            and manifest.get("descriptorSha256") == DESCRIPTOR_SHA256,
            "本地配置不属于当前已验证的相机／固件／解析器范围。")
    base, _ = _bound_path(directory, manifest.get("base"))
    records = manifest.get("cameraFiles")
    require(isinstance(records, list) and len(records) == len(CAMERA_FILES), "本地配置的相机文件清单不完整。")
    paths = {}
    for record in records:
        path, _ = _bound_path(directory, record)
        require(path.name in CAMERA_FILES and path.parent == directory / "camera" and path.name not in paths,
                "本地配置的相机文件路径或记录无效。")
        paths[path.name] = path
    live = snapshot(directory / "camera")
    require(sha(live["settings"]) == manifest.get("settingsSha256"), "本地配置的基础设置校验失败。")
    require(struct.unpack_from("<H", live["readback"], 44)[0] == 0x81,
            "本地配置不是已注册的 Standard 基础风格。")
    library = _parser_path(library_path)
    return {"directory": directory, "manifest": manifest, "base": base,
            "camera": directory / "camera", "live": live, "library": library,
            "baseSha256": manifest["base"]["sha256"], "descriptorSha256": sha(live["descriptor"])}
