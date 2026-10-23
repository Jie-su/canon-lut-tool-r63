"""Strict 3D CUBE reader and trilinear interpolation; Python standard library."""
from dataclasses import dataclass
import hashlib
import math
from pathlib import Path
import re
import shlex


def natural_key(path):
    text = Path(path).name.casefold()
    return tuple((1, int(part)) if part.isdecimal() else (0, part)
                 for part in re.split(r"(\d+)", text))


@dataclass(frozen=True)
class Cube:
    size: int
    domain_min: tuple
    domain_max: tuple
    data: tuple
    title: str = ""
    input_sha256: str = ""

    @classmethod
    def load(cls, path):
        raw = Path(path).read_bytes()
        if len(raw) > 160 * 1024 * 1024:
            raise ValueError("CUBE input exceeds 160 MiB")
        cube = cls.parse(raw.decode("utf-8-sig"))
        return cls(cube.size, cube.domain_min, cube.domain_max, cube.data,
                   cube.title, hashlib.sha256(raw).hexdigest())

    @classmethod
    def parse(cls, text):
        size, title, lower, upper = None, "", (0.0,) * 3, (1.0,) * 3
        seen, rows, data_started = set(), [], False
        for line_number, line in enumerate(text.splitlines(), 1):
            tokens = shlex.split(line, comments=True, posix=True)
            if not tokens:
                continue
            key = tokens[0].upper()
            if key in ("TITLE", "LUT_3D_SIZE", "DOMAIN_MIN", "DOMAIN_MAX"):
                if key in seen or data_started:
                    raise ValueError("Duplicate or late CUBE directive at line %d" % line_number)
                seen.add(key)
                if key == "TITLE":
                    if len(tokens) != 2:
                        raise ValueError("TITLE needs one quoted value")
                    title = tokens[1]
                elif key == "LUT_3D_SIZE":
                    if len(tokens) != 2 or not tokens[1].isdecimal():
                        raise ValueError("Invalid LUT_3D_SIZE")
                    size = int(tokens[1])
                    if not 2 <= size <= 129:
                        raise ValueError("LUT_3D_SIZE must be 2..129")
                else:
                    if len(tokens) != 4:
                        raise ValueError("DOMAIN requires three finite values")
                    values = tuple(float(x) for x in tokens[1:])
                    if not all(math.isfinite(x) for x in values):
                        raise ValueError("CUBE domain is not finite")
                    if key == "DOMAIN_MIN": lower = values
                    else: upper = values
                continue
            if size is None:
                raise ValueError("CUBE data before LUT_3D_SIZE at line %d" % line_number)
            if len(tokens) != 3:
                raise ValueError("Expected RGB data at line %d" % line_number)
            try:
                values = tuple(float(x) for x in tokens)
            except ValueError as error:
                raise ValueError("Unsupported CUBE directive/data at line %d" % line_number) from error
            if not all(math.isfinite(x) for x in values):
                raise ValueError("CUBE data is not finite at line %d" % line_number)
            rows.append(values)
            data_started = True
            if len(rows) > size ** 3:
                raise ValueError("CUBE contains too many rows")
        if size is None or len(rows) != size ** 3:
            raise ValueError("CUBE row count must equal LUT_3D_SIZE cubed")
        if not all(hi > lo for lo, hi in zip(lower, upper)):
            raise ValueError("Each DOMAIN_MAX must exceed DOMAIN_MIN")
        return cls(size, lower, upper, tuple(rows), title)

    @property
    def output_min(self):
        return tuple(min(row[c] for row in self.data) for c in range(3))

    @property
    def output_max(self):
        return tuple(max(row[c] for row in self.data) for c in range(3))

    @property
    def out_of_range(self):
        return any(x < 0 or x > 1 for row in self.data for x in row)

    def sample(self, rgb):
        """Trilinear sample with DOMAIN input clamping, before output clipping."""
        if len(rgb) != 3 or not all(math.isfinite(v) for v in rgb):
            raise ValueError("Expected finite RGB input")
        coords = [max(0.0, min(1.0, (v - lo) / (hi - lo))) * (self.size - 1)
                  for v, lo, hi in zip(rgb, self.domain_min, self.domain_max)]
        lower = [int(math.floor(v)) for v in coords]
        upper = [min(v + 1, self.size - 1) for v in lower]
        fraction = [v - lo for v, lo in zip(coords, lower)]
        result = [0.0, 0.0, 0.0]
        # CUBE file order: red changes fastest, then green, then blue.
        for bz in (0, 1):
            b = upper[2] if bz else lower[2]
            wb = fraction[2] if bz else 1 - fraction[2]
            for gy in (0, 1):
                g = upper[1] if gy else lower[1]
                wg = fraction[1] if gy else 1 - fraction[1]
                for rx in (0, 1):
                    r = upper[0] if rx else lower[0]
                    wr = fraction[0] if rx else 1 - fraction[0]
                    value = self.data[(b * self.size + g) * self.size + r]
                    weight = wr * wg * wb
                    for c in range(3):
                        result[c] += value[c] * weight
        return tuple(result)

    def apply(self, rgb):
        return tuple(max(0.0, min(1.0, value)) for value in self.sample(rgb))
