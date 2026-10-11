#!/bin/bash
# Fetch the two inputs scripts/build_java_runtime_ci.sh needs but cannot derive:
# the Lineage guest image, and the r8.jar its dex step uses.
#
#   scripts/fetch_translation_resources.sh
#
# Both land in build/, which the workflow caches. The image is ~1.1 GB, so this
# runs once per cache miss rather than once per build.
#
# The URL is derived from GuestImage.swift rather than repeated here: the tag
# and the image version are that file's constants, and a hardcoded copy is how
# the two drift apart.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src/app/Husk/GuestImage.swift"
BUILD="$ROOT/build"
mkdir -p "$BUILD"

[ -f "$SRC" ] || { echo "error: $SRC not found" >&2; exit 1; }

const() { # const <name>  -> the string literal assigned to that static let
  v="$(sed -n "s/.*static let $1 *= *\"\([^\"]*\)\".*/\1/p" "$SRC" | head -1)"
  [ -n "$v" ] || { echo "error: could not read '$1' from GuestImage.swift" >&2; exit 1; }
  printf '%s' "$v"
}

TAG="$(const dependenciesTag)"
VER="$(const imageVersion)"
IMG="$BUILD/lineage-vda.qcow2"
URL="https://github.com/Leviidev/Husk/releases/download/$TAG/vda-$VER.qcow2"

# ---- the guest image -----------------------------------------------------------
if [ -s "$IMG" ]; then
  echo "==> guest image already present ($(du -sh "$IMG" | cut -f1))"
else
  echo "==> downloading $URL"
  curl -fL --retry 3 --retry-delay 10 -C - -o "$IMG.part" "$URL"
  mv "$IMG.part" "$IMG"
  echo "==> guest image: $(du -sh "$IMG" | cut -f1)"
fi

# ---- r8.jar --------------------------------------------------------------------
# src/java-framework/build.sh wants R8 8.5 or newer: the d8 in build-tools 34
# crashes on the classes it feeds it. That is its comment, repeated here because
# the reason for the pin is not visible from the artifact alone.
R8_VER="8.6.17"
R8="$BUILD/r8.jar"
if [ -s "$R8" ]; then
  echo "==> r8.jar already present"
else
  R8_URL="https://dl.google.com/dl/android/maven2/com/android/tools/r8/$R8_VER/r8-$R8_VER.jar"
  echo "==> downloading $R8_URL"
  curl -fL --retry 3 --retry-delay 10 -o "$R8.part" "$R8_URL"
  mv "$R8.part" "$R8"
fi

echo "==> inputs ready: image $(du -sh "$IMG" | cut -f1), r8 $(du -h "$R8" | cut -f1)"
