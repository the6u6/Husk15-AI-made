#!/bin/bash
# Husk: build everything from a clean checkout to the IPA, in order.
#
# Runs on macOS with Xcode. Usage: ./scripts/ci_build.sh [output.ipa]
set -euo pipefail

HUSK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$HUSK_ROOT/build/Husk.ipa}"
cd "$HUSK_ROOT"

step() { printf '\n\033[1;34m##### %s\033[0m\n' "$*"; }

step "fetch sources"
./scripts/fetch_sources.sh

step "dependencies: libffi glib pixman libucontext libslirp"
./scripts/build_ios.sh libffi glib pixman libucontext libslirp

# build_gpu_ios.sh asks for cross-ios-darwin.meson, which no script generates.
# build_ios.sh writes cross-darwin.meson, the file it describes (host system
# darwin, subsystem ios), under a different name.
cp build/ios-arm64/cross-darwin.meson build/ios-arm64/cross-ios-darwin.meson

if [ ! -f build/ios-arm64/sysroot/lib/libANGLE-shared.dylib ]; then
    step "ANGLE (EGL/GLES over Metal)"
    ./scripts/build_angle_ios.sh
fi

if [ ! -f build/ios-arm64/sysroot/lib/libvirglrenderer.a ]; then
    step "libepoxy + virglrenderer"
    # build_ios.sh's cross environment, which the GPU script assumes is set.
    PKG_CONFIG_LIBDIR="$HUSK_ROOT/build/ios-arm64/sysroot/lib/pkgconfig:$HUSK_ROOT/build/ios-arm64/sysroot/share/pkgconfig" \
        ./scripts/build_gpu_ios.sh
fi

# REMOVED: the QEMU cross build, the Husk patches into it, and the guest
# kernel/initramfs. Husk no longer runs a full Android system. The translation
# layer (src/translation-layer-next) is a separate C runtime and is untouched.
# Dropping these stages is most of this script's wall clock. The scripts are
# still on disk if anyone wants them back: build_ios.sh, integrate_husk.sh,
# fetch_phase0_guest.sh, build_phase1_image.sh.

if [ ! -d build/ios-arm64/lib/MoltenVK.xcframework ]; then
    step "MoltenVK (Vulkan over Metal, for Unreal Engine games)"
    ./scripts/build_moltenvk_ios.sh
fi

step "on-device pairing (Rust)"
./scripts/build_rppairing_ios.sh

# Translation-layer resources that go in the bundle as resources rather than as
# code: Android's CA certificates and system fonts for Flutter, and Husk's
# Dalvik runtime for Java apps. Both are derived from the Lineage guest image,
# which build_android_system.sh and build_java_runtime.sh expect to already be
# unpacked somewhere -- historically a path on someone's external drive, and in
# no CI at all until now.
#
# Optional by design: without them the app still builds and every engine except
# Java and Flutter works, so a failure here warns rather than stopping the build.
# Set HUSK_SKIP_TRANSLATION_RESOURCES=1 to skip the ~1.1 GB image download
# entirely, which is the right call for a pull-request build.
if [ "${HUSK_SKIP_TRANSLATION_RESOURCES:-0}" != "1" ]; then
    step "translation-layer resources (CA certs, fonts, Java runtime)"
    # download the guest image and r8.jar into build/, which the workflow caches
    ./scripts/fetch_translation_resources.sh || echo "warning: resource fetch failed; continuing without" >&2
    # CA certificates + system fonts, for Flutter and for TLS
    [ -d build/android-system ] || ./scripts/build_android_system.sh build/lineage-vda.qcow2 \
        || echo "warning: android-system failed; Flutter apps will have no system fonts" >&2
    # libcore, ICU, tzdata, conscrypt and Husk's Java framework, for Java apps
    ./scripts/build_java_runtime_ci.sh build/lineage-vda.qcow2 \
        || echo "warning: java-runtime failed; Java apps will not start" >&2
else
    echo "==> HUSK_SKIP_TRANSLATION_RESOURCES=1: skipping CA certs, fonts and the Java runtime"
fi

step "app + IPA"
mkdir -p "$(dirname "$OUT")"
./scripts/package_ipa.sh "$OUT"
./scripts/package_ipa.sh --trollstore "${OUT%.ipa}.tipa"
