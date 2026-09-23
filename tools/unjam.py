#!/usr/bin/env python3
"""Extractor for the game's DATA.JAM / DATA.JAL archive pair.

Reimplementation of the bundled UJ.EXE ("UnJam V1.1 -- ar compression archiver
-- modified by Paul Andrews"). The container is an LHA level-1 header stream
with the method field replaced by "JAMM!"; the payload codec is Okumura's AR002
(13-bit LZSS + block-wise static Huffman), the algorithm LHA later shipped as
-lh5-. The CRC-16 polynomial is 0xA071 rather than LHA's 0xA001.
"""
import argparse
import struct
import sys
from pathlib import Path

MAGIC = b"JAMM!"
CRC_POLY = 0xA071

DICBIT = 13
MAXMATCH = 256
THRESHOLD = 3
NC = 255 + MAXMATCH + 2 - THRESHOLD
CBIT = 9
NP = DICBIT + 1
NT = 19
PBIT = 4
TBIT = 5

_CRC_TABLE = []
for _i in range(256):
    _c = _i
    for _ in range(8):
        _c = (_c >> 1) ^ (CRC_POLY if _c & 1 else 0)
    _CRC_TABLE.append(_c)


def crc16(data):
    c = 0
    table = _CRC_TABLE
    for b in data:
        c = (c >> 8) ^ table[(c ^ b) & 0xFF]
    return c


class ArchiveError(Exception):
    pass


class _BitReader:
    """MSB-first bit reader with a 16-bit peek window, zero-padded past EOF."""

    __slots__ = ("data", "pos", "acc", "n")

    def __init__(self, data):
        self.data = data
        self.pos = 0
        self.acc = 0
        self.n = 0

    def peek16(self):
        while self.n < 16:
            b = self.data[self.pos] if self.pos < len(self.data) else 0
            self.pos += 1
            self.acc = ((self.acc << 8) | b) & 0xFFFFFFFF
            self.n += 8
        return (self.acc >> (self.n - 16)) & 0xFFFF

    def skip(self, k):
        self.peek16()
        self.n -= k

    def getbits(self, k):
        if k == 0:
            return 0
        v = self.peek16() >> (16 - k)
        self.n -= k
        return v


class _Ar002Decoder:
    def __init__(self, data):
        self.br = _BitReader(data)
        self.c_len = bytearray(NC)
        self.pt_len = bytearray(NT)
        self.c_table = [0] * 4096
        self.pt_table = [0] * 256
        self.left = [0] * (2 * NC - 1)
        self.right = [0] * (2 * NC - 1)
        self.blocksize = 0

    def _make_table(self, nchar, bitlen, tablebits, table):
        count = [0] * 17
        weight = [0] * 17
        start = [0] * 18
        for i in range(nchar):
            count[bitlen[i]] += 1
        for i in range(1, 17):
            start[i + 1] = (start[i] + (count[i] << (16 - i))) & 0xFFFF
        if start[17] != 0:
            raise ArchiveError("malformed Huffman table")

        jutbits = 16 - tablebits
        for i in range(1, tablebits + 1):
            start[i] >>= jutbits
            weight[i] = 1 << (tablebits - i)
        for i in range(tablebits + 1, 17):
            weight[i] = 1 << (16 - i)

        i = start[tablebits + 1] >> jutbits
        if i != 0:
            for k in range(i, 1 << tablebits):
                table[k] = 0

        avail = nchar
        mask = 1 << (15 - tablebits)
        left, right = self.left, self.right
        for ch in range(nchar):
            ln = bitlen[ch]
            if ln == 0:
                continue
            nextcode = (start[ln] + weight[ln]) & 0xFFFF
            if ln <= tablebits:
                for i in range(start[ln], nextcode):
                    table[i] = ch
            else:
                k = start[ln]
                cur, idx = table, k >> jutbits
                for _ in range(ln - tablebits):
                    if cur[idx] == 0:
                        right[avail] = left[avail] = 0
                        cur[idx] = avail
                        avail += 1
                    if k & mask:
                        cur, idx = right, cur[idx]
                    else:
                        cur, idx = left, cur[idx]
                    k = (k << 1) & 0xFFFF
                cur[idx] = ch
            start[ln] = nextcode

    def _read_pt_len(self, nn, nbit, i_special):
        br = self.br
        n = br.getbits(nbit)
        if n == 0:
            c = br.getbits(nbit)
            for i in range(nn):
                self.pt_len[i] = 0
            for i in range(256):
                self.pt_table[i] = c
            return
        i = 0
        while i < n:
            bb = br.peek16()
            c = bb >> 13
            if c == 7:
                mask = 1 << 12
                while bb & mask:
                    mask >>= 1
                    c += 1
            br.skip(3 if c < 7 else c - 3)
            self.pt_len[i] = c
            i += 1
            if i == i_special:
                c = br.getbits(2)
                while c > 0:
                    self.pt_len[i] = 0
                    i += 1
                    c -= 1
        while i < nn:
            self.pt_len[i] = 0
            i += 1
        self._make_table(nn, self.pt_len, 8, self.pt_table)

    def _read_c_len(self):
        br = self.br
        n = br.getbits(CBIT)
        if n == 0:
            c = br.getbits(CBIT)
            for i in range(NC):
                self.c_len[i] = 0
            for i in range(4096):
                self.c_table[i] = c
            return
        i = 0
        while i < n:
            bb = br.peek16()
            c = self.pt_table[bb >> 8]
            if c >= NT:
                mask = 1 << 7
                while c >= NT:
                    c = self.right[c] if bb & mask else self.left[c]
                    mask >>= 1
            br.skip(self.pt_len[c])
            if c <= 2:
                if c == 0:
                    c = 1
                elif c == 1:
                    c = br.getbits(4) + 3
                else:
                    c = br.getbits(CBIT) + 20
                while c > 0:
                    self.c_len[i] = 0
                    i += 1
                    c -= 1
            else:
                self.c_len[i] = c - 2
                i += 1
        while i < NC:
            self.c_len[i] = 0
            i += 1
        self._make_table(NC, self.c_len, 12, self.c_table)

    def decode(self, outsize):
        out = bytearray(outsize)
        br = self.br
        c_table, c_len = self.c_table, self.c_len
        pt_table, pt_len = self.pt_table, self.pt_len
        left, right = self.left, self.right
        r = 0
        while r < outsize:
            if self.blocksize == 0:
                self.blocksize = br.getbits(16)
                self._read_pt_len(NT, TBIT, 3)
                self._read_c_len()
                self._read_pt_len(NP, PBIT, -1)
                c_table, c_len = self.c_table, self.c_len
                pt_table, pt_len = self.pt_table, self.pt_len
            self.blocksize -= 1

            bb = br.peek16()
            j = c_table[bb >> 4]
            if j >= NC:
                mask = 1 << 3
                while j >= NC:
                    j = right[j] if bb & mask else left[j]
                    mask >>= 1
            br.skip(c_len[j])

            if j <= 255:
                out[r] = j
                r += 1
                continue

            length = j - (256 - THRESHOLD)

            bb = br.peek16()
            p = pt_table[bb >> 8]
            if p >= NP:
                mask = 1 << 7
                while p >= NP:
                    p = right[p] if bb & mask else left[p]
                    mask >>= 1
            br.skip(pt_len[p])
            if p != 0:
                p -= 1
                p = (1 << p) + br.getbits(p)

            i = r - p - 1
            if i < 0:
                raise ArchiveError("match references data before start of stream")
            end = r + length
            if end > outsize:
                end = outsize
            while r < end:
                out[r] = out[i]
                r += 1
                i += 1
        return bytes(out)


class Entry:
    __slots__ = ("name", "size", "offset", "packed_size", "crc", "attribute",
                 "level", "timestamp", "data_offset")

    def __init__(self, name, size, offset):
        self.name = name
        self.size = size
        self.offset = offset

    @property
    def path(self):
        return self.name.replace("\\", "/")

    def __repr__(self):
        return f"<Entry {self.name} {self.size}B @{self.offset}>"


class JamArchive:
    """DATA.JAM body plus its DATA.JAL index."""

    def __init__(self, jam_path, jal_path=None):
        jam_path = Path(jam_path)
        if jal_path is None:
            jal_path = jam_path.with_suffix(".JAL")
            if not jal_path.exists():
                jal_path = jam_path.with_suffix(".jal")
        self._load(jam_path.read_bytes(), Path(jal_path).read_bytes())

    @classmethod
    def from_bytes(cls, jam, jal):
        archive = cls.__new__(cls)
        archive._load(jam, jal)
        return archive

    def _load(self, jam, jal):
        self.jam = jam
        self.entries = self._read_index(jal)
        for e in self.entries:
            self._read_header(e)

    @staticmethod
    def _read_index(jal):
        """JAL entry: uint8 name length, name, uint32 size, uint32 JAM offset."""
        entries = []
        p = 0
        while p + 9 <= len(jal) and jal[p]:
            n = jal[p]
            p += 1
            name = jal[p:p + n].decode("cp437")
            p += n
            size, offset = struct.unpack_from("<II", jal, p)
            p += 8
            entries.append(Entry(name, size, offset))
        return entries

    def _read_header(self, entry):
        """LHA level-1 header with a "JAMM!" method field."""
        jam = self.jam
        off = entry.offset
        if off + 22 > len(jam):
            raise ArchiveError(f"{entry.name}: header past end of archive")
        header_size = jam[off]
        checksum = jam[off + 1]
        if jam[off + 2:off + 7] != MAGIC:
            raise ArchiveError(f"{entry.name}: bad magic {jam[off + 2:off + 7]!r}")
        if sum(jam[off + 2:off + 2 + header_size]) & 0xFF != checksum:
            raise ArchiveError(f"{entry.name}: header sum error")

        packed, original, timestamp = struct.unpack_from("<III", jam, off + 7)
        entry.attribute = jam[off + 19]
        entry.level = jam[off + 20]
        name_len = jam[off + 21]
        name = jam[off + 22:off + 22 + name_len].decode("cp437")
        if name != entry.name:
            raise ArchiveError(f"index/header name mismatch: {entry.name!r} vs {name!r}")
        if original != entry.size:
            raise ArchiveError(f"{entry.name}: index/header size mismatch")

        tail = off + 22 + name_len
        entry.crc = struct.unpack_from("<H", jam, tail)[0]
        ext_size = struct.unpack_from("<H", jam, tail + 3)[0]
        if ext_size:
            raise ArchiveError(f"{entry.name}: extended headers are not supported")
        entry.packed_size = packed
        entry.timestamp = timestamp
        entry.data_offset = tail + 5

    def read(self, entry, verify=True):
        packed = self.jam[entry.data_offset:entry.data_offset + entry.packed_size]
        if len(packed) != entry.packed_size:
            raise ArchiveError(f"{entry.name}: truncated archive")
        data = _Ar002Decoder(packed).decode(entry.size)
        if verify and crc16(data) != entry.crc:
            raise ArchiveError(f"{entry.name}: CRC error")
        return data


def _match(entry, patterns):
    if not patterns:
        return True
    from fnmatch import fnmatch
    name = entry.name.upper()
    alt = entry.path.upper()
    return any(fnmatch(name, p.upper()) or fnmatch(alt, p.upper()) for p in patterns)


def main():
    ap = argparse.ArgumentParser(description="Extract SEEK AND DESTROY DATA.JAM archives.")
    ap.add_argument("archive", help="path to DATA.JAM")
    ap.add_argument("patterns", nargs="*", help="glob filters, e.g. 'STAGE00/*' 'data\\*.BIN'")
    ap.add_argument("--jal", help="path to the index file (default: archive with .JAL suffix)")
    ap.add_argument("-o", "--outdir", default=".", help="extraction root (default: .)")
    ap.add_argument("-l", "--list", action="store_true", help="list contents, extract nothing")
    ap.add_argument("-t", "--test", action="store_true", help="decode and verify CRCs only")
    ap.add_argument("--flat", action="store_true", help="ignore directory components")
    ap.add_argument("--lower", action="store_true", help="lowercase extracted names")
    ap.add_argument("--no-verify", action="store_true", help="skip CRC verification")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()

    try:
        archive = JamArchive(args.archive, args.jal)
    except (OSError, ArchiveError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    selected = [e for e in archive.entries if _match(e, args.patterns)]

    if args.list:
        total_p = total_u = 0
        print(f"{'Name':<26}{'Original':>10}{'Packed':>10}{'Ratio':>8}  CRC")
        for e in selected:
            ratio = e.packed_size / e.size if e.size else 0
            print(f"{e.name:<26}{e.size:>10}{e.packed_size:>10}{ratio:>8.3f}  {e.crc:04X}")
            total_u += e.size
            total_p += e.packed_size
        ratio = total_p / total_u if total_u else 0
        print(f"{len(selected)} files{total_u:>19}{total_p:>10}{ratio:>8.3f}")
        return 0

    outroot = Path(args.outdir)
    failed = 0
    for e in selected:
        try:
            data = archive.read(e, verify=not args.no_verify)
        except ArchiveError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            failed += 1
            continue
        if args.test:
            if not args.quiet:
                print(f"OK   {e.name} ({e.size} bytes)")
            continue
        rel = Path(Path(e.path).name) if args.flat else Path(e.path)
        if args.lower:
            rel = Path(*[p.lower() for p in rel.parts])
        dest = outroot / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        if not args.quiet:
            print(f"{dest} ({e.size} bytes)")

    if failed:
        print(f"{failed} of {len(selected)} entries failed", file=sys.stderr)
        return 1
    if args.test and not args.quiet:
        print(f"{len(selected)} entries verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
