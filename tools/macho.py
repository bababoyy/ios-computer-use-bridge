"""Bağımlılıksız, küçük bir Mach-O yardımcı modülü.

Yalnızca bu projenin ihtiyacı olanı yapar: 64-bit (thin ya da fat) bir Mach-O'ya
LC_LOAD_DYLIB eklemek, mevcut dylib'leri listelemek ve FairPlay şifrelemesini tespit
etmek. Linux, macOS ve CI'da aynı şekilde çalışır (insert_dylib/optool'un yerine).
"""
from __future__ import annotations

import struct
from dataclasses import dataclass

MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
MH_MAGIC = 0xFEEDFACE
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF

LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_LAZY_LOAD_DYLIB = 0x20
LC_LOAD_UPWARD_DYLIB = 0x80000023
LC_ENCRYPTION_INFO_64 = 0x2C
LC_CODE_SIGNATURE = 0x1D

DYLIB_COMMANDS = {LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB}
HEADER_64 = 32


class MachOError(Exception):
    pass


@dataclass
class Slice:
    offset: int
    size: int


def slices(data: bytes | bytearray) -> list[Slice]:
    """Dosyadaki 64-bit Mach-O dilimlerini döndürür."""
    if len(data) < 8:
        raise MachOError("Dosya Mach-O olamayacak kadar küçük")
    magic_be = struct.unpack_from(">I", data, 0)[0]
    if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
        nfat = struct.unpack_from(">I", data, 4)[0]
        out = []
        for i in range(nfat):
            if magic_be == FAT_MAGIC:
                _, _, off, size, _ = struct.unpack_from(">iiIII", data, 8 + i * 20)
            else:
                _, _, off, size, _, _ = struct.unpack_from(">iiQQII", data, 8 + i * 32)
            out.append(Slice(off, size))
        return out
    magic_le = struct.unpack_from("<I", data, 0)[0]
    if magic_le == MH_MAGIC_64:
        return [Slice(0, len(data))]
    if magic_le == MH_MAGIC:
        raise MachOError("32-bit Mach-O desteklenmiyor")
    if magic_le == MH_CIGAM_64:
        raise MachOError("Big-endian Mach-O desteklenmiyor")
    raise MachOError("Mach-O değil")


def _commands(data: bytes | bytearray, base: int):
    magic = struct.unpack_from("<I", data, base)[0]
    if magic != MH_MAGIC_64:
        raise MachOError(f"Dilim 64-bit Mach-O değil (offset {base})")
    ncmds, sizeofcmds = struct.unpack_from("<II", data, base + 16)
    off = base + HEADER_64
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmdsize < 8:
            raise MachOError("Bozuk load command")
        yield cmd, off, cmdsize
        off += cmdsize
    if off - base - HEADER_64 != sizeofcmds:
        raise MachOError("sizeofcmds load command'larla uyuşmuyor")


def _dylib_name(data: bytes | bytearray, off: int, cmdsize: int) -> str:
    name_off = struct.unpack_from("<I", data, off + 8)[0]
    raw = bytes(data[off + name_off: off + cmdsize])
    return raw.split(b"\0", 1)[0].decode("utf-8", "replace")


def dylibs(data: bytes | bytearray) -> list[list[str]]:
    """Her dilim için bağlanan dylib yollarının listesi."""
    return [[_dylib_name(data, off, size) for cmd, off, size in _commands(data, s.offset) if cmd in DYLIB_COMMANDS]
            for s in slices(data)]


def is_encrypted(data: bytes | bytearray) -> bool:
    for s in slices(data):
        for cmd, off, _ in _commands(data, s.offset):
            if cmd == LC_ENCRYPTION_INFO_64 and struct.unpack_from("<I", data, off + 16)[0] != 0:
                return True
    return False


def has_code_signature(data: bytes | bytearray) -> bool:
    return any(cmd == LC_CODE_SIGNATURE for s in slices(data) for cmd, _, _ in _commands(data, s.offset))


def _free_header_space(data: bytes | bytearray, base: int) -> int:
    sizeofcmds = struct.unpack_from("<I", data, base + 20)[0]
    end_of_cmds = HEADER_64 + sizeofcmds
    first_data = None
    for cmd, off, _ in _commands(data, base):
        if cmd != LC_SEGMENT_64:
            continue
        fileoff, filesize = struct.unpack_from("<QQ", data, off + 40)
        nsects = struct.unpack_from("<I", data, off + 64)[0]
        for i in range(nsects):
            sect_off = struct.unpack_from("<I", data, off + 72 + i * 80 + 48)[0]
            if sect_off > 0 and (first_data is None or sect_off < first_data):
                first_data = sect_off
        if fileoff > 0 and filesize > 0 and (first_data is None or fileoff < first_data):
            first_data = fileoff
    if first_data is None:
        raise MachOError("Bölüm bulunamadı, başlık alanı hesaplanamıyor")
    return first_data - end_of_cmds


def add_load_dylib(data: bytearray, path: str, weak: bool = False) -> bool:
    """Tüm dilimlere LC_LOAD_DYLIB (ya da weak) ekler. Zaten varsa False döner."""
    name = path.encode("utf-8") + b"\0"
    cmdsize = (24 + len(name) + 7) & ~7
    command = struct.pack("<IIIIII", LC_LOAD_WEAK_DYLIB if weak else LC_LOAD_DYLIB, cmdsize, 24, 2, 0x10000, 0x10000)
    command += name + b"\0" * (cmdsize - 24 - len(name))

    targets = []
    for s in slices(data):
        existing = [_dylib_name(data, off, size) for cmd, off, size in _commands(data, s.offset) if cmd in DYLIB_COMMANDS]
        if path in existing:
            continue
        free = _free_header_space(data, s.offset)
        if free < cmdsize:
            raise MachOError(f"Başlıkta yer yok ({free} bayt boş, {cmdsize} gerekli). "
                             "Uygulamayı -headerpad_max_install_names ile derleyin.")
        targets.append(s)

    for s in targets:
        ncmds, sizeofcmds = struct.unpack_from("<II", data, s.offset + 16)
        at = s.offset + HEADER_64 + sizeofcmds
        if any(data[at:at + cmdsize]):
            raise MachOError("Başlıktaki boş alan sıfır değil; güvenli ekleme yapılamıyor")
        data[at:at + cmdsize] = command
        struct.pack_into("<II", data, s.offset + 16, ncmds + 1, sizeofcmds + cmdsize)
    return bool(targets)
