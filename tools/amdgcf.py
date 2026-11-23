#!/usr/bin/env python3
"""amdgcf.dat tool: dump, verify and rebuild AMD's chip revision allow-list.

Author: Liam van Dam
Format and hash are described in docs/AMDGCF.md.

  amdgcf.py dump    amdgcf.dat
  amdgcf.py verify  amdgcf.dat  (--inf u0xxxxxx.inf | --release-version STRING)
  amdgcf.py build   amdgcf.dat out.dat (--inf ... | --release-version ...) [--add 7340:40 ...] [--apple]
"""
import argparse
import re
import struct
import sys

M = (1 << 64) - 1
K0, K1, K2, K3 = 0xD6D018F5, 0xA2AA033B, 0x62992FC1, 0x30BC5B29

# Apple revisions, from Project Falcon's 26.9.2 list
APPLE = ['7310:00', '7319:40', '731B:40', '7340:00', '7340:40', '7340:41',
         '7340:43', '7340:47', '7360:41', '73A2:00', '73AB:00']


def _rotr(x, r):
    return ((x >> r) | (x << (64 - r))) & M


def metrohash64(data, seed=0):
    u64 = lambda i: int.from_bytes(data[i:i + 8], 'little')
    p, n = 0, len(data)
    h = ((seed + K2) * K0) & M
    if n >= 32:
        v = [h, h, h, h]
        while p + 32 <= n:
            v[0] = (_rotr((v[0] + u64(p) * K0) & M, 29) + v[2]) & M
            v[1] = (_rotr((v[1] + u64(p + 8) * K1) & M, 29) + v[3]) & M
            v[2] = (_rotr((v[2] + u64(p + 16) * K2) & M, 29) + v[0]) & M
            v[3] = (_rotr((v[3] + u64(p + 24) * K3) & M, 29) + v[1]) & M
            p += 32
        v[2] ^= (_rotr(((v[0] + v[3]) * K0 + v[1]) & M, 37) * K1) & M
        v[3] ^= (_rotr(((v[1] + v[2]) * K1 + v[0]) & M, 37) * K0) & M
        v[0] ^= (_rotr(((v[0] + v[2]) * K0 + v[3]) & M, 37) * K1) & M
        v[1] ^= (_rotr(((v[1] + v[3]) * K1 + v[2]) & M, 37) * K0) & M
        h = (h + (v[0] ^ v[1])) & M
    if n - p >= 16:
        v0 = (_rotr((h + u64(p) * K2) & M, 29) * K3) & M
        v1 = (_rotr((h + u64(p + 8) * K2) & M, 29) * K3) & M
        v0 ^= (_rotr((v0 * K0) & M, 21) + v1) & M
        v1 ^= (_rotr((v1 * K3) & M, 21) + v0) & M
        h = (h + v1) & M
        p += 16
    for size, rot in ((8, 55), (4, 26), (2, 48), (1, 37)):
        if n - p >= size:
            h = (h + int.from_bytes(data[p:p + size], 'little') * K3) & M
            h ^= (_rotr(h, rot) * K1) & M
            p += size
    h ^= _rotr(h, 28)
    h = (h * K0) & M
    h ^= _rotr(h, 29)
    return h


def read(path):
    b = open(path, 'rb').read()
    n = struct.unpack_from('<I', b)[0]
    recs = []
    for i in range(n):
        off = 12 + 3 * i
        recs.append(((struct.unpack_from('<H', b, off)[0] - off) & 0xFFFF, b[off + 2]))
    return b, recs


def digest(body, release_version):
    return metrohash64(body + release_version.encode('ascii')).to_bytes(8, 'big')


def build(recs, release_version):
    recs = sorted(set(recs))
    body = bytearray()
    for i, (dev, rev) in enumerate(recs):
        body += struct.pack('<HB', (dev + 12 + 3 * i) & 0xFFFF, rev)
    return struct.pack('<I', len(recs)) + digest(bytes(body), release_version) + body


def release_version_from(args):
    if args.release_version:
        return args.release_version
    raw = open(args.inf, 'rb').read()
    text = raw.decode('utf-16') if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else raw.decode('latin-1')
    m = re.search(r'HKR,,ReleaseVersion,,"([^"]+)"', text)
    if not m:
        sys.exit('ReleaseVersion not found in ' + args.inf)
    return m.group(1)


def parse_pair(s):
    dev, rev = s.split(':')
    return int(dev, 16), int(rev, 16)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    d = sub.add_parser('dump')
    d.add_argument('file')
    for name in ('verify', 'build'):
        p = sub.add_parser(name)
        p.add_argument('file')
        if name == 'build':
            p.add_argument('out')
            p.add_argument('--add', nargs='*', default=[], metavar='DEV:REV')
            p.add_argument('--apple', action='store_true', help='add the known Apple revisions')
        g = p.add_mutually_exclusive_group(required=True)
        g.add_argument('--inf')
        g.add_argument('--release-version')
    args = ap.parse_args()

    raw, recs = read(args.file)
    if args.cmd == 'dump':
        print(f'{len(recs)} records, hash {raw[4:12].hex()}')
        by_dev = {}
        for dev, rev in recs:
            by_dev.setdefault(dev, []).append(f'{rev:02X}')
        for dev in sorted(by_dev):
            print(f'  {dev:04X}: {" ".join(by_dev[dev])}')
        return

    rv = release_version_from(args)
    if args.cmd == 'verify':
        ok = digest(raw[12:], rv) == raw[4:12]
        print(f'ReleaseVersion {rv}: {"OK" if ok else "MISMATCH"}')
        sys.exit(0 if ok else 1)

    extra = [parse_pair(x) for x in args.add] + ([parse_pair(x) for x in APPLE] if args.apple else [])
    out = build(recs + extra, rv)
    open(args.out, 'wb').write(out)
    print(f'{args.out}: {struct.unpack_from("<I", out)[0]} records, hash {out[4:12].hex()}')


if __name__ == '__main__':
    main()  # Liampie was hier
