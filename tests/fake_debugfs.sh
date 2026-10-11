#!/bin/bash
# A debugfs that serves a synthetic Lineage system image.
#
# Real debugfs needs a real ext4 system.img, which means a 1.1 GB download and a
# macOS runner. This stands in for it: it knows what a Lineage image holds and
# answers `dump`, `rdump` and `ls -p` from a table, so build_java_runtime_ci.sh
# can be run end to end without either.
#
# The table is deliberately not uniform. i18n is .capex under /apex, tzdata is
# .apex under /system/apex, art and conscrypt are .capex under /system/apex, and
# conscrypt's archive holds apex_payload.img directly where the others wrap it in
# `original_apex`. Three CI runs each found a different assumption in the real
# script to be wrong, and a harness where every module is in the same place will
# not catch the next one.
#
# HUSK_FAKE_MISSING names modules to pretend the image does not carry.
#
# Archives are built with python3 rather than zip(1): Git Bash ships no zip, and
# a harness that silently does nothing is worse than none.
set -u

# `debugfs -R "<command and its arguments>" <image>` -- the image is a separate
# argv, not part of the -R string. Discarding it here meant rdump had only two
# fields to work from and took the destination directory for the image.
ARG=""
IMG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -R) ARG="$2"; shift 2 ;;
    *)  IMG="$1"; shift ;;
  esac
done

CMD="${ARG%% *}"
REST="${ARG#* }"

module_at() {
  case "$1" in
    /system/apex/com.android.art.capex)          echo com.android.art ;;
    /system/apex/com.android.conscrypt.capex)    echo com.android.conscrypt ;;
    /apex/com.android.i18n.capex)                echo com.android.i18n ;;
    /system/apex/com.android.tzdata.apex)        echo com.android.tzdata ;;
    /system/framework/org.apache.http.legacy.jar) echo HTTP_LEGACY ;;
    /system/framework/framework-res.apk)          echo FRAMEWORK_RES ;;
    *) return 1 ;;
  esac
}

case "$CMD" in
  ls)
    echo "/system/apex/com.android.art.capex/ /system/apex/com.android.conscrypt.capex/ /apex/com.android.i18n.capex/ /system/apex/com.android.tzdata.apex/"
    exit 0 ;;

  dump)
    src="${REST%% *}"; dst="${REST#* }"
    m="$(module_at "$src" || true)"
    [ -n "$m" ] || exit 1
    case " ${HUSK_FAKE_MISSING:-} " in *" $m "*) exit 1 ;; esac
    mkdir -p "$(dirname "$dst")"

    case "$m" in
      HTTP_LEGACY|FRAMEWORK_RES)
        printf 'synthetic %s' "$m" > "$dst"
        exit 0 ;;
    esac

    # conscrypt carries apex_payload.img directly; the others wrap it in
    # original_apex, which is itself a zip.
    python3 - "$dst" "$m" <<'PY'
import io, os, sys, zipfile
dst, m = sys.argv[1], sys.argv[2]
payload = ('payload-for-' + m).encode()
buf = io.BytesIO()
if m == 'com.android.conscrypt':
    with zipfile.ZipFile(buf, 'w') as z:
        z.writestr('apex_payload.img', payload)
else:
    inner = io.BytesIO()
    with zipfile.ZipFile(inner, 'w') as z:
        z.writestr('apex_payload.img', payload)
    with zipfile.ZipFile(buf, 'w') as z:
        z.writestr('original_apex', inner.getvalue())
with open(dst, 'wb') as f:
    f.write(buf.getvalue())
PY
    exit 0 ;;

  rdump)
    # `rdump <src> <dst> <image>` -- three fields, so split rather than strip:
    # taking `${REST% *}` for dst leaves the source path attached to it, and
    # mkdir -p then writes the whole tree somewhere relative to the cwd.
    # Real debugfs reads the module out of the image, but the script names the
    # payload $WORK/<module>.img, so it is recoverable from the path given.
    set -- $REST
    dst="$2"
    img="${3:-$IMG}"
    # Real debugfs cannot open an image that is not there. Without this the
    # harness answered anyway, so the script that deleted its own payload before
    # unzipping it still produced a full apex root and the flow test passed --
    # a green test for a broken script, which is worse than no test.
    [ -f "$img" ] || { echo "fake debugfs: no such image: $img" >&2; exit 1; }
    m="$(basename "$img" .img)"
    mkdir -p "$dst"
    case "$m" in
      com.android.art)
        mkdir -p "$dst/javalib" "$dst/lib64"
        for j in core-oj core-libart okhttp bouncycastle apache-xml; do : > "$dst/javalib/$j.jar"; done
        for l in libandroidio libbase 'libc++' libexpat libjavacore libnativehelper libopenjdk; do : > "$dst/lib64/$l.so"; done ;;
      com.android.i18n)
        mkdir -p "$dst/javalib" "$dst/lib64" "$dst/etc/icu"
        : > "$dst/javalib/core-icu4j.jar"
        for l in libicu libicui18n libicuuc libicu_jni libandroidicu; do : > "$dst/lib64/$l.so"; done ;;
      com.android.tzdata)
        mkdir -p "$dst/etc"; : > "$dst/etc/zoneinfo" ;;
      com.android.conscrypt)
        mkdir -p "$dst/javalib" "$dst/lib64"
        : > "$dst/javalib/conscrypt.jar"
        for l in libjavacrypto libcrypto libssl; do : > "$dst/lib64/$l.so"; done ;;
      *) echo "fake debugfs: rdump does not know module '$m'" >&2; exit 1 ;;
    esac
    exit 0 ;;

  *) echo "fake debugfs: unsupported command '$CMD'" >&2; exit 1 ;;
esac