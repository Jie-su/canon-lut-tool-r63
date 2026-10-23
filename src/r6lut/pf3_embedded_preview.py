"""Read this tool's embedded PF3 RGB grid for a photographic approximation.

These files deliberately replace dense grids while preserving PSE parameters.
Canon's parameter-to-ICC compiler does not consume those replacement grids.
This path therefore reads the selected PF3 itself, without reopening its CUBE.
It does not open a camera or claim to reproduce Canon RAW development.
"""
from array import array
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile

from .bridge import Parser, validate_table
from .native import (DESCRIPTOR_SHA256, LIBRARY, PARSER_SHA256, PAYLOAD_BYTES, TABLE_BYTES,
                     encode_full33)

_PREFIXES = ("R6LUT-", "R6C2-", "R6C3-")
_MUTABLE_RECORDS = {0x1002, 0x1070, 0x1071}
_MUTABLE_PROPERTIES = {0x40001002, 0x40001070, 0x40001071}


def _sha(raw):
    return hashlib.sha256(raw).hexdigest()


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _title(value):
    _require(len(value) == 32, "PF3 内部名称长度无效。")
    text = value.split(b"\0", 1)[0]
    _require(text and value == text.ljust(32, b"\0"), "PF3 内部名称格式无效。")
    return text.decode("ascii", errors="strict")


def _validated_manifest(path, source_bytes, properties, title):
    """Require every companion binding; never silently fall back after damage."""
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
        _require(isinstance(manifest, dict) and manifest.get("schema") == "r6lut-candidate-v1",
                 "配套清单格式不是 r6lut-candidate-v1。")
        _require(manifest.get("model") == "0x80000518" and manifest.get("firmware") == "1.1.2"
                 and manifest.get("serializerType") == 10
                 and manifest.get("modelAliasUsed") is False
                 and manifest.get("vtableHookUsed") is False
                 and manifest.get("compactCipherAppliedToTables") is False,
                 "配套清单不属于已验证的 R6 III full33 格式。")
        provenance = manifest.get("provenance")
        _require(isinstance(provenance, dict)
                 and provenance.get("parserSha256") == PARSER_SHA256
                 and provenance.get("descriptorSha256") == DESCRIPTOR_SHA256,
                 "配套清单的解析器或机型兼容信息不匹配。")
        base_hash = provenance.get("baseSha256")
        _require(isinstance(base_hash, str) and len(base_hash) == 64
                 and all(c in "0123456789abcdef" for c in base_hash),
                 "配套清单缺少基础 PF3 绑定。")
        pf3 = manifest["pf3"]
        full33 = manifest["full33"]
        _require(isinstance(pf3, dict) and isinstance(full33, dict), "配套清单的文件绑定无效。")
        _require(pf3["sha256"] == _sha(source_bytes) and pf3["bytes"] == len(source_bytes),
                 "PF3 与配套清单的文件校验不一致。")
        _require(manifest["title"] == title, "PF3 与清单的内部名称不一致。")
        _require(manifest["baseStyle"] == struct.unpack("<I", properties[0x114])[0],
                 "PF3 与清单的基础风格不一致。")
        settings = manifest.get("settings", {})
        _require(isinstance(settings, dict), "配套清单的基础参数记录无效。")
        settings_hex = manifest.get("settingsHex", settings.get("hex"))
        _require(settings_hex == properties[0x115].hex(), "PF3 与清单的基础参数不一致。")
        if settings:
            _require(settings.get("bytes") == len(properties[0x115])
                     and settings.get("hex") == properties[0x115].hex()
                     and settings.get("sha256") == _sha(properties[0x115]),
                     "PF3 基础参数的配套校验不一致。")
        filename = full33["file"]
        _require(isinstance(filename, str) and filename and Path(filename).name == filename
                 and filename not in (".", ".."), "配套载荷必须保存在 PF3 同一文件夹。")
        carrier_path = path.parent / filename
        _require(carrier_path.is_file(), "找不到配套 full33 载荷，请将配套文件保存在一起。")
        carrier = carrier_path.read_bytes()
        _require(full33["bytes"] == len(carrier) == PAYLOAD_BYTES
                 and full33["sha256"] == _sha(carrier), "配套 full33 载荷校验未通过。")
        _require(struct.unpack_from("<II", carrier) == (1, PAYLOAD_BYTES - 40)
                 and struct.unpack_from("<I", carrier, 40)[0] == PAYLOAD_BYTES - 40,
                 "配套 full33 载荷头无效。")
        _require(carrier[8:40] == properties[0x40001002]
                 and carrier[46:78] == properties[0x40001002]
                 and carrier[44:46] == properties[0x114][:2],
                 "配套 full33 与 PF3 的名称或基础风格不一致。")
        _require(carrier[80:96] == properties[0x115][:16]
                 and carrier[104:112] == properties[0x115][24:32],
                 "配套 full33 与 PF3 的基础参数不一致。")
        for prop, offset in ((0x40001070, 372), (0x40001071, 215994)):
            _require(encode_full33(properties[prop]) == carrier[offset:offset + TABLE_BYTES],
                     "配套 full33 与 PF3 内嵌色表不一致。")
        return manifest, {"manifestSha256": _sha(path.read_bytes()),
                          "full33Sha256": _sha(carrier), "companionBindingsVerified": True}
    except (OSError, KeyError, TypeError, ValueError, struct.error) as error:
        raise ValueError("PF3 配套清单或载荷校验失败；没有改用会丢失内嵌效果的参数预览。\n" + str(error)) from error


def prepare_embedded_pf3_lookup(input_path, output_path, context_path=None):
    """Return metadata and create a lookup for our dense PF3, otherwise None.

    A paired manifest must bind the selected PF3 and both full33 grids. No
    original CUBE or bundled camera data is needed. Without a manifest, a
    local user context is required to compare preserved baseline metadata.
    Ordinary PSE presets are classified without consulting a local context.
    On None, no output directory is created. The caller adds photoSha256 and
    writes metadata.json before publishing the preview directory.
    """
    source = Path(input_path).resolve()
    destination = Path(output_path)
    source_bytes = source.read_bytes()
    manifest_path = source.with_suffix(".manifest.json")
    # Ordinary native PF3s may not have all the same optional properties as our
    # baseline. Read only their name until they are identified as our format.
    _require(LIBRARY.is_file() and _sha(LIBRARY.read_bytes()) == PARSER_SHA256,
             "需要本机已验证版本的 Canon EOS Utility 3 PF3 解析组件。")
    api = None
    properties = None
    manifest = None
    bindings = {"companionBindingsVerified": False}
    with tempfile.TemporaryDirectory(prefix="r6lut-pf3-grid-", dir="/private/tmp") as temporary:
        native_source = Path(temporary) / "source.pf3"
        native_source.write_bytes(source_bytes)
        try:
            api = Parser(LIBRARY)
            source_records = api.file_records(source_bytes)
            reference = api.open(native_source)
            try:
                raw_title = api.get(reference, 0x40001002)
            finally:
                api.call("Release", reference)
            try:
                title = _title(raw_title)
            except (UnicodeError, ValueError):
                # Let the native parameter renderer diagnose ordinary PSE files.
                return None
            is_candidate = title.startswith(_PREFIXES)
            if not is_candidate:
                if manifest_path.is_file():
                    try:
                        candidate_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                    except (OSError, ValueError):
                        candidate_manifest = None
                    if isinstance(candidate_manifest, dict) and candidate_manifest.get("schema") == "r6lut-candidate-v1":
                        raise ValueError("配套清单标为本工具生成，但 PF3 内部名称不匹配；请检查文件是否混放。")
                return None
            properties = api.read(native_source)
            for prop in (0x40001070, 0x40001071):
                validate_table(properties[prop])
            if manifest_path.exists():
                manifest, bindings = _validated_manifest(manifest_path, source_bytes, properties, title)
            else:
                from .context import load_context
                try:
                    context = load_context(context_path)
                except (ValueError, OSError) as error:
                    raise ValueError("这份 PF3 包含工具内嵌色表。请同时提供配套 .manifest.json 和 .full33.bin，或先初始化匹配的本地转换配置；不需要原 CUBE。") from error
                baseline = context["base"]
                native_baseline = Path(temporary) / "baseline.pf3"
                native_baseline.write_bytes(baseline.read_bytes())
                baseline_properties = api.read(native_baseline)
                baseline_records = api.file_records(baseline.read_bytes())
                _require([(key, kind) for key, kind, _ in source_records] ==
                         [(key, kind) for key, kind, _ in baseline_records],
                         "这份 PF3 的记录结构与本地基础风格不一致。")
                _require(all(a == b for a, b in zip(source_records, baseline_records)
                             if a[0] not in _MUTABLE_RECORDS),
                         "这份 PF3 的基础元数据与本地配置不一致，请提供原配套清单。")
                _require(all(value == baseline_properties[key] for key, value in properties.items()
                             if key not in _MUTABLE_PROPERTIES),
                         "这份 PF3 的基础调色参数与本地配置不一致，请提供原配套清单。")
                bindings["localContextBaselineVerified"] = True

        finally:
            if api is not None:
                api.call("Terminate")
    _require(source.read_bytes() == source_bytes, "PF3 在预览准备期间发生变化，请重新选择。")
    _require(not destination.exists() or (destination.is_dir() and not any(destination.iterdir())),
             "PF3 预览输出目录必须是新目录或空目录。")
    words = struct.unpack("<107811H", properties[0x40001070][6:])
    values = array("f")
    # Source grids: R outer / G middle / B inner; viewer lookup: R fastest.
    for blue in range(33):
        for green in range(33):
            for red in range(33):
                at = ((red * 33 + green) * 33 + blue) * 3
                values.extend((words[at] / 4095, words[at + 1] / 4095,
                               words[at + 2] / 4095, 1.0))
    if sys.byteorder != "little":
        values.byteswap()
    raw = values.tobytes()
    destination.mkdir(parents=True, exist_ok=True)
    lookup = {"schema": "r6lut-srgb-preview-v1", "size": 33,
              "source": str(source), "sourceSha256": _sha(source_bytes),
              "storage": "float32-le-rgba-red-fastest", "bytes": len(raw),
              "sha256": _sha(raw), "inputEncoding": "sRGB display code values (photographic approximation)",
              "outputEncoding": "sRGB display code values (photographic approximation)",
              "sourceProperty": "0x40001070", "adaptationAlreadyBaked": True}
    (destination / "lookup.rgba32f").write_bytes(raw)
    (destination / "lookup.json").write_text(json.dumps(lookup, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return {"schema": "r6lut-pf3-preview-v1", "renderMode": "embedded-lut",
            "pf3Sha256": _sha(source_bytes), "label": "PF3 内嵌色表近似预览",
            "method": "Read selected PF3 property 0x40001070; 33-cubed RGB/12-bit grid; photographic sRGB approximation, not Canon RAW simulation",
            "title": title, "sourceUnchanged": True, "cameraAccess": False,
            "sourceCubeRequired": False, "adaptationAlreadyBaked": True,
            "nativeBaselineMetadataVerified": bindings.get("localContextBaselineVerified", False), "nativeRecordChecksumVerified": True,
            "lookupSha256": _sha(raw), "profileLabel": ((manifest or {}).get("adaptation") or {}).get("profileLabel") if isinstance((manifest or {}).get("adaptation", {}), dict) else None,
            **bindings}
