"""Small ctypes bridge to the user's installed Canon EdsCFParse; no EDSDK."""
import ctypes as C
from pathlib import Path
import struct
import sys

SCHEMA = [(0x114, 4), (0x115, 32), (0x40001002, 32),
          (0x4000100a, 64), (0x40001021, 240), (0x40001029, 240),
          (0x40001019, 300), (0x40001018, 300), (0x40001065, 300),
          (0x40001061, 512), (0x40001062, 512), (0x40001023, 8),
          (0x4000102b, 8), (0x40001008, 456), (0x40001012, 4),
          (0x40001070, 215628), (0x40001071, 215628),
          (0x4000100d, 3), (0x4000100c, 2), (0x40001011, 4), (0x40001080, 4)]


def validate_table(table):
    if len(table) != 215628 or struct.unpack_from("<3H", table) != (12, 3, 33):
        raise ValueError("Expected 33³ RGB / 12-bit source table")
    if any(word > 4095 for (word,) in struct.iter_unpack("<H", table[6:])):
        raise ValueError("Source table exceeds 12-bit range")


class Parser:
    def __init__(self, library):
        if sys.platform != "darwin":
            raise RuntimeError("Canon offline PF3 conversion requires macOS")
        self.lib = C.CDLL(str(Path(library).resolve()))
        u, p = C.c_uint32, C.c_void_p
        signatures = {"Initialize": [], "Terminate": [],
                      "CreateRef": [C.c_char_p, u, u, C.POINTER(p)],
                      "Release": [p], "ReflectProperty": [p],
                      "GetPropertySize": [p, u, u, C.POINTER(u), C.POINTER(u)],
                      "GetPropertyData": [p, u, u, u, p],
                      "SetPropertyData": [p, u, u, u, p]}
        for name, args in signatures.items():
            fn = getattr(self.lib, "EdsCfp" + name)
            fn.argtypes, fn.restype = args, u
        self.call("Initialize")

    def call(self, name, *args):
        rc = getattr(self.lib, "EdsCfp" + name)(*args)
        if rc:
            raise RuntimeError("EdsCfp%s failed: 0x%08x" % (name, rc))

    def open(self, path, write=False):
        ref = C.c_void_p()
        self.call("CreateRef", str(Path(path).resolve()).encode("utf-8"),
                  2, 2 if write else 0, C.byref(ref))
        if not ref.value:
            raise RuntimeError("Canon returned a null PF3 reference")
        return ref

    def get(self, ref, prop):
        kind, size = C.c_uint32(), C.c_uint32()
        self.call("GetPropertySize", ref, prop, 0, C.byref(kind), C.byref(size))
        if not 0 < size.value <= 1048576:
            raise ValueError("Unexpected property size: 0x%08x" % prop)
        data = C.create_string_buffer(size.value)
        self.call("GetPropertyData", ref, prop, 0, size.value, data)
        return data.raw

    def set(self, ref, prop, data):
        value = C.create_string_buffer(data, len(data))
        self.call("SetPropertyData", ref, prop, 0, len(data), value)

    def read(self, path):
        ref = self.open(path)
        try:
            return {key: self.get(ref, key) for key, _ in SCHEMA}
        finally:
            self.call("Release", ref)

    def file_records(self, raw):
        """Read all stored version3000 records through Canon's local decoder.

        No cipher keys are copied or distributed. The strict reader checks the
        entire stored record sequence, checksum and terminator, not just SCHEMA.
        """
        if raw[:8] != bytes.fromhex("0000300050535000") or len(raw) < 32:
            raise ValueError("Unsupported PF3 envelope")
        if struct.unpack_from(">I", raw, 8)[0] != len(raw) - 12:
            raise ValueError("PF3 envelope length mismatch")
        buffer = C.create_string_buffer(raw[12:], len(raw) - 12)
        fn = getattr(self.lib, "_Z14DecipherBufferPhmm")
        fn.argtypes, fn.restype = [C.c_void_p, C.c_ulong, C.c_ulong], None
        fn(buffer, len(raw) - 12, 12)
        plain = buffer.raw
        records, seen, at, checked = [], set(), 0, False
        while at + 8 <= len(plain):
            start = at
            identifier, kind, size = struct.unpack_from(">HHI", plain, at)
            at += 8
            if size > len(plain) - at:
                raise ValueError("Truncated PF3 stored record")
            value = plain[at:at + size]
            at += size
            if identifier == 0xFFFF:
                if (kind, size, at, checked) != (0xFFFF, 0, len(plain), True):
                    raise ValueError("Invalid PF3 terminator")
                return records
            if checked:
                raise ValueError("Stored record after checksum")
            if identifier == 0xFFFE:
                if kind != 4 or size != 4 or int.from_bytes(value, "big") != sum(plain[:start]) & 0xFFFFFFFF:
                    raise ValueError("PF3 checksum mismatch")
                checked = True
                continue
            if not (0x1000 <= identifier <= 0x10FF or 0x9000 <= identifier <= 0x90FF):
                raise ValueError("Unsupported PF3 stored record: 0x%04x" % identifier)
            if identifier in seen or kind not in (2, 3, 4, 0xFFFF):
                raise ValueError("Duplicate/unsupported PF3 stored record")
            if size % {3: 2, 4: 4}.get(kind, 1):
                raise ValueError("Misaligned PF3 stored record")
            records.append((identifier, kind, value))
            seen.add(identifier)
        raise ValueError("Missing PF3 terminator")
