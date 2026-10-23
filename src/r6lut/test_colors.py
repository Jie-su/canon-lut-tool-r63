"""Analytical transfer/gamut anchors and combined inverse-Log CUBE checks."""
import math
import unittest

from .colors import (Adaptation, ColorAdapter, D65, PRIMARIES, canon_log_decode,
                     canon_log_encode, gamut_matrix, matvec, rgb_to_xyz,
                     srgb_decode, srgb_encode)
from .cube import Cube
from .convert import internal_title


class ColorTests(unittest.TestCase):
    def test_srgb_reference_and_roundtrip(self):
        self.assertEqual(srgb_decode(0.), 0.)
        self.assertAlmostEqual(srgb_decode(0.04045), 0.0031308049535603713, places=15)
        self.assertAlmostEqual(srgb_encode(0.0031308), 0.040449936, places=12)
        self.assertAlmostEqual(srgb_decode(1.), 1., places=14)
        for value in (-.01, 0., .01, .18, .5, 1., 2.):
            self.assertAlmostEqual(srgb_encode(srgb_decode(value)), value, delta=4e-8)

    def test_official_canon_reflection_anchors(self):
        expected = {"clog2": (0.092864125, 0.39825469203794917, 0.5623042642562242),
                    "clog3": (0.12512219, 0.3433893703739355, 0.5644735828313111)}
        codes = {"clog2": (95, 407, 575), "clog3": (128, 351, 577)}
        for mode in expected:
            for reflection, value, code in zip((0., .18, .9), expected[mode], codes[mode]):
                actual = canon_log_encode(reflection, mode)
                self.assertAlmostEqual(actual, value, places=14)
                self.assertEqual(math.floor(actual*1023+.5), code)

    def test_canon_signed_roundtrip_and_rounded_piece_boundaries(self):
        for mode in ("clog2", "clog3"):
            for reflection in (-.9, -.1, -.0127, -.005, 0., .005, .0127, .18, .9, 10.):
                self.assertAlmostEqual(canon_log_decode(canon_log_encode(reflection, mode), mode),
                                       reflection, delta=1e-12)
        for reflection in (-.014*.9, .014*.9):
            left = canon_log_encode(reflection-1e-12, "clog3")
            right = canon_log_encode(reflection+1e-12, "clog3")
            # Official rounded coefficients have a ~2.56e-9 branch jump.
            self.assertLess(abs(left-right), 3e-9)

    def test_primary_xy_white_and_gamut_roundtrip(self):
        for gamut, primaries in PRIMARIES.items():
            matrix = rgb_to_xyz(gamut)
            white = matvec(matrix, (1., 1., 1.))
            self.assertAlmostEqual(white[0]/sum(white), D65[0], places=13)
            self.assertAlmostEqual(white[1]/sum(white), D65[1], places=13)
            for channel, expected in enumerate(primaries):
                xyz = matvec(matrix, tuple(float(i == channel) for i in range(3)))
                self.assertAlmostEqual(xyz[0]/sum(xyz), expected[0], places=13)
                self.assertAlmostEqual(xyz[1]/sum(xyz), expected[1], places=13)
            forward, backward = gamut_matrix("bt709", gamut), gamut_matrix(gamut, "bt709")
            for value in ((.18, .18, .18), (1., 0., 0.), (.13, .48, .91)):
                recovered = matvec(backward, matvec(forward, value))
                for actual, expected in zip(recovered, value):
                    self.assertAlmostEqual(actual, expected, places=13)
            for actual in matvec(forward, (.18, .18, .18)):
                self.assertAlmostEqual(actual, .18, places=13)
        self.assertAlmostEqual(rgb_to_xyz("bt709")[0][0], 0.4123907992659595, places=13)
        self.assertAlmostEqual(rgb_to_xyz("bt2020")[0][0], 0.6369580483012914, places=13)

    def test_combined_inverse_log_cube_recovers_srgb(self):
        n = 65
        for mode in ("clog2", "clog3"):
            low, high = canon_log_encode(0., mode), canon_log_encode(1., mode)
            curve = [srgb_encode(canon_log_decode(low + (high-low)*i/(n-1), mode)) for i in range(n)]
            cube = Cube(n, (low,)*3, (high,)*3,
                        tuple((curve[r], curve[g], curve[b]) for b in range(n) for g in range(n) for r in range(n)))
            adapter = ColorAdapter(Adaptation(mode, "bt709", "srgb"), cube)
            for rgb in ((0., .18, 1.), (.1, .5, .9), (.04, .25, .75)):
                for actual, expected in zip(adapter.apply(rgb), rgb):
                    self.assertAlmostEqual(actual, expected, delta=.002)
            self.assertEqual(adapter.summary()["clipping"]["logInputOutsideCubeDomainComponents"], 0)

    def test_output_gamma24_and_clipping_statistics(self):
        cube = Cube(2, (.2,)*3, (.3,)*3, ((-.1, .5, 1.1),)*8)
        adapter = ColorAdapter(Adaptation("clog3", "bt709", "gamma24"), cube)
        result = adapter.apply((0., 0., 0.))
        self.assertEqual(result[0], 0.)
        self.assertAlmostEqual(result[1], srgb_encode(.5**2.4), places=14)
        self.assertAlmostEqual(result[2], 1., places=14)
        stats = adapter.summary()["clipping"]
        self.assertEqual(stats["sampledComponents"], 3)
        self.assertEqual(stats["logInputOutsideCubeDomainComponents"], 3)
        self.assertEqual(stats["interpolatedCubeOutputOutsideUnitRangeComponents"], 2)

    def test_profile_identity_is_unique_and_direct_unchanged(self):
        titles, filenames = set(), set()
        for mode in ("clog2", "clog3"):
            for gamut in PRIMARIES:
                for output in ("srgb", "gamma24", "same-log"):
                    profile = Adaptation(mode, gamut, output)
                    titles.add(internal_title("示例.cube", "a"*64, profile))
                    filenames.add(profile.filename_prefix()+"示例.pf3")
        self.assertEqual(len(titles), 18)
        self.assertEqual(len(filenames), 18)
        self.assertTrue(all(len(title.encode("ascii")) <= 31 for title in titles))
        self.assertEqual(internal_title("示例.cube", "a"*64, Adaptation()),
                         internal_title("示例.cube", "a"*64))
        self.assertEqual(Adaptation().filename_prefix(), "")
        for bad in [("clog", "bt709", "srgb"), ("clog3", "p3", "srgb"), ("clog3", "bt709", "pq")]:
            with self.assertRaises(ValueError): Adaptation(*bad)

    def test_identity_log_to_log_cube_preserves_all_gamuts(self):
        cube = Cube(2, (0.,)*3, (1.,)*3,
                    tuple((float(r), float(g), float(b)) for b in range(2) for g in range(2) for r in range(2)))
        for mode in ("clog2", "clog3"):
            for gamut in PRIMARIES:
                adapter = ColorAdapter(Adaptation(mode, gamut, "same-log"), cube)
                for rgb in ((0., 0., 0.), (.18, .18, .18), (1., 1., 1.), (.04, .25, .75), (1., 0., 0.)):
                    for actual, expected in zip(adapter.apply(rgb), rgb):
                        self.assertAlmostEqual(actual, expected, delta=2e-7)
                self.assertEqual(adapter.summary()["clipping"]["interpolatedCubeOutputClampedBeforeOutputDecode"], False)

    def test_same_log_keeps_signed_channels_until_inverse_matrix(self):
        encoded = tuple(canon_log_encode(value, "clog3") for value in (-.01, .18, .4))
        cube = Cube(2, (0.,)*3, (1.,)*3, (encoded,)*8)
        adapter = ColorAdapter(Adaptation("clog3", "cinema-gamut", "same-log"), cube)
        actual = adapter.apply((.5, .5, .5))
        linear = matvec(gamut_matrix("cinema-gamut", "bt709"), (-.01, .18, .4))
        expected = tuple(srgb_encode(max(0., min(1., value))) for value in linear)
        for value, wanted in zip(actual, expected):
            self.assertAlmostEqual(value, wanted, places=13)


if __name__ == "__main__": unittest.main()
