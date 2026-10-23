"""Reusable offline conversion API used by the CLI and desktop wrapper."""
import ctypes as C
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import struct
import tempfile

from .bridge import Parser, validate_table
from .cube import Cube, natural_key
from .colors import Adaptation, ColorAdapter
from .native import (HEADER_BYTES, LIBRARY, MODEL, PARSER_SHA256,
                     TABLES, Native, build_dense, require, sha, snapshot)

MUTABLE_PROPERTIES = {0x40001002, 0x40001070, 0x40001071}
MUTABLE_RECORDS = {0x1002, 0x1070, 0x1071}


def internal_title(path, source_hash, profile=None):
    stem = Path(path).stem
    slug = re.sub(r"[^A-Za-z0-9_-]+", "-", stem).strip("-_")[:14]
    if profile is not None and profile.mode != "none":
        prefix = "R6C2-" if profile.mode == "clog2" else "R6C3-"
        return (prefix + (slug or "LUT") + "-" + profile.identity_hash(source_hash)[:8])[:31]
    return ("R6LUT-" + (slug or "LUT") + "-" + source_hash[:8])[:31]


def compose_table(table, cube, adapter=None):
    validate_table(table)
    words = struct.unpack("<107811H", table[6:])
    values = []
    for at in range(0, len(words), 3):
        sample = tuple(value / 4095 for value in words[at:at + 3])
        rgb = cube.apply(sample) if adapter is None else adapter.apply(sample)
        values.extend(int(math.floor(value * 4095 + 0.5)) for value in rgb)
    result = table[:6] + struct.pack("<107811H", *values)
    validate_table(result)
    return result


def _metadata_validation(api, original_records, output_path, expected):
    actual = api.read(output_path)
    require(actual == expected, "PF3 API property round-trip differs")
    records = api.file_records(output_path.read_bytes())
    require([(key, kind) for key, kind, _ in records] ==
            [(key, kind) for key, kind, _ in original_records],
            "PF3 stored record inventory/order/type changed")
    changed, preserved = [], []
    for before, after in zip(original_records, records):
        key, kind, value = before
        if key in MUTABLE_RECORDS:
            changed.append("0x%04x" % key)
            continue
        require(before == after, "PF3 stored metadata changed: 0x%04x" % key)
        preserved.append({"id": "0x%04x" % key, "kind": kind,
                          "bytes": len(value), "sha256": sha(value)})
    return {"apiPropertiesRoundTripExact": True, "storedRecordInventoryExact": True,
            "storedRecordCount": len(records), "allStoredMetadataPreservedExact": True,
            "allowedMutableRecordIds": sorted(changed), "preservedRecords": preserved}


def _write_pf3(api, base_path, staged_path, properties, base_records):
    shutil.copyfile(base_path, staged_path)
    ref = api.open(staged_path, write=True)
    try:
        for prop in sorted(MUTABLE_PROPERTIES):
            api.set(ref, prop, properties[prop])
        api.call("ReflectProperty", ref)
    finally:
        api.call("Release", ref)
    return _metadata_validation(api, base_records, staged_path, properties)


def _sources(input_path):
    path = Path(input_path).resolve()
    if path.is_dir():
        paths = sorted((f for f in path.iterdir() if f.is_file() and f.suffix.casefold() == ".cube"),
                       key=lambda f: (natural_key(f), f.name.casefold(), f.name))
    elif path.is_file() and path.suffix.casefold() == ".cube":
        paths = [path]
    else:
        raise ValueError("Input must be a CUBE file or a directory containing CUBEs")
    require(paths, "No CUBE files in input directory")
    stems = [f.stem.casefold() for f in paths]
    require(len(stems) == len(set(stems)), "CUBE stems collide on case-insensitive filesystems")
    return paths


def convert(input_path, output_dir, base_path=None, camera_data=None, library_path=None, progress=None,
            adaptation="none", log_gamut="cinema-gamut", lut_output="srgb", context_path=None):
    """Convert a file/directory, validate all outputs, then publish a whole batch.

    Only EdsCFParse is loaded. This function never loads EDSDK, opens a camera
    session, invokes EOS Utility or installs a Picture Style.
    """
    emit = progress or (lambda event: None)
    profile = Adaptation(adaptation, log_gamut, lut_output)
    sources = _sources(input_path)
    output = Path(output_dir).resolve()
    from .context import load_context
    context = load_context(context_path, library_path)
    base, camera, library, live = (context[key] for key in ("base", "camera", "library", "live"))
    base_sha256 = context["baseSha256"]
    if base_path is not None:
        require(Path(base_path).resolve() == base, "Use --context rather than overriding its bound PF3.")
    if camera_data is not None:
        require(Path(camera_data).resolve() == camera, "Use --context rather than overriding its bound snapshot.")
    require(struct.unpack_from("<H", live["readback"], 44)[0] == 0x81,
            "Requires saved official Standard slot metadata")
    require(not output.exists() or (output.is_dir() and not any(output.iterdir())),
            "Output directory must be new or empty")
    # Parse the entire batch before any native compilation or publication.
    parsed = [(path, Cube.load(path)) for path in sources]
    api, rows = None, []
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".r6lut-stage-", dir=output.parent) as temporary:
        stage = Path(temporary)
        # Canon CreateRef on this parser rejects non-ASCII file paths (rc=2).
        # Keep all Canon file operations in an ASCII-only private workspace;
        # Unicode source/output names are handled by Python after validation.
        native_temp = tempfile.TemporaryDirectory(prefix="r6lut-native-", dir="/private/tmp")
        native_work = Path(native_temp.name)
        require(str(native_work).isascii(), "Native workspace path must be ASCII")
        native_base = native_work / "baseline.pf3"
        shutil.copyfile(base, native_base)
        try:
            api = Parser(library)
            base_properties = api.read(native_base)
            require(base_properties[0x114] == struct.pack("<I", 0x81), "Baseline is not Standard")
            require(base_properties[0x115] == live["settings"], "Baseline/settings mismatch")
            base_records = api.file_records(base.read_bytes())
            require(len(base_records) == 26, "Authentic baseline record inventory changed")
            native = Native(api)
            normal_base, checked_base, base_checks, _ = native.compile_normal(native_base, live)
            dense_base, base_tables = build_dense(normal_base, checked_base)
            require(all(t["normalNativeVsDense"]["maxSampleDelta"] <= 5 for t in base_tables),
                    "Baseline native/dense codec check failed")
            # Confirm the preserved official header after direction-specific
            # envelope normalization; this does not equate write/read bodies.
            header = bytearray(normal_base[:HEADER_BYTES])
            struct.pack_into("<I", header, 4, 83036)
            struct.pack_into("<I", header, 40, 83036)
            header[8:40] = bytes(32)
            require(bytes(header) == live["readback"][:HEADER_BYTES],
                    "Baseline header does not match saved official registration")
            for index, (source, cube) in enumerate(parsed, 1):
                source_bytes = source.read_bytes()
                source_hash = sha(source_bytes)
                require(source_hash == cube.input_sha256, "CUBE changed during conversion")
                title = internal_title(source, source_hash, profile)
                common = {"index": index, "total": len(parsed), "source": str(source),
                          "displayName": source.stem}
                emit(dict(event="progress", phase="compose", **common))
                properties = dict(base_properties)
                properties[0x40001002] = title.encode("ascii").ljust(32, b"\0")
                adapter = None if profile.mode == "none" else ColorAdapter(profile, cube)
                for prop, _, _ in TABLES:
                    properties[prop] = compose_table(base_properties[prop], cube, adapter)
                output_stem = profile.filename_prefix() + source.stem
                pf3_name, carrier_name, manifest_name = (output_stem + suffix for suffix in
                    (".pf3", ".full33.bin", ".manifest.json"))
                pf3 = native_work / ("item-%04d.pf3" % index)
                validation = _write_pf3(api, native_base, pf3, properties, base_records)
                emit(dict(event="progress", phase="compile", **common))
                normal, read_properties, checks, native_tables = native.compile_normal(pf3, live, base_properties)
                require(read_properties == properties, "Compiled PF3 properties changed")
                require(normal[372:] == normal_base[372:],
                        "Normal parameter-only body differs unexpectedly")
                dense, dense_tables = build_dense(normal, properties)
                require(normal[:372] == dense[:372], "Native header changed")
                (stage / carrier_name).write_bytes(dense)
                pf3_bytes = pf3.read_bytes()
                (stage / pf3_name).write_bytes(pf3_bytes)
                validation.update({"sourceCubeUnchanged": source.read_bytes() == source_bytes,
                    "basePf3Unchanged": sha(base.read_bytes()) == base_sha256,
                    "gridsFiniteAndBounded": True, "full33HeaderPreservedExact": True,
                    "canonPf3PathsAsciiOnly": True,
                    "normalNativeBodyIgnoresDenseSourceOnlyChanges": True,
                    "modelAliasUsed": False, "serializerType": 10,
                    "baselineNativeVsDenseMaxDelta": [t["normalNativeVsDense"]["maxSampleDelta"] for t in base_tables]})
                require(validation["sourceCubeUnchanged"], "Source CUBE changed")
                manifest = {"schema": "r6lut-candidate-v1", "model": "0x80000518", "firmware": "1.1.2",
                    "status": "offline_validated_candidate", "cameraAccess": False,
                    "requiresOwnInstaller": True, "ordinaryEosUtilityPf3RegistrationAppliesDenseLut": False,
                    "serializerType": 10, "modelAliasUsed": False, "vtableHookUsed": False,
                    "compactCipherAppliedToTables": False, "nativeMetadataPreservedExact": True,
                    "sourcePf3Unchanged": True,
                    "adaptation": profile.describe() if adapter is None else adapter.summary(),
                    "slotControl": 65, "baseStyle": 0x81, "settingsHex": properties[0x115].hex(),
                    "settings": {"bytes": 32, "hex": properties[0x115].hex(), "sha256": sha(properties[0x115])},
                    "installationScope": "User-owned validated R6 III 1.1.2 context; explicit installer slot selection required",
                    "source": {"path": str(source), "filename": source.name, "sha256": source_hash,
                               "cubeSize": cube.size, "domainMin": cube.domain_min, "domainMax": cube.domain_max,
                               "cubeOutputMin": cube.output_min, "cubeOutputMax": cube.output_max,
                               "cubeOutputClippedToUnitRange": cube.out_of_range},
                    "title": title, "pf3": {"file": pf3_name, "bytes": len(pf3_bytes), "sha256": sha(pf3_bytes)},
                    "full33": {"file": carrier_name, "bytes": len(dense), "sha256": sha(dense)},
                    "provenance": {"baseSha256": base_sha256, "parserSha256": PARSER_SHA256,
                                   "realModel": "0x80000518", "firmware": "1.1.2",
                                   "descriptorSha256": context["descriptorSha256"], "settingsSha256": sha(live["settings"]),
                                   "cameraData": str(camera), "contextSchema": context["manifest"]["schema"]},
                    "validation": validation, "realModelChecks": checks,
                    "nativeTables": native_tables, "denseTables": dense_tables,
                    "normalNativeSha256": sha(normal), "baseRealModelChecks": base_checks,
                    "notes": "PF3 alone registered by ordinary EOS Utility regenerates Canon parameter tables; install the accompanying full33 carrier with this tool."}
                (stage / manifest_name).write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
                rows.append(dict(event="converted", title=title,
                                 adaptationMode=profile.mode, profileLabel=profile.describe()["profileLabel"],
                                 pf3=str(output / pf3_name),
                                 full33=str(output / carrier_name), manifest=str(output / manifest_name),
                                 pf3Sha256=sha(pf3_bytes), full33Sha256=sha(dense), **common))
            batch = {"schema": "r6lut-batch-v1", "status": "ready", "count": len(rows),
                     "output": str(output), "manifest": str(output / "batch-manifest.json"),
                     "files": rows, "requiresOwnInstaller": True,
                     "ordinaryEosUtilityPf3RegistrationAppliesDenseLut": False,
                     "adaptation": profile.describe(),
                     "model": "0x80000518", "firmware": "1.1.2"}
            (stage / "batch-manifest.json").write_text(json.dumps(batch, ensure_ascii=False, indent=2) + "\n")
            require(not output.exists() or not any(output.iterdir()), "Output changed while conversion ran")
            if output.exists():
                output.rmdir()
            os.rename(stage, output)
            # TemporaryDirectory cleanup tolerates its staged directory moving.
            for row in rows:
                emit(row)
            emit(dict(event="batch_summary", **batch))
            return batch
        finally:
            try:
                if api is not None:
                    api.call("Terminate")
            finally:
                native_temp.cleanup()
