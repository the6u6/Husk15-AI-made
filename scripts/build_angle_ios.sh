#!/bin/bash
# Build ANGLE (EGL + GLES over Metal) for iOS arm64.
#
# This is the host-side GPU stack Husk needs. virglrenderer turns the guest's
# GL calls into real draw calls, but it needs an EGL/GLES implementation to make
# them against -- and iOS has no EGL at all. ANGLE supplies one on top of Metal.
# UTM does the same thing, which is what makes GPU acceleration inside a QEMU
# guest on iOS a solved problem rather than a hope.
#
# ANGLE is taken from WebKit rather than upstream because WebKit carries an
# Xcode project for it, which avoids needing depot_tools and gn. A blob-filtered
# sparse checkout keeps that to ~260 MB instead of cloning all of WebKit.
#
# That checkout tracks WebKit's main branch, so it moves under you: the tree
# that built here in March is not the tree that builds next month, and the
# difference arrives as a Clang diagnostic in a file nobody in this repo has
# heard of. Once a commit is known good, set WEBKIT_COMMIT to it and this
# becomes reproducible:
#
#     WEBKIT_COMMIT=<sha> ./scripts/build_angle_ios.sh
#
# or export it in CI. Leave it empty to track main.
#
# Pinning is not what the iOS 14 experiment needs. Xcode 15.4 cannot compile one
# line of current WebKit -- ResourceMap.h's `static_assert(kNeedsLock)`, which
# Apple clang diagnoses inside a discarded `if constexpr` branch. Everything
# else in the tree builds. Set HUSK_CLANG15_PATCHES=1 to drop that one
# redundant assert; see the block below the checkout for the full argument, and
# IOS14-EXPERIMENT.md section 3 for the failure it works around.
set -euo pipefail

HUSK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GPU="$HUSK_ROOT/third_party/gpu"
WK="$GPU/webkit"
PREFIX="$HUSK_ROOT/build/ios-arm64/sysroot"
LOG="$HUSK_ROOT/build/logs/angle-build.log"
WEBKIT_COMMIT="${WEBKIT_COMMIT:-}"
mkdir -p "$GPU" "$(dirname "$LOG")"

if [ ! -d "$WK" ]; then
    echo "==> sparse-cloning WebKit for its ANGLE tree${WEBKIT_COMMIT:+ at $WEBKIT_COMMIT}"
    git clone --depth 1 --filter=blob:none --sparse \
        https://github.com/WebKit/WebKit.git "$WK"
fi

# A --depth 1 clone has no history to check a commit out of, so fetch it by name
# and detach onto it. No-op when WEBKIT_COMMIT is empty.
if [ -n "$WEBKIT_COMMIT" ]; then
    have="$(git -C "$WK" rev-parse --verify --quiet HEAD || true)"
    if [ "$have" != "$WEBKIT_COMMIT" ]; then
        echo "==> pinning WebKit to $WEBKIT_COMMIT"
        git -C "$WK" fetch --depth 1 origin "$WEBKIT_COMMIT"
        git -C "$WK" checkout -q FETCH_HEAD
    fi
else
    echo "==> WebKit is tracking main; set WEBKIT_COMMIT to make this reproducible"
fi

# HUSK_CLANG15_PATCHES works around one Apple Clang bug in current ANGLE, for the
# same reason build_gpu_ios.sh patches virglrenderer: 2026 source through a 2024
# clang. Off by default -- the working 15.0/Xcode 26 build does not need it and
# the vendored trees should stay untouched unless they are asked to be.
#
# What happens without it, on Xcode 15.4 and any current WebKit:
#
#   src/libANGLE/ResourceMap.h:463:9: error: static assertion failed
#                                       due to requirement 'kNeedsLock'
#
# ResourceMap gained a lazily allocated second flat-resource array,
# mAdditionalFlatResources, published with a release store and read with an
# acquire load. It is guarded by
#
#     if constexpr (kAdditionalFlatResourcesSize > 0) {
#         static_assert(kNeedsLock);
#
# ANGLE_ENABLE_SHARE_CONTEXT_LOCK is *not* defined for this build -- it is in
# neither GCC_PREPROCESSOR_DEFINITIONS nor the xcconfig -- so the #else branch
# of the class body is live, and there kAdditionalFlatResourcesSize is the
# literal 0. The condition is therefore the compile-time constant `0 > 0`, the
# branch is a *discarded statement*, and a static_assert(false) inside a
# discarded statement is well formed and must not be diagnosed. Apple clang 15
# diagnoses it anyway.
#
# Removing the line is behaviour-preserving here, and not only because the
# branch is dead: the invariant it re-checks is already asserted at class scope
# a few hundred lines earlier --
#
#     static_assert(kAdditionalFlatResourcesSize == 0 || kNeedsLock,
#                   "kAdditionalFlatResourcesSize > 0 requires kNeedsLock ...");
#
# so the function-level assert is redundant. Nothing that can affect codegen is
# removed.
#
# The bug only fires where assignAboveCurrentFlatSize is actually instantiated,
# which is two files: renderer/metal/mtl_utils.mm and mtl_state_cache.mm. The
# other 163 translation units compile clean, which is why this reads as one bad
# line rather than a tree that does not build.
#
# The alternative is pinning WEBKIT_COMMIT to a 2024 tree, where the feature
# does not exist. That throws away a tree that is otherwise 92% compatible with
# this toolchain and may trade this error for others in the files that never
# got to compile, so the patch is the cheaper experiment.
HUSK_CLANG15_PATCHES="${HUSK_CLANG15_PATCHES:-0}"
if [ "$HUSK_CLANG15_PATCHES" != "0" ]; then
    rm_header="$WK/Source/ThirdParty/ANGLE/src/libANGLE/ResourceMap.h"
    if [ ! -f "$rm_header" ]; then
        echo "::warning::HUSK_CLANG15_PATCHES is on but $rm_header is absent; nothing to patch"
    elif grep -q '^[[:space:]]*static_assert(kNeedsLock);$' "$rm_header"; then
        # BSD sed: the -i suffix is a separate argument, not attached. '|' as the
        # delimiter so the slashes in the replacement need no escaping.
        sed -i '' 's|^\([[:space:]]*\)static_assert(kNeedsLock);$|\1// Husk patch: see scripts/build_angle_ios.sh|' \
            "$rm_header"
        echo "==> patched ResourceMap.h: dropped the redundant static_assert(kNeedsLock)"
    else
        echo "==> ResourceMap.h needs no patch (already applied, or the line is gone)"
    fi
fi

# Configurations and Tools/ccache are not optional: the ANGLE xcconfigs include
# ../../../../Tools/ccache/ccache.xcconfig, and the build fails to even start
# without it.
( cd "$WK" && git sparse-checkout set \
    Source/ThirdParty/ANGLE Configurations Tools/Scripts Tools/ccache )

cd "$WK/Source/ThirdParty/ANGLE"

# Three overrides worth explaining.
#
# WK_AVAILABILITY_OVERLAY_FLAGS points at a clang VFS overlay that WebKit
# generates to defuse availability annotations. Nothing in this subset of the
# tree generates it, so the build dies looking for availability-overlay.yaml.
# Clearing the flag drops the overlay -- which then surfaces the errors it was
# hiding, all of the form "MTLPixelFormatBC1_RGBA is only available on iOS
# 16.4". Those are enum constants, harmless to compile in; the one call that
# matters, supportsBCTextureCompression, sits behind @available, so the warning
# is turned off rather than the target raised. Husk deploys to 15.0 (14.0 in
# the iOS 14 experiment, IOS14-EXPERIMENT.md), and ANGLE
# must not sit ABOVE it: dyld refuses to load a dylib whose LC_BUILD_VERSION
# minos exceeds the running OS, so an ANGLE left at 15.5 would break the GL stack
# on 15.0-15.4. If WebKit's ANGLE xcconfigs refuse to go this low, raise both
# this and src/app/project.yml together -- never one without the other.
#
# The -Wno-error=thread-safety-* pair is newer, and is not about the deployment
# target at all. ANGLE's src/common/SimpleMutex.h annotates its methods
#     void lock()   ANGLE_ACQUIRE_CAPABILITY(mutex) { mutex.lock(); }
#     void unlock() ANGLE_RELEASE_CAPABILITY(mutex) { mutex.unlock(); }
# where `mutex` is a std::mutex. Clang's thread-safety analysis requires an
# acquire/release capability's argument to have the `capability` attribute, and
# std::mutex does not carry one. Older Clang accepted it; the one in Xcode 26
# (LLVM 21) reports four errors and WebKit's ANGLE xcconfig has -Werror on, so
# the tree does not compile:
#   'acquire_capability' attribute requires arguments whose type is annotated
#     with 'capability' attribute; type here is 'std::mutex'
#   'release_capability' attribute requires arguments whose type is annotated
#     with 'capability' attribute; type here is 'std::mutex'
#   expecting mutex 'mutex' to be held at the end of function
#   mutex 'mutex' is still held at the end of function
# MutexOnStd is the non-futex path, so this is the code Apple platforms
# actually compile -- there is no avoiding it short of pinning an old tree.
# -Wno-error rather than -Wno-: the warnings still print, only the promotion to
# an error is dropped, so a genuine threading mistake in Husk's own sources is
# still visible. The flags come after $(inherited), which is what makes them
# override the -Werror the xcconfig set.
ALIASES="$GPU/angle-aliases.txt"

ANGLE_WARN_FLAGS='-Wno-unguarded-availability-new -Wno-error=thread-safety-attributes -Wno-error=thread-safety-analysis'

angle_build () {
    # The alias flag has to reach xcodebuild as ONE argument. Written inline as
    # an unquoted ${1:+...} it word-splits at the space, xcodebuild sees a bare
    # "-Wl,-alias_list,..." and dies with "invalid option" -- which the error
    # filter below then hides, because it drops lines mentioning xcodebuild.
    # Build it in an array instead, and expand that array quoted.
    #
    # $(inherited) is for xcodebuild to expand, not the shell, so it stays
    # backslash-escaped here.
    local ldflags=()
    if [ -n "${1:-}" ]; then
        ldflags=("OTHER_LDFLAGS=\$(inherited) -Wl,-alias_list,$1")
    fi

    # DEVELOPER_DIR has to be handed through explicitly. `env -i` wipes the
    # environment, which is deliberate here (the ANGLE xcconfigs read a lot of
    # ambient state), but setup-xcode selects a build machine's Xcode purely by
    # exporting DEVELOPER_DIR -- so without this, ANGLE silently builds with
    # whatever the image defaults to while the rest of Husk uses the selected
    # one. ${VAR:+...} expands to nothing when the variable is unset, which is
    # the normal local case, and is safe under `set -u`.
    env -i PATH="$PATH" HOME="$HOME" \
        ${DEVELOPER_DIR:+DEVELOPER_DIR="$DEVELOPER_DIR"} \
        xcodebuild archive \
        -archivePath "ANGLE" -scheme "ANGLE" \
        -sdk iphoneos -arch arm64 -configuration Release \
        WEBCORE_LIBRARY_DIR="/usr/local/lib" NORMAL_UMBRELLA_FRAMEWORKS_DIR="" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
        WK_AVAILABILITY_OVERLAY_FLAGS="" WK_AVAILABILITY_OVERLAY_SWIFT_FLAGS="" \
        IPHONEOS_DEPLOYMENT_TARGET="13.0" \
        OTHER_CFLAGS='$(inherited) '"$ANGLE_WARN_FLAGS" \
        OTHER_CPLUSPLUSFLAGS='$(inherited) '"$ANGLE_WARN_FLAGS" \
        ${ldflags[@]+"${ldflags[@]}"} \
        > "$LOG" 2>&1 \
      || { echo "ANGLE build failed; last errors:" >&2
           grep -a "error:\|^ld: " "$LOG" | head -10 >&2; exit 1; }
}

# Two passes, because of a name mismatch.
#
# WebKit builds ANGLE with its entry points renamed -- the dylib exports
# EGL_ChooseConfig, not eglChooseConfig -- since WebCore reaches them through
# ANGLE's own loader. libepoxy and virglrenderer expect the standard names.
# Rather than hand-write ~115 forwarding functions, the second pass relinks with
# ld's -alias_list, which adds the standard name as an alias of each renamed
# symbol. No wrappers, no extra indirection at call time.
#
# EGL only, deliberately. Aliasing the 828 GL_* exports the same way fails with
# "ld: 828 duplicate symbols" -- ANGLE already carries internal gl* symbols that
# the aliases collide with. It is also unnecessary: epoxy resolves GL entry
# points through eglGetProcAddress, so EGL is the only surface that must be
# reachable by its standard name.
echo "==> building ANGLE for iOS arm64, pass 1 (log: $LOG)"
angle_build ""

echo "==> generating EGL symbol aliases"
nm -g "ANGLE.xcarchive/Products/usr/local/lib/libANGLE-shared.dylib" \
  | awk '$2=="T"{print $3}' | grep -E '^_EGL_' \
  | awk '{o=$1; a=$1; sub(/^_EGL_/,"_egl",a); print o, a}' > "$ALIASES"
echo "    $(wc -l < "$ALIASES") aliases"

echo "==> pass 2, relinking with standard EGL names"
angle_build "$ALIASES"

DYLIB="ANGLE.xcarchive/Products/usr/local/lib/libANGLE-shared.dylib"
[ -f "$DYLIB" ] || { echo "no dylib at $DYLIB" >&2; exit 1; }

install -d "$PREFIX/lib" "$PREFIX/include"
cp "$DYLIB" "$PREFIX/lib/"
rsync -a "include/" "$PREFIX/include/"

# WebKit ships it for loading out of WebCore.framework; ours is embedded in the
# app, so the install name has to say so or dyld will not find it at runtime.
install_name_tool -id "@rpath/libANGLE-shared.dylib" "$PREFIX/lib/libANGLE-shared.dylib"

echo "==> staged $(ls -lh "$PREFIX/lib/libANGLE-shared.dylib" | awk '{print $5}') to $PREFIX/lib"
otool -D "$PREFIX/lib/libANGLE-shared.dylib" | tail -1
echo "==> standard EGL entry points exported: $(nm -g "$PREFIX/lib/libANGLE-shared.dylib" | grep -c ' T _egl')"
