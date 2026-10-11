#!/bin/bash
# Build build/java-runtime -- Husk's Dalvik runtime for Java apps (libGDX and
# the like) -- from the Lineage guest image.
#
#   scripts/build_java_runtime_ci.sh [lineage-vda.qcow2|vda.raw]
#
# Exists because scripts/build_java_runtime.sh is a developer-local script: its
# APEX root, HTTP_LEGACY and FRAMEWORK_RES all default to paths on an external
# drive that no CI runner has, and nothing in the repository called it. This
# derives all three from the same guest image the app itself downloads, which
# is the only copy of those files anyone actually has.
#
# Everything it produces is optional. The app runs without it; only Java apps
# need it. So a missing tool or an unreachable image warns and exits 0 rather
# than failing the build -- see the call site in ci_build.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${1:-${LINEAGE_IMAGE:-$ROOT/build/lineage-vda.qcow2}}"
OUT="$ROOT/build/java-runtime"
APEX_OUT="$ROOT/build/java-apex-root"
SYS_IMG="$ROOT/build/system.img"
FRAMEWORK_OUT="$ROOT/build/java-framework-files"

warn() { echo "warning: $*" >&2; }
die()  { echo "error: $*" >&2; exit 1; }

# ---- 1. inputs -----------------------------------------------------------------
[ -f "$IMG" ] || die "guest image not found: $IMG (see scripts/fetch_translation_resources.sh)"

for t in qemu-img debugfs python3 unzip; do
  command -v "$t" >/dev/null 2>&1 || warn "$t not found; java-runtime will be skipped"
done
command -v qemu-img  >/dev/null 2>&1 || exit 0
command -v debugfs  >/dev/null 2>&1 || exit 0

JDK="${HUSK_JDK:-}"
if [ -z "$JDK" ]; then
  for c in /opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home \
           /usr/local/opt/openjdk/libexec/openjdk.jdk/Contents/Home \
           /Library/Java/JavaVirtualMachines/*/Contents/Home; do
    [ -x "$c/bin/javac" ] && JDK="$c" && break
  done
fi
[ -x "${JDK:-}/bin/javac" ] || { warn "no JDK found; java-runtime will be skipped"; exit 0; }

D8="${HUSK_D8:-$ROOT/build/r8.jar}"
[ -f "$D8" ] || { warn "r8.jar not found at $D8; java-runtime will be skipped"; exit 0; }

# ---- 2. the system partition ---------------------------------------------------
# build_android_system.sh unpacks this too. Doing it once and caching it is what
# lets step 3 read the APEX modules from the same tree, and it turns a
# multi-minute unpack into a file that survives the build.
if [ ! -f "$SYS_IMG" ] || [ "$IMG" -nt "$SYS_IMG" ]; then
  echo "==> unpacking the system partition"
  WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
  RAW="$IMG"
  case "$IMG" in
    *.qcow2) qemu-img convert -O raw "$IMG" "$WORK/vda.raw"; RAW="$WORK/vda.raw" ;;
  esac

  # build_android_system.sh shells out to `gpt -r show`, which is not on a stock
  # runner. Reading the partition table directly is twelve lines and removes a
  # Homebrew formula from the list of things that has to be present.
  python3 - "$RAW" "$SYS_IMG" <<'PY'
import struct, sys
raw, out = sys.argv[1], sys.argv[2]
with open(raw, 'rb') as f:
    f.seek(512)                                  # protective MBR
    hdr = f.read(92)
    assert hdr[:8] == b'EFI PART', 'not a GPT disk'
    entry_lba, n, sz = struct.unpack_from('<QII', hdr, 72)
    f.seek(entry_lba * 512)
    entries = f.read(n * sz)
    base = None
    for i in range(n):
        e = entries[i * sz:(i + 1) * sz]
        first, last = struct.unpack_from('<QQ', e, 0)
        name = e[56:128].split(b'\0')[0].decode()
        if name == 'super' and first:
            base = first * 512
            break
    assert base is not None, 'no super partition'
    f.seek(base + 12288)
    h = f.read(256)
    magic, _, _, hsize = struct.unpack_from('<IHHI', h, 0)
    assert magic == 0x414C5030, 'no logical partition metadata'
    o = 12 + 32
    tsize = struct.unpack_from('<I', h, o)[0]; o += 4 + 32
    (po, pn, ps), (eo, en, es) = (struct.unpack_from('<III', h, o + 12 * i) for i in range(2))
    f.seek(base + 12288 + hsize)
    T = f.read(tsize)
    ext = [struct.unpack_from('<QIQI', T, eo + es * i) for i in range(en)]
    written = 0
    with open(out, 'wb') as w:
        for i in range(pn):
            e = T[po + ps * i:po + ps * (i + 1)]
            name = e[:36].split(b'\0')[0].decode()
            _, fi, ne, _ = struct.unpack_from('<IIII', e, 36)
            if name != 'system':
                continue
            for j in range(fi, fi + ne):
                nsec, _, data, _ = ext[j]
                f.seek(base + data * 512)
                left = nsec * 512
                while left:
                    b = f.read(min(left, 64 << 20))
                    if not b:
                        # A short read means the download was truncated. Without
                        # this the loop never terminates: left is only reduced by
                        # len(b), and a zero-length read reduces it by nothing.
                        raise SystemExit('image truncated: extent runs past the end of the file')
                    w.write(b); left -= len(b); written += len(b)
    assert written, 'system partition was empty'
    print("    system.img: %.1f MiB" % (written / (1 << 20)))
PY
  [ -s "$SYS_IMG" ] || die "system partition did not unpack"
fi

# ---- 3. the APEX modules, and the two /system/framework files -------------------
MODULES="com.android.art com.android.i18n com.android.tzdata com.android.conscrypt"
echo "==> extracting $MODULES"
rm -rf "$APEX_OUT"; mkdir -p "$APEX_OUT"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

for m in $MODULES; do
  if ! debugfs -R "dump /system/apex/$m.capex $WORK/$m.capex" "$SYS_IMG" 2>/dev/null; then
    warn "$m.capex not in the image; java-runtime will be incomplete"
    continue
  fi
  # A capex is a zip that wraps either apex_payload.img directly or an
  # `original_apex` zip holding it. build_android_system.sh unwraps both shapes;
  # so does this.
  python3 - "$WORK/$m.capex" "$WORK/$m.img" <<'PY'
import sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(src)
if 'original_apex' in z.namelist():
    z = zipfile.ZipFile(z.open('original_apex'))
open(dst, 'wb').write(z.read('apex_payload.img'))
PY
  debugfs -R "rdump / $WORK/$m" "$WORK/$m.img" 2>/dev/null
  [ -d "$WORK/$m" ] && cp -R "$WORK/$m/." "$APEX_OUT/" && rm -rf "$WORK/$m"
done

echo "==> /system/framework"
mkdir -p "$FRAMEWORK_OUT"
for f in org.apache.http.legacy.jar framework-res.apk; do
  debugfs -R "dump /system/framework/$f $FRAMEWORK_OUT/$f" "$SYS_IMG" 2>/dev/null \
    || warn "$f not in the image"
done

# ---- 4. Husk's own Java framework, then the runtime ----------------------------
echo "==> building husk-framework.dex"
HUSK_JDK="$JDK" HUSK_D8="$D8" "$ROOT/src/java-framework/build.sh" \
    "$OUT/husk-framework.dex" || die "src/java-framework/build.sh failed"

echo "==> assembling $OUT"
HTTP_LEGACY="$FRAMEWORK_OUT/org.apache.http.legacy.jar" \
FRAMEWORK_RES="$FRAMEWORK_OUT/framework-res.apk" \
  "$ROOT/scripts/build_java_runtime.sh" "$APEX_OUT" || die "build_java_runtime.sh failed"

[ -f "$OUT/husk-framework.dex" ] || die "no husk-framework.dex in $OUT"
echo "==> $OUT: $(du -sh "$OUT" | cut -f1)"
