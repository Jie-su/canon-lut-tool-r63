"""Experimental photographic CLog adaptation; no PF3-domain calibration claim.

Canon Log coefficients: Canon, "Canon Log Gamma Curves", 2018, pp. 8-9:
https://www.usa.canon.com/content/dam/canon-assets/white-papers/pro/white-paper-canon-log-gamma-curves.pdf
Cinema Gamut primaries/D65 reference implementation (Canon C500 source):
https://github.com/colour-science/colour/blob/develop/colour/models/rgb/datasets/canon_cinema_gamut.py

The numeric transfer functions are defined; treating PF3 table values as sRGB
display values and decoded values as scene reflection is an explicit heuristic.
"""
from dataclasses import dataclass
import hashlib
import json
import math


D65 = (0.3127, 0.3290)
PRIMARIES = {
    "bt709": ((0.640, 0.330), (0.300, 0.600), (0.150, 0.060)),
    "bt2020": ((0.708, 0.292), (0.170, 0.797), (0.131, 0.046)),
    "cinema-gamut": ((0.740, 0.270), (0.170, 1.140), (0.080, -0.100)),
}
GAMUT_LABELS = {"bt709": "BT709", "bt2020": "BT2020", "cinema-gamut": "CinemaGamut"}


def _finite(value):
    if not math.isfinite(value):
        raise ValueError("Color component must be finite")
    return value


def srgb_decode(value):
    value = _finite(value)
    return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4


def srgb_encode(value):
    value = _finite(value)
    return 12.92 * value if value <= 0.0031308 else 1.055 * value ** (1 / 2.4) - 0.055


def canon_log_encode(reflection, mode):
    """Normalized full-code Canon Log; input reflection is scene x * 0.9.

    This exposes the white-paper reflection convention: 18% reflection uses
    scene x=0.2. It does not convert full-code values into legal-range values.
    """
    x = _finite(reflection) / 0.9
    if mode == "clog2":
        a, b, c = 0.24136077, 87.099375, 0.092864125
        return -a * math.log10(1 - b*x) + c if x < 0 else a * math.log10(1 + b*x) + c
    if mode == "clog3":
        if x < -0.014:
            return -0.36726845 * math.log10(1 - 14.98325*x) + 0.12783901
        if x <= 0.014:
            return 1.9754798*x + 0.12512219
        return 0.36726845 * math.log10(1 + 14.98325*x) + 0.12240537
    raise ValueError("Unsupported Canon Log curve")


def canon_log_decode(code, mode):
    code = _finite(code)
    if mode == "clog2":
        a, b, c = 0.24136077, 87.099375, 0.092864125
        x = (1 - 10 ** ((c-code)/a))/b if code < c else (10 ** ((code-c)/a)-1)/b
    elif mode == "clog3":
        lower = 1.9754798 * -0.014 + 0.12512219
        upper = 1.9754798 * 0.014 + 0.12512219
        if code < lower:
            x = (1 - 10 ** ((0.12783901-code)/0.36726845)) / 14.98325
        elif code <= upper:
            x = (code - 0.12512219) / 1.9754798
        else:
            x = (10 ** ((code-0.12240537)/0.36726845) - 1) / 14.98325
    else:
        raise ValueError("Unsupported Canon Log curve")
    return x * 0.9


def matvec(matrix, vector):
    return tuple(sum(row[c] * vector[c] for c in range(3)) for row in matrix)


def matmul(a, b):
    return tuple(tuple(sum(a[r][k] * b[k][c] for k in range(3)) for c in range(3)) for r in range(3))


def inverse(matrix):
    rows = [list(row) + [float(r == c) for c in range(3)] for r, row in enumerate(matrix)]
    for col in range(3):
        pivot = max(range(col, 3), key=lambda r: abs(rows[r][col]))
        if abs(rows[pivot][col]) < 1e-15:
            raise ValueError("Singular primary matrix")
        rows[col], rows[pivot] = rows[pivot], rows[col]
        divisor = rows[col][col]
        rows[col] = [value / divisor for value in rows[col]]
        for r in range(3):
            if r == col: continue
            multiplier = rows[r][col]
            rows[r] = [x - multiplier*y for x, y in zip(rows[r], rows[col])]
    return tuple(tuple(row[3:]) for row in rows)


def rgb_to_xyz(gamut):
    if gamut not in PRIMARIES:
        raise ValueError("Unsupported input gamut")
    columns = tuple((x/y, 1.0, (1-x-y)/y) for x, y in PRIMARIES[gamut])
    unscaled = tuple(tuple(columns[c][r] for c in range(3)) for r in range(3))
    xw, yw = D65
    white = (xw/yw, 1.0, (1-xw-yw)/yw)
    scales = matvec(inverse(unscaled), white)
    return tuple(tuple(unscaled[r][c]*scales[c] for c in range(3)) for r in range(3))


def gamut_matrix(source, target):
    if source == target:
        if source not in PRIMARIES: raise ValueError("Unsupported gamut")
        return ((1., 0., 0.), (0., 1., 0.), (0., 0., 1.))
    return matmul(inverse(rgb_to_xyz(target)), rgb_to_xyz(source))


@dataclass(frozen=True)
class Adaptation:
    mode: str = "none"
    log_gamut: str = "cinema-gamut"
    lut_output: str = "srgb"

    def __post_init__(self):
        if self.mode not in ("none", "clog2", "clog3"):
            raise ValueError("Adaptation must be none, clog2 or clog3")
        if self.log_gamut not in PRIMARIES:
            raise ValueError("Unsupported Log input gamut")
        if self.lut_output not in ("srgb", "gamma24", "same-log"):
            raise ValueError("LUT output must be srgb, gamma24 or same-log")

    def parameters(self):
        return {"mode": self.mode, "logGamut": self.log_gamut, "lutOutput": self.lut_output}

    def token(self):
        return {"clog2": "CLog2", "clog3": "CLog3", "none": "Direct"}[self.mode]

    def filename_prefix(self):
        if self.mode == "none": return ""
        output = {"srgb": "OutsRGB", "gamma24": "OutGamma24", "same-log": "OutSameLog"}[self.lut_output]
        return self.token() + "-" + GAMUT_LABELS[self.log_gamut] + "-" + output + "__"

    def identity_hash(self, source_hash):
        raw = source_hash + json.dumps(self.parameters(), sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(raw.encode("ascii")).hexdigest()

    def describe(self):
        if self.mode == "none":
            return {"mode": "none", "status": "direct_numeric_composition",
                    "profileLabel": "直接转换（不进行 Log 输入适配）", "internalPf3DomainCalibrated": False}
        output = {"srgb": "sRGB 输出假设", "gamma24": "BT.709 原色 / Gamma 2.4 输出假设",
                  "same-log": "同曲线 / 同色域 Log 输出假设"}[self.lut_output]
        return {**self.parameters(), "status": "experimental_photographic_approximation",
                "profileLabel": "实验 " + self.token() + " · " + GAMUT_LABELS[self.log_gamut] + " · " + output,
                "internalPf3DomainCalibrated": False, "inputGamutVerifiedForSourceCube": False,
                "lutOutputEncodingVerifiedForSourceCube": False,
                "whitepoint": {"name": "D65", "xy": list(D65)},
                "sourceDisplayAssumption": "PF3 Standard table numeric RGB is treated as sRGB display-encoded RGB",
                "reflectionAssumption": "sRGB-decoded linear BT.709 RGB is treated as scene reflection; Canon scene x=reflection/0.9",
                "logCodeRange": "normalized full code values; no full/legal-range remapping",
                "lutOutputPrimariesAssumption": self.log_gamut + " / D65" if self.lut_output == "same-log" else "BT.709 / D65",
                "lutOutputTransfer": {"srgb": "sRGB passthrough",
                                      "gamma24": "pure gamma 2.4 decode followed by sRGB encode; not Rec.709 OETF or full BT.1886",
                                      "same-log": "selected Canon Log decode to reflection, selected gamut to BT.709, final linear clamp then sRGB encode"}[self.lut_output],
                "linearBt709ToLogGamutMatrix": gamut_matrix("bt709", self.log_gamut),
                "assumptions": ["PF3 internal numerical domain has not been calibrated as sRGB",
                                "This cannot reverse Canon's rendering or recover clipped scene highlights",
                                "Source CUBE curve, gamut, output encoding and exposure intent must be confirmed separately",
                                "This does not enable Log recording or reproduce the author's look exactly"],
                "references": ["https://www.usa.canon.com/content/dam/canon-assets/white-papers/pro/white-paper-canon-log-gamma-curves.pdf",
                               "https://github.com/colour-science/colour/blob/develop/colour/models/rgb/datasets/canon_cinema_gamut.py"]}


class ColorAdapter:
    def __init__(self, config, cube):
        if config.mode == "none":
            raise ValueError("ColorAdapter is only used for explicit CLog adaptation")
        self.config, self.cube = config, cube
        self.matrix = gamut_matrix("bt709", config.log_gamut)
        self.inverse_matrix = gamut_matrix(config.log_gamut, "bt709")
        self.count = 0
        self.input_domain_clipped = 0
        self.output_clipped = 0
        self.final_linear_clipped = 0
        self.log_min, self.log_max = [math.inf]*3, [-math.inf]*3
        self.output_min, self.output_max = [math.inf]*3, [-math.inf]*3

    def apply(self, rgb):
        reflection = matvec(self.matrix, tuple(srgb_decode(x) for x in rgb))
        encoded = tuple(canon_log_encode(value, self.config.mode) for value in reflection)
        for c, value in enumerate(encoded):
            self.log_min[c] = min(self.log_min[c], value)
            self.log_max[c] = max(self.log_max[c], value)
            if value < self.cube.domain_min[c] or value > self.cube.domain_max[c]:
                self.input_domain_clipped += 1
        raw = self.cube.sample(encoded)
        if self.config.lut_output == "same-log":
            # Retain signed values through Log decoding and inverse gamut.
            # Clipping channels before the matrix would change hue and neutrals.
            for c, value in enumerate(raw):
                self.output_min[c] = min(self.output_min[c], value)
                self.output_max[c] = max(self.output_max[c], value)
                if value < 0 or value > 1: self.output_clipped += 1
            try:
                reflection_out = tuple(canon_log_decode(value, self.config.mode) for value in raw)
            except OverflowError as error:
                raise ValueError("CUBE output exceeds finite Canon Log decoding range") from error
            linear709 = matvec(self.inverse_matrix, reflection_out)
            result = []
            for value in linear709:
                _finite(value)
                if value < -1e-12 or value > 1 + 1e-12: self.final_linear_clipped += 1
                result.append(srgb_encode(max(0.0, min(1.0, value))))
            self.count += 1
            return tuple(result)
        output = []
        for c, value in enumerate(raw):
            self.output_min[c] = min(self.output_min[c], value)
            self.output_max[c] = max(self.output_max[c], value)
            if value < 0 or value > 1: self.output_clipped += 1
            value = max(0.0, min(1.0, value))
            if self.config.lut_output == "gamma24":
                value = srgb_encode(value ** 2.4)
            output.append(value)
        self.count += 1
        return tuple(output)

    def summary(self):
        description = self.config.describe()
        description["clipping"] = {"sampledRgbNodes": self.count, "sampledComponents": self.count*3,
                                    "logInputOutsideCubeDomainComponents": self.input_domain_clipped,
                                    "interpolatedCubeOutputOutsideUnitRangeComponents": self.output_clipped,
                                    "interpolatedCubeOutputClampedBeforeOutputDecode": self.config.lut_output != "same-log",
                                    "finalLinearBt709OutsideUnitRangeComponents": self.final_linear_clipped,
                                    "finalLinearClipCounterTolerance": 1e-12,
                                    "logInputMin": self.log_min, "logInputMax": self.log_max,
                                    "interpolatedCubeOutputMin": self.output_min,
                                    "interpolatedCubeOutputMax": self.output_max}
        return description
