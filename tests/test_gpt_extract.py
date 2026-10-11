"""Test the GPT + Android super-partition parser inside build_java_runtime_ci.sh.

The parser is a python heredoc in a shell script, so it cannot be reached by
running the script -- a 1.1 GB image and a macOS runner stand between here and
it. This builds a synthetic disk with the real layout instead: a protective
MBR, a GPT with a `super` partition, and inside that the Android LP metadata
header with one logical partition named `system`.

The parser is extracted from the shell script rather than copied here, so the
two cannot drift apart -- which is the whole reason this test exists: the first
version of the parser had `first, last, name = struct.unpack_from('<QQ', e, 0)`,
two values into three names, which raised ValueError on the first partition it
ever read. `bash -n` does not see inside a heredoc, and no build on a clean
checkout would ever have run it.

    python3 tests/test_gpt_extract.py

Exits non-zero on failure.
"""
import os
import re
import struct
import subprocess
import sys
import tempfile
import shutil

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, os.pardir, "scripts", "build_java_runtime_ci.sh")

SECTOR = 512
SUPER_LBA = 2048
SYS_DATA_LBA = SUPER_LBA + 40
SYS_SECTORS = 64
META_OFF = 12288                      # bytes into the super partition

PAYLOAD = (b"HUSK-SYSTEM-PAYLOAD" * 800 + b"\0" * SYS_SECTORS * SECTOR)
PAYLOAD = PAYLOAD[:SYS_SECTORS * SECTOR]


def build_disk(path):
    """A raw image with the layout the parser expects."""
    buf = bytearray(b"\0" * ((SUPER_LBA + 256) * SECTOR))

    mbr = bytearray(SECTOR)
    mbr[510], mbr[511] = 0x55, 0xAA
    buf[0:SECTOR] = mbr

    hdr = bytearray(92)
    hdr[0:8] = b"EFI PART"
    struct.pack_into("<QII", hdr, 72, 2, 128, 128)      # entry array at LBA 2
    buf[SECTOR:SECTOR + 92] = hdr

    entries = bytearray(128 * 128)

    def entry(idx, first, last, name):
        e = bytearray(128)
        struct.pack_into("<QQ", e, 0, first, last)
        e[56:56 + len(name)] = name.encode()
        entries[idx * 128:(idx + 1) * 128] = e

    entry(0, 1, 33, "EFI")
    entry(1, SUPER_LBA, SUPER_LBA + 200, "super")
    buf[2 * SECTOR:2 * SECTOR + len(entries)] = entries

    base = SUPER_LBA * SECTOR
    h = bytearray(256)
    struct.pack_into("<IHHI", h, 0, 0x414C5030, 0, 0, 256)
    o = 12 + 32
    struct.pack_into("<I", h, o, 132)                    # tables size
    o += 4 + 32
    # descriptor 0: partitions, at offset 0, one 64-byte entry
    struct.pack_into("<III", h, o, 0, 1, 64)
    # descriptor 1 is `extents` -- the header names its four descriptors
    # partitions, extents, groups, block_devices -- and follows the partitions.
    # LpMetadataExtent is 8+4+(4 pad)+8+4+(4 pad) = 32.
    struct.pack_into("<III", h, o + 12, 68, 1, 32)
    buf[base + META_OFF:base + META_OFF + 256] = h

    table = bytearray(132)
    e = bytearray(64)
    e[0:7] = b"system\0"
    struct.pack_into("<IIII", e, 36, 0, 0, 1, 0)         # attrs, first extent, count, 0
    table[0:64] = e
    buf[base + META_OFF + 256:base + META_OFF + 256 + 132] = table

    ext = bytearray(32)
    # target_data is relative to the super partition; the parser seeks base + data * 512
    struct.pack_into("<QIQI", ext, 0, SYS_SECTORS, 0, SYS_DATA_LBA - SUPER_LBA, 0)
    buf[base + META_OFF + 256 + 68:base + META_OFF + 256 + 68 + 32] = ext

    off = SYS_DATA_LBA * SECTOR
    buf[off:off + len(PAYLOAD)] = PAYLOAD

    with open(path, "wb") as f:
        f.write(buf)
    return path


def extract_parser():
    """Pull the python heredoc out of the shell script, so this cannot drift."""
    src = open(SCRIPT, encoding="utf-8").read()
    m = re.search(r"python3 - \"\$RAW\" \"\$SYS_IMG\" <<'PY'\n(.*?)\nPY\n", src, re.S)
    if not m:
        raise SystemExit("could not find the parser heredoc in %s" % SCRIPT)
    return m.group(1)


def main():
    if not os.path.exists(SCRIPT):
        raise SystemExit("missing %s" % SCRIPT)
    parser = extract_parser()
    work = tempfile.mkdtemp()
    try:
        raw = build_disk(os.path.join(work, "vda.raw"))
        out = os.path.join(work, "system.img")
        print("built a synthetic GPT + Android super image (%d bytes)" % os.path.getsize(raw))

        r = subprocess.run([sys.executable, "-c", parser, raw, out], capture_output=True)
        if r.returncode != 0:
            print("FAIL: parser exited %d" % r.returncode)
            print(r.stderr.decode("utf-8", "replace"))
            return 1
        print("parser: %s" % r.stdout.decode().strip())

        got = open(out, "rb").read()
        if got != PAYLOAD:
            print("FAIL: %d bytes extracted, expected %d" % (len(got), len(PAYLOAD)))
            return 1
        print("PASS: system.img matches byte for byte (%d bytes)" % len(got))
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
