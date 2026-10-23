"""Display-encoded sRGB preview lookup, reusing the converter's color pipeline.

This is not a Canon RAW developer or a prediction of PF3 camera rendering.
The native viewer first color-manages decoded photographs into sRGB, then
interpolates this lookup in sRGB *code values*, not linear-light Core Image RGB.
"""
from array import array
import hashlib
import json
from pathlib import Path
import sys

from .colors import Adaptation, ColorAdapter
from .cube import Cube


def make_preview_lut(input_path, output_path, adaptation="none", log_gamut="cinema-gamut",
                     lut_output="gamma24", size=65):
    if size not in (17, 33, 65):
        raise ValueError("Preview size must be 17, 33 or 65")
    source = Path(input_path).resolve()
    destination = Path(output_path)
    if destination.exists():
        raise ValueError("Preview destination already exists")
    config = Adaptation(adaptation, log_gamut, lut_output)
    cube = Cube.load(source)
    apply = cube.apply if config.mode == "none" else ColorAdapter(config, cube).apply
    data = array("f")
    # Shared CUBE convention: R changes fastest, followed by G and B.
    for b in range(size):
        for g in range(size):
            for r in range(size):
                data.extend((*apply((r / (size-1), g / (size-1), b / (size-1))), 1.0))
    if sys.byteorder != "little":
        data.byteswap()
    raw = data.tobytes()
    destination.mkdir(parents=True)
    (destination / "lookup.rgba32f").write_bytes(raw)
    metadata = {
        "schema": "r6lut-srgb-preview-v1", "size": size,
        "source": str(source), "sourceSha256": cube.input_sha256,
        "inputEncoding": "sRGB display code values", "outputEncoding": "sRGB display code values",
        "storage": "float32-le-rgba-red-fastest", "bytes": len(raw),
        "sha256": hashlib.sha256(raw).hexdigest(), "adaptation": config.describe(),
        "scope": "Resampled photographic approximation; does not simulate Canon RAW development or PF3 rendering",
    }
    (destination / "lookup.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
    return metadata
