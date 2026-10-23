"""Math/format tests use no Canon libraries and no devices."""
import math
from pathlib import Path
import struct
import unittest

from .cube import Cube, natural_key
from .convert import compose_table, internal_title
from .native import encode_full33


def cube_text(transform, size=2, domain=None):
    lines = ["TITLE \"test # title\"", "LUT_3D_SIZE %d" % size]
    if domain:
        lines += ["DOMAIN_MIN " + " ".join(map(str, domain[0])),
                  "DOMAIN_MAX " + " ".join(map(str, domain[1]))]
    for b in range(size):
        for g in range(size):
            for r in range(size):
                lines.append(" ".join("%.17g" % x for x in transform(r/(size-1), g/(size-1), b/(size-1))))
    return "\n".join(lines)


class CubeTests(unittest.TestCase):
    def test_identity_red_fastest_and_edges(self):
        cube = Cube.parse(cube_text(lambda r, g, b: (r, g, b)))
        self.assertEqual(cube.data[1], (1., 0., 0.))
        for point in [(0., 0., 0.), (1., 1., 1.), (.137, .427, .821), (1., .2, 0.)]:
            for actual, expected in zip(cube.apply(point), point):
                self.assertAlmostEqual(actual, expected, places=14)

    def test_nonseparable_and_nondefault_domain(self):
        domain = ((.1, .2, .3), (.9, .8, .7))
        cube = Cube.parse(cube_text(lambda r, g, b: (r*g, g*b, r*b), domain=domain))
        for point in [(.3, .5, .6), (.5, .35, .4), (1., 0., 2.)]:
            t = [max(0., min(1., (x-lo)/(hi-lo))) for x, lo, hi in zip(point, *domain)]
            expected = (t[0]*t[1], t[1]*t[2], t[0]*t[2])
            for actual, wanted in zip(cube.apply(point), expected):
                self.assertAlmostEqual(actual, wanted, places=14)

    def test_source_grid_composition_identity_swap(self):
        # Input values deliberately do not follow spatial grid coordinates.
        words = [(node * 37 + c * 751) % 4096 for node in range(33**3) for c in range(3)]
        table = struct.pack("<3H", 12, 3, 33) + struct.pack("<107811H", *words)
        identity = Cube.parse(cube_text(lambda r, g, b: (r, g, b)))
        swap = Cube.parse(cube_text(lambda r, g, b: (b, g, r)))
        self.assertEqual(compose_table(table, identity), table)
        result = struct.unpack("<107811H", compose_table(table, swap)[6:])
        for at in range(0, len(words), 3):
            self.assertEqual(result[at:at+3], tuple(reversed(words[at:at+3])))
        packed = encode_full33(table)
        planar = struct.unpack("<107811H", packed)
        for channel in range(3):
            for node in (0, 1, 123, 35936):
                self.assertEqual(planar[channel*33**3+node],
                                 (words[node*3+channel]*32768+2047)//4095)

    def test_clipping_and_finite_rejection(self):
        cube = Cube.parse(cube_text(lambda r, g, b: (-1., 2., .5)))
        self.assertTrue(cube.out_of_range)
        self.assertEqual(cube.apply((.4, .5, .6)), (0., 1., .5))
        with self.assertRaises(ValueError): cube.apply((math.nan, 0, 0))
        for bad in ["nan", "inf", "-inf"]:
            with self.assertRaises(ValueError):
                Cube.parse(cube_text(lambda r, g, b: (r, g, b)).replace("0 0 0", bad+" 0 0", 1))

    def test_strict_format(self):
        valid = cube_text(lambda r, g, b: (r, g, b))
        for bad in [valid+"\n0 0 0", "\n".join(valid.splitlines()[:-1]),
                    valid.replace("LUT_3D_SIZE 2", "LUT_1D_SIZE 2"),
                    "LUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 0 1 1\n" + "\n".join(valid.splitlines()[2:]),
                    valid+"\nDOMAIN_MAX 2 2 2", valid.replace("LUT_3D_SIZE 2", "LUT_3D_SIZE 2\nLUT_3D_SIZE 2")]:
            with self.subTest(bad=bad[:70]):
                with self.assertRaises(ValueError): Cube.parse(bad)

    def test_natural_names_and_ascii_title(self):
        self.assertEqual(sorted(["lut10.CUBE", "lut2.cube", "Lut1.cube"], key=natural_key),
                         ["Lut1.cube", "lut2.cube", "lut10.CUBE"])
        value = internal_title(Path("中文暖色.cube"), "a"*64)
        self.assertLessEqual(len(value.encode("ascii")), 31)
        self.assertEqual(value, internal_title(Path("中文暖色.cube"), "a"*64))
        self.assertEqual(internal_title(Path("中文预设.cube"), "a"*64), "R6LUT-LUT-aaaaaaaa")
        self.assertEqual(internal_title(Path("另一个预设.cube"), "a"*64), "R6LUT-LUT-aaaaaaaa")


if __name__ == "__main__":
    unittest.main()
