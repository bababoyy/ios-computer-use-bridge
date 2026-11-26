"""macho.py testleri: sentetik Mach-O dosyalarıyla (cihaz ya da macOS gerekmez).

Çalıştırma: python -m unittest discover tools
"""
from __future__ import annotations

import struct
import unittest

import macho

SECT_OFFSET = 0x4000


def make_thin(extra_cmds: bytes = b"", encrypted: bool = False, sect_offset: int = SECT_OFFSET) -> bytearray:
    """Bir __TEXT segmenti, bir bölüm ve bir LC_LOAD_DYLIB içeren küçük bir arm64 Mach-O."""
    seg = struct.pack("<II16sQQQQiiII", macho.LC_SEGMENT_64, 72 + 80, b"__TEXT", 0, 0x8000, 0, 0x8000, 5, 5, 1, 0)
    sect = struct.pack("<16s16sQQIIIIIIII", b"__text", b"__TEXT", sect_offset, 16, sect_offset, 2, 0, 0, 0, 0, 0, 0)
    name = b"/usr/lib/libSystem.B.dylib\0"
    size = (24 + len(name) + 7) & ~7
    dylib = struct.pack("<IIIIII", macho.LC_LOAD_DYLIB, size, 24, 2, 0x10000, 0x10000) + name.ljust(size - 24, b"\0")
    enc = struct.pack("<IIIII", macho.LC_ENCRYPTION_INFO_64, 24, SECT_OFFSET, 16, 1 if encrypted else 0) + b"\0" * 4
    cmds = seg + sect + dylib + enc + extra_cmds
    header = struct.pack("<IiiIIIII", macho.MH_MAGIC_64, 0x0100000C, 0, 2, 3 if not extra_cmds else 4, len(cmds), 0, 0)
    data = bytearray(header + cmds)
    data += b"\0" * (sect_offset - len(data))
    data += b"\x1f\x20\x03\xd5" * 4  # nop'lar
    return data


def make_fat(*thin: bytearray) -> bytearray:
    out = bytearray(struct.pack(">II", macho.FAT_MAGIC, len(thin)))
    offset = 0x4000
    arch_table = b""
    body = bytearray()
    for t in thin:
        arch_table += struct.pack(">iiIII", 0x0100000C, 0, offset + len(body), len(t), 14)
        body += t
        body += b"\0" * (-len(body) % 0x4000)
    out += arch_table
    out += b"\0" * (offset - len(out))
    out += body
    return out


GADGET = "@executable_path/Frameworks/FridaGadget.dylib"


class MachOTests(unittest.TestCase):
    def test_lists_dylibs(self):
        self.assertEqual(macho.dylibs(make_thin()), [["/usr/lib/libSystem.B.dylib"]])

    def test_add_load_dylib_thin(self):
        data = make_thin()
        self.assertTrue(macho.add_load_dylib(data, GADGET))
        self.assertEqual(macho.dylibs(data), [["/usr/lib/libSystem.B.dylib", GADGET]])
        # bölüm verisi yerinde kaldı
        self.assertEqual(data[SECT_OFFSET:SECT_OFFSET + 4], b"\x1f\x20\x03\xd5")

    def test_add_is_idempotent(self):
        data = make_thin()
        macho.add_load_dylib(data, GADGET)
        snapshot = bytes(data)
        self.assertFalse(macho.add_load_dylib(data, GADGET))
        self.assertEqual(bytes(data), snapshot)

    def test_add_load_dylib_fat(self):
        data = make_fat(make_thin(), make_thin())
        self.assertTrue(macho.add_load_dylib(data, GADGET))
        self.assertEqual(macho.dylibs(data), [["/usr/lib/libSystem.B.dylib", GADGET]] * 2)

    def test_no_header_space(self):
        data = make_thin(sect_offset=0x100)
        with self.assertRaises(macho.MachOError):
            macho.add_load_dylib(data, GADGET)

    def test_encryption_detected(self):
        self.assertFalse(macho.is_encrypted(make_thin()))
        self.assertTrue(macho.is_encrypted(make_thin(encrypted=True)))

    def test_rejects_non_macho(self):
        with self.assertRaises(macho.MachOError):
            macho.slices(b"\x7fELF" + b"\0" * 60)


if __name__ == "__main__":
    unittest.main()
