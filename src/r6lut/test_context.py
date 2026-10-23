"""Portable context and full33 guards. No Canon SDK or user data is required."""
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

from . import context
from .native import DESCRIPTOR_SHA256, PARSER_SHA256, NODE_COUNT, encode_full33, sha


class ContextGuards(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def profile(self):
        (self.root / "camera").mkdir()
        (self.root / "baseline.pf3").write_bytes(b"this user's independently chosen baseline")
        for filename in context.CAMERA_FILES:
            (self.root / "camera" / filename).write_bytes(filename.encode("ascii"))
        manifest = {
            "schema": context.SCHEMA, "model": "0x80000518", "firmware": "1.1.2",
            "serializerType": 10, "parserSha256": PARSER_SHA256,
            "descriptorSha256": DESCRIPTOR_SHA256, "settingsSha256": sha(b"settings"),
            "base": context._record(self.root / "baseline.pf3", "baseline.pf3"),
            "cameraFiles": [context._record(self.root / "camera" / name, "camera/" + name)
                            for name in context.CAMERA_FILES],
        }
        self.save(manifest)
        return manifest

    def save(self, manifest):
        (self.root / "context.json").write_text(json.dumps(manifest))

    def test_missing_context_is_actionable(self):
        with self.assertRaisesRegex(ValueError, "setup-context"):
            context.load_context(self.root)

    def test_user_chosen_baseline_hash_is_used(self):
        manifest = self.profile()
        readback = bytearray(372)
        struct.pack_into("<H", readback, 44, 0x81)
        live = {"settings": b"settings", "descriptor": b"descriptor", "readback": bytes(readback)}
        with patch.object(context, "snapshot", return_value=live), patch.object(context, "_parser_path", return_value=Path("parser")):
            result = context.load_context(self.root)
        self.assertEqual(result["baseSha256"], manifest["base"]["sha256"])
        self.assertEqual(result["base"], (self.root / "baseline.pf3").resolve())

    def test_changed_baseline_is_rejected(self):
        self.profile()
        (self.root / "baseline.pf3").write_bytes(b"changed after initialization")
        with self.assertRaisesRegex(ValueError, "校验失败"):
            context.load_context(self.root)

    def test_context_cannot_escape_its_directory(self):
        manifest = self.profile()
        manifest["base"]["file"] = "../outside.pf3"
        self.save(manifest)
        with self.assertRaisesRegex(ValueError, "路径"):
            context.load_context(self.root)

    def test_unknown_camera_remains_rejected(self):
        manifest = self.profile()
        manifest["model"] = "0x80000464"
        self.save(manifest)
        with self.assertRaisesRegex(ValueError, "已验证"):
            context.load_context(self.root)

    def test_cached_snapshot_is_not_initialization_proof(self):
        (self.root / "manifest.json").write_text(json.dumps({
            "schema": context.SNAPSHOT_SCHEMA, "freshReadOpcode": 0x9189,
            "cachedFallbackAllowed": True,
        }))
        with self.assertRaisesRegex(ValueError, "缓存"):
            context._saved_snapshot(self.root)


class Full33Format(unittest.TestCase):
    def test_channel_planes_and_node_order(self):
        rgb = []
        for node in range(NODE_COUNT):
            rgb.extend((node % 4096, (node * 7) % 4096, 4095 - node % 4096))
        table = struct.pack("<HHH", 12, 3, 33) + struct.pack("<%dH" % len(rgb), *rgb)
        result = encode_full33(table)
        self.assertEqual(len(result), NODE_COUNT * 6)
        # Probe distinct nodes/channels to catch interleaving and axis reversal.
        for node in (0, 1, 16, 32, 1088, NODE_COUNT - 1):
            for channel in range(3):
                actual = struct.unpack_from("<H", result, (channel * NODE_COUNT + node) * 2)[0]
                expected = round(rgb[node * 3 + channel] * 32768 / 4095)
                self.assertEqual(actual, expected)
        self.assertEqual(struct.unpack_from("<H", result, 0)[0], 0)
        self.assertEqual(struct.unpack_from("<H", result, 4 * NODE_COUNT)[0], 32768)

    def test_out_of_range_source_remains_rejected(self):
        table = bytearray(struct.pack("<HHH", 12, 3, 33) + bytes(NODE_COUNT * 6))
        struct.pack_into("<H", table, 6, 4096)
        with self.assertRaises(ValueError):
            encode_full33(table)


if __name__ == "__main__":
    unittest.main()
