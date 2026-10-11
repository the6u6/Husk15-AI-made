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

# Homebrew installs e2fsprogs keg-only, so its sbin is not on PATH and a bare
# `debugfs` does not resolve. build_android_system.sh works around this with a
# hardcoded /opt/homebrew path, which is right on Apple Silicon and wrong on
# Intel; try PATH first, then both prefixes.
DEBUGFS="$(command -v debugfs || true)"
if [ -z "$DEBUGFS" ]; then
  for c in /opt/homebrew/opt/e2fsprogs/sbin/debugfs \
           /usr/local/opt/e2fsprogs/sbin/debugfs \
           /opt/homebrew/bin/debugfs /usr/local/bin/debugfs; do
    [ -x "$c" ] && DEBUGFS="$c" && break
  done
fi
# Prepended so anything nested -- a helper, a subshell -- resolves it too,
# but only once there is something to put there.
[ -n "$DEBUGFS" ] && export PATH="$(dirname "$DEBUGFS"):$PATH"

for t in qemu-img python3 unzip; do
  command -v "$t" >/dev/null 2>&1 || warn "$t not found; java-runtime will be skipped"
done
command -v qemu-img >/dev/null 2>&1 || exit 0
[ -n "$DEBUGFS" ] || { warn "debugfs not found (brew install e2fsprogs); java-runtime will be skipped"; exit 0; }

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
    # A GPT entry's 72-byte name field is UTF-16LE (UEFI 2.x, 5.2.2), 36
    # characters -- not ASCII. Read as bytes, "super" is b's\x00u\x00p\x00e\x00r\x00',
    # splitting on NUL leaves b's', and the match below can never succeed.
    def entry_name(e):
        return e[56:128].decode('utf-16-le', 'ignore').split('\x00')[0]

    parts = []
    base = None
    for i in range(n):
        e = entries[i * sz:(i + 1) * sz]
        first, last = struct.unpack_from('<QQ', e, 32)   # starting/ending LBA
        name = entry_name(e)
        if not name and not first:
            continue                                    # unused slot
        parts.append('%d:%s[%d..%d]' % (i, name, first, last))
        if name == 'super' and first:
            base = first * 512
    if base is None:
        # build_android_system.sh locates the super partition by position, not by
        # name -- "the second one", as its comment says. A conventional Android
        # layout puts it there, so fall back to that rather than to an error.
        used = [i for i in range(n)
                if entries[i * sz + 56:i * sz + 128].decode('utf-16-le', 'ignore').split('\x00')[0]]
        if len(used) > 1:
            e = entries[used[1] * sz:used[1] * sz + sz]
            base = struct.unpack_from('<Q', e, 32)[0] * 512
            print('    no partition named super; using the second one: %s'
                  % entry_name(e))
    assert base is not None, 'no super partition; the image has: %s' % (', '.join(parts) or 'none')
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
# build_java_runtime.sh reads an "APEX root": one directory per module, each
# holding that module's mounted layout (com.android.art/javalib, and so on).
MODULES="com.android.art com.android.i18n com.android.tzdata com.android.conscrypt"
echo "==> extracting $MODULES"
rm -rf "$APEX_OUT"; mkdir -p "$APEX_OUT"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# What the image holds, so a miss is a report rather than a shrug.
apex_listing() {
  for d in /system/apex /apex; do
    echo "    $d:" >&2
    "$DEBUGFS" -R "ls -p $d" "$SYS_IMG" 2>/dev/null | tr -s ' ' '\n' | grep -v '^/$' | head -40 >&2 \
      || echo "      (absent)" >&2
  done
}

for m in $MODULES; do
  # Where a module can be. Partition-backed APEXes are .capex, file-backed ones
  # .apex, and the two live in different directories depending on the build --
  # assuming one path is what produced FileNotFoundError from zipfile.
  found=""
  for root in /system/apex /apex; do
    for ext in capex apex; do
      p="$root/$m.$ext"
      if "$DEBUGFS" -R "dump $p $WORK/$m.zip" "$SYS_IMG" 2>/dev/null && [ -s "$WORK/$m.zip" ]; then
        found="$p"; break 2
      fi
    done
  done
  if [ -z "$found" ]; then
    warn "$m is not in the image at any known root"
    echo "    tried: /system/apex/$m.{capex,apex} and /apex/$m.{capex,apex}" >&2
    apex_listing
    continue
  fi
  echo "    $m <- $found"
  rm -f "$WORK/$m.zip"

  # A capex is a zip that wraps either apex_payload.img directly or an
  # `original_apex` zip holding it. build_android_system.sh unwraps both shapes;
  # so does this.
  python3 - "$WORK/$m.zip" "$WORK/$m.img" <<'PY'
import sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(src)
if 'original_apex' in z.namelist():
    z = zipfile.ZipFile(z.open('original_apex'))
open(dst, 'wb').write(z.read('apex_payload.img'))
PY
  # rdump of / produces $WORK/<m>/<contents>, so the module's own directory has
  # to be made here. Copying straight into $APEX_OUT puts javalib/ and lib64/
  # at the apex root, and build_java_runtime.sh looks for
  # com.android.art/javalib/core-oj.jar.
  mkdir -p "$WORK/$m" "$APEX_OUT/$m"
  "$DEBUGFS" -R "rdump / $WORK/$m" "$WORK/$m.img" 2>/dev/null
  cp -R "$WORK/$m/." "$APEX_OUT/$m/" 2>/dev/null
  [ -n "$(ls -A "$APEX_OUT/$m" 2>/dev/null)" ] || { rm -rf "$APEX_OUT/$m"; warn "$m extracted to nothing"; }
done

echo "==> /system/framework"
mkdir -p "$FRAMEWORK_OUT"
for f in org.apache.http.legacy.jar framework-res.apk; do
  "$DEBUGFS" -R "dump /system/framework/$f $FRAMEWORK_OUT/$f" "$SYS_IMG" 2>/dev/null \
    || warn "$f not in the image"
done

# ---- 4. preflight, then assemble ----------------------------------------------
# Every file build_java_runtime.sh copies, and every file it copies without
# asking. Checked here so the report names the files instead of leaving the
# first `cp` to fail on one of them and take the rest of the list down with it.
REQUIRED="
com.android.art/javalib/core-oj.jar
com.android.art/javalib/core-libart.jar
com.android.art/javalib/okhttp.jar
com.android.art/javalib/bouncycastle.jar
com.android.art/javalib/apache-xml.jar
com.android.art/lib64/libandroidio.so
com.android.art/lib64/libbase.so
com.android.art/lib64/libc++.so
com.android.art/lib64/libexpat.so
com.android.art/lib64/libjavacore.so
com.android.art/lib64/libnativehelper.so
com.android.art/lib64/libopenjdk.so
com.android.i18n/javalib/core-icu4j.jar
com.android.i18n/etc/icu
com.android.tzdata/etc
com.android.conscrypt/javalib/conscrypt.jar
com.android.conscrypt/lib64/libjavacrypto.so
com.android.conscrypt/lib64/libcrypto.so
com.android.conscrypt/lib64/libssl.so
"

missing=0
for f in $REQUIRED; do
  [ -e "$APEX_OUT/$f" ] || { echo "  absent from the apex root: $f" >&2; missing=$((missing+1)); }
done
for f in "$FRAMEWORK_OUT/org.apache.http.legacy.jar" "$FRAMEWORK_OUT/framework-res.apk"; do
  [ -e "$f" ] || { echo "  absent from the image: ${f##*/}" >&2; missing=$((missing+1)); }
done

if [ "$missing" -gt 0 ]; then
  echo "error: $missing required file(s) missing; the apex root is not what build_java_runtime.sh expects" >&2
  echo "       what was extracted:" >&2
  find "$APEX_OUT" -maxdepth 2 >&2 2>/dev/null | head -30
  die "see the list above"
fi

# build_java_runtime.sh calls src/java-framework/build.sh itself, after
# `rm -rf "$OUT"` -- so building the dex here would only be deleted again. What
# it does not do is pass the JDK through: build.sh defaults both to
# /Volumes/GTAV/husk2. Exported, so the internal call inherits them.
echo "==> assembling $OUT"
export HUSK_JDK="$JDK" HUSK_D8="$D8"
HTTP_LEGACY="$FRAMEWORK_OUT/org.apache.http.legacy.jar" \
FRAMEWORK_RES="$FRAMEWORK_OUT/framework-res.apk" \
  "$ROOT/scripts/build_java_runtime.sh" "$APEX_OUT" || die "build_java_runtime.sh failed"

[ -f "$OUT/husk-framework.dex" ] || die "no husk-framework.dex in $OUT"
echo "==> $OUT: $(du -sh "$OUT" | cut -f1)"
