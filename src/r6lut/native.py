"""Pinned offline R6 III full33 compiler. No EDSDK or camera transport."""

import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
import sys

from .bridge import Parser, SCHEMA, validate_table


MODEL = 0x80000518
FIRMWARE = b"1.1.2".ljust(32, b"\0")
DESCRIPTOR_SHA256 = "eeaec0b23cc8b0a168fa6f9ba6c80a0431528b80ce05b52cfb168686442d84ac"
PARSER_SHA256 = "f4f2f931c174bfb200fde98d26c0e35c6bcaa3cf2374dbf89583bbeb7fe866b5"
LIBRARY = Path("/Applications/Canon Utilities/EOS Utility/EU3/EOS Utility 3.app/Contents/PlugIns/EdsCFParse.bundle/Contents/MacOS/EdsCFParse")
NODE_COUNT = 33 ** 3
TABLE_BYTES = NODE_COUNT * 3 * 2
HEADER_BYTES = 372
PAYLOAD_BYTES = HEADER_BYTES + 2 * TABLE_BYTES
TABLES = ((0x40001070, 0x1F04, 372), (0x40001071, 0x1F03, 215994))
MUTABLE_SOURCE_PROPERTIES = {0x40001002, 0x40001070, 0x40001071}
U, P = C.c_uint32, C.c_void_p


def sha(data):
    return hashlib.sha256(data).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def native_words(data):
    require(len(data) == TABLE_BYTES, "Expected a complete native full33 table")
    values = struct.unpack("<%dH" % (NODE_COUNT * 3), data)
    require(max(values) <= 32768, "Native full33 RGB sample exceeds 32768")
    return values


def encode_full33(source):
    """Encode observed RGB grid planes at Canon's 0..32768 integer scale.

    The format and quantization are mathematical facts independently checked
    against upstream full33 research. This implementation fills separate
    channel buffers explicitly; it does not invoke a third-party codec.
    """
    validate_table(source)
    planes = [bytearray(NODE_COUNT * 2) for _ in range(3)]
    for node, rgb in enumerate(struct.iter_unpack("<HHH", source[6:])):
        for channel in range(3):
            scaled = (int(rgb[channel]) * 32768 + 2047) // 4095
            struct.pack_into("<H", planes[channel], node * 2, scaled)
    encoded = b"".join(bytes(plane) for plane in planes)
    native_words(encoded)
    return encoded


def table_delta(a, b):
    differences = [abs(x - y) for x, y in zip(native_words(a), native_words(b))]
    return {"differentSamples": sum(value != 0 for value in differences),
            "maxSampleDelta": max(differences),
            "meanSampleDelta": sum(differences) / len(differences),
            "differentBytes": sum(x != y for x, y in zip(a, b))}


def title(raw):
    require(len(raw) == 32, "Expected 32 title bytes")
    value = raw.split(b"\0", 1)[0]
    require(1 <= len(value) <= 31 and raw == value.ljust(32, b"\0"),
            "Expected a nonempty, nul-padded title of at most 31 ASCII bytes")
    require(all(0x20 <= byte <= 0x7E for byte in value), "Title contains nonprinting ASCII")
    return value.decode("ascii")


def snapshot(folder):
    def get(prop, parameter=0):
        return (folder / ("property-%08x-param-%d.bin" % (prop, parameter))).read_bytes()
    data = {"model": get(0x01000001), "firmware": get(7),
            "descriptor": get(0x01000210), "control": get(0x114, 33),
            "settings": get(0x115, 33), "readback": get(0x01000203, 33)}
    require(data["model"] == struct.pack("<I", MODEL), "Requires the actual R6 III model ID")
    require(data["firmware"] == FIRMWARE, "Requires observed firmware 1.1.2")
    require(len(data["descriptor"]) == 15076 and sha(data["descriptor"]) == DESCRIPTOR_SHA256,
            "Requires the observed real R6 III descriptor")
    require(data["control"] == struct.pack("<I", 65), "Only initialized user slot 1 is supported")
    require(len(data["settings"]) == 32, "Expected exact slot-1 settings")
    readback = data["readback"]
    require(len(readback) == 83076, "Expected the observed slot-1 readback representation")
    require(struct.unpack_from("<II", readback) == (1, 83036)
            and struct.unpack_from("<I", readback, 40)[0] == 83036,
            "Slot-1 readback envelope differs")
    require(readback[8:40] == bytes(32), "Expected empty readback outer caption")
    require(struct.unpack_from("<H", readback, 44)[0] in (0x81, 0x84),
            "This prototype supports only Standard or Neutral baseline metadata")
    title(readback[46:78])
    return data


class Native:
    def __init__(self, parser):
        self.parser = parser
        self.style_type = getattr(parser.lib, "_ZN13CPseInterface19GetPictureStyleTypeEv")
        self.style_type.argtypes, self.style_type.restype = [P], U
        self.internal_get = getattr(parser.lib, "_ZN13CPseInterface15GetPropertyDataE9PseDataIDjPv12EdsByteOrder")
        self.internal_get.argtypes, self.internal_get.restype = [P, U, U, P, U], U

    @staticmethod
    def pointer(address):
        return P.from_address(address).value

    def check_type(self, pointer, symbol):
        expected = C.cast(getattr(self.parser.lib, symbol), P).value + 16
        require(self.pointer(pointer) == expected, "Unexpected fixed parser object ABI: " + symbol)

    def interface(self, reference):
        self.check_type(reference.value, "_ZTV9CEdsParse")
        file_parser = self.pointer(reference.value + 0x38)
        self.check_type(file_parser, "_ZTV17CEdsFileParserPSE")
        interface = self.pointer(file_parser + 0x30)
        self.check_type(interface, "_ZTV17CPseInterfaceVer3")
        return interface

    def check_model(self, reference, interface, stage):
        classification_model = U.from_address(interface + 0x10).value
        stored_model = self.parser.get(reference, 0x40001001)
        family = self.style_type(interface)
        require(classification_model == MODEL and stored_model == struct.pack("<I", MODEL)
                and family == 10, "Real R6 III model/type-10 context changed at " + stage)
        return {"stage": stage, "interfaceModel": "0x%08x" % classification_model,
                "profileItemModel": "0x%08x" % int.from_bytes(stored_model, "little"),
                "serializerType": family}

    def compile_normal(self, path, live, base_properties=None):
        before = path.read_bytes()
        reference = self.parser.open(path)
        try:
            properties = {key: self.parser.get(reference, key) for key, _ in SCHEMA}
            title(properties[0x40001002])
            require(properties[0x114] in (struct.pack("<I", 0x81), struct.pack("<I", 0x84)),
                    "Only this Standard/Neutral baseline family is supported")
            require(properties[0x115] == live["settings"], "Source settings differ from official slot 1")
            if base_properties is not None:
                require(all(properties[key] == value for key, value in base_properties.items()
                            if key not in MUTABLE_SOURCE_PROPERTIES),
                        "Source differs from the selected PSE baseline outside title and LUTs")
            for prop, _, _ in TABLES:
                validate_table(properties[prop])
            for prop, key in ((0x01000001, "model"), (0x01000210, "descriptor")):
                value = live[key]
                buffer = C.create_string_buffer(value)
                self.parser.call("SetPropertyData", reference, prop, 0, len(value), buffer)
            interface = self.interface(reference)
            checks = [self.check_model(reference, interface, "real_model_and_descriptor_set")]
            data = self.parser.get(reference, 0x01000203)
            checks.append(self.check_model(reference, interface, "normal_native_compile_completed"))
            require(len(data) == PAYLOAD_BYTES, "Real R6 III normal carrier is not full33")
            require(struct.unpack_from("<II", data) == (1, PAYLOAD_BYTES - 40)
                    and struct.unpack_from("<I", data, 40)[0] == PAYLOAD_BYTES - 40,
                    "Normal full33 envelope differs")
            require(data[8:40] == properties[0x40001002]
                    and data[46:78] == properties[0x40001002], "Native caption/title mismatch")
            require(data[44:46] == properties[0x114][:2], "Native base style mismatch")
            require(data[80:96] == properties[0x115][:16]
                    and data[104:112] == properties[0x115][24:32],
                    "Native settings differ from the source baseline")
            require(struct.unpack_from("<II", data, 96) == (0xDEADBEEF, 0xDEADBEEF)
                    and struct.unpack_from("<HH", data, 112) == (0x4C, 252)
                    and struct.unpack_from("<HHI", data, 116) == (0x2FFF, 0xFFFF, 0),
                    "Native control markers differ")
            require(data[368:370] == properties[0x4000100C] and data[370:372] == bytes(2),
                    "Native version/footer field differs")
            native_tables = []
            for source_prop, native_prop, offset in TABLES:
                buffer = C.create_string_buffer(TABLE_BYTES)
                require(self.internal_get(interface, native_prop, TABLE_BYTES, buffer, 0x4949) == 0,
                        "Native full33 property unavailable")
                require(buffer.raw == data[offset:offset + TABLE_BYTES],
                        "Native full33 property does not exactly match its carrier position")
                values = native_words(buffer.raw)
                native_tables.append({"sourceProperty": "0x%08x" % source_prop,
                                      "nativeProperty": "0x%04x" % native_prop,
                                      "offset": offset, "bytes": TABLE_BYTES,
                                      "sha256": sha(buffer.raw), "min": min(values), "max": max(values),
                                      "internalPropertyCarrierMatchExact": True})
            checks.append(self.check_model(reference, interface, "native_tables_validated"))
            require(path.read_bytes() == before, "Source PF3 changed during native compilation")
            return data, properties, checks, native_tables
        finally:
            self.parser.call("Release", reference)


def build_dense(native_payload, properties):
    result = bytearray(native_payload)
    tables = []
    for prop, _, offset in TABLES:
        encoded = encode_full33(properties[prop])
        result[offset:offset + TABLE_BYTES] = encoded
        values = native_words(encoded)
        tables.append({"sourceProperty": "0x%08x" % prop,
                       "sourceTableSha256": sha(properties[prop]), "offset": offset,
                       "bytes": TABLE_BYTES, "sha256": sha(encoded),
                       "min": min(values), "max": max(values), "finite": True,
                       "layout": "R plane, G plane, B plane; uint16LE; R-outer/G-middle/B-inner nodes",
                       "normalNativeVsDense": table_delta(native_payload[offset:offset + TABLE_BYTES], encoded)})
    result = bytes(result)
    require(len(result) == PAYLOAD_BYTES and result[:HEADER_BYTES] == native_payload[:HEADER_BYTES],
            "Dense replacement changed native metadata")
    return result, tables

