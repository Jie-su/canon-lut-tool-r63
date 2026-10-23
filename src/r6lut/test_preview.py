from pathlib import Path
import struct
import tempfile
import unittest

from .colors import Adaptation, ColorAdapter
from .cube import Cube
from .preview import make_preview_lut


class PreviewTests(unittest.TestCase):
    def fixture(self, folder, fn):
        path = Path(folder) / "test.cube"
        path.write_text("LUT_3D_SIZE 2\n" + "\n".join(" ".join(map(str, fn(r,g,b)))
            for b in (0,1) for g in (0,1) for r in (0,1)) + "\n")
        return path

    def test_identity_and_red_fastest_swap(self):
        for function in (lambda r,g,b:(r,g,b), lambda r,g,b:(b,g,r)):
            with tempfile.TemporaryDirectory() as tmp:
                cube = self.fixture(tmp, function)
                out = Path(tmp)/"out"
                result = make_preview_lut(cube, out, size=17)
                values = struct.unpack("<%df" % (17**3*4), (out/"lookup.rgba32f").read_bytes())
                self.assertEqual(result["bytes"],17**3*16)
                for r,g,b in ((0,0,0),(16,0,0),(0,0,16),(4,8,12),(16,16,16)):
                    offset = ((b*17+g)*17+r)*4
                    self.assertEqual(values[offset:offset+4], (*function(r/16,g/16,b/16),1.0))

    def test_clog_nodes_reuse_color_adapter(self):
        for mode in ("clog2","clog3"):
            with tempfile.TemporaryDirectory() as tmp:
                source = self.fixture(tmp, lambda r,g,b:(b,g,r))
                out = Path(tmp)/"out"
                make_preview_lut(source,out,mode,"cinema-gamut","gamma24",17)
                values = struct.unpack("<%df"%(17**3*4),(out/"lookup.rgba32f").read_bytes())
                adapter=ColorAdapter(Adaptation(mode,"cinema-gamut","gamma24"),Cube.load(source))
                for r,g,b in ((0,0,0),(4,8,12),(16,16,16)):
                    offset=((b*17+g)*17+r)*4
                    for got,want in zip(values[offset:offset+3],adapter.apply((r/16,g/16,b/16))):
                        self.assertAlmostEqual(got,want,places=7)

    def test_existing_destination_is_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            source=self.fixture(tmp,lambda r,g,b:(r,g,b))
            with self.assertRaisesRegex(ValueError,"already exists"):
                make_preview_lut(source,Path(tmp),size=17)


if __name__ == "__main__":
    unittest.main()
