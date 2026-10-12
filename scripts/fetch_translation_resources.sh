#!/bin/bash
# Fetch the two inputs scripts/build_java_runtime_ci.sh needs but cannot derive:
# the Lineage guest image, and the r8.jar its dex step uses.
#
#   scripts/fetch_translation_resources.sh
#
# Both land in build/, which the workflow caches. The image is ~1.1 GB, so this
# runs once per cache miss rather than once per build.
#
# Why an image is downloaded at all when there is no guest: it is the only copy
# of Android's CA certificates, system fonts and APEX modules that anyone has,
# and the translation layer's Java and Flutter support is built out of them.
#
# These two used to be read out of src/app/Husk/GuestImage.swift, which the VM
# removal deleted. Reading them was to avoid drifting from that file's constants;
# with the file gone there is nothing to drift from, so they live here. They were
# "lineage-v2" and "v12" at the point it was deleted -- if the release moves,
# change them here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
mkdir -p "$BUILD"

TAG="lineage-v2"
VER="v12"
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
