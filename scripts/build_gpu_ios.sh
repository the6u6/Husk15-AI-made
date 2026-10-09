#!/bin/bash
# Build the host GPU stack for iOS: libepoxy + virglrenderer.
#
# These turn the guest's GL calls into real draw calls on the phone's GPU
# instead of pixels rasterised in software by an emulated CPU. ANGLE supplies
# the EGL/GLES implementation underneath (scripts/build_angle_ios.sh); run that
# first.
#
# Both come from UTM's forks at the commits UTM pins, not from upstream.
# Upstream libepoxy 1.5.10 does not build for iOS at all -- dispatch_egl.c fails
# with "use of undeclared identifier 'EGLDisplay'" -- and the Darwin and Metal
# support in both projects lives in these forks. They are MIT, so linking them
# with Husk's GPLv2+ code is fine; it is only UTM's own Apache-2.0 app code that
# has to be left alone.
set -euo pipefail

HUSK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GPU="$HUSK_ROOT/third_party/gpu"
PREFIX="$HUSK_ROOT/build/ios-arm64/sysroot"
LOGS="$HUSK_ROOT/build/logs"
MESON=/opt/homebrew/bin/meson
NINJA=/opt/homebrew/bin/ninja
mkdir -p "$GPU" "$LOGS"

EPOXY_COMMIT=bf98587477fe68d07b93319ece7b40a7d0e2eabe
VIRGL_COMMIT=482f9d8b8c2d2288efa10a027116216909d2c226

# virglrenderer's src/gallium/meson.build:72 does a `find_installation('yaml')`,
# which runs `import yaml` in whichever python MESON ITSELF runs on -- not
# whatever python3 is first on PATH. meson is a Homebrew binary whose shebang
# points into /opt/homebrew/opt/python@3.14, and that interpreter does not ship
# PyYAML:
#
#   src/gallium/meson.build:72:16: ERROR: /opt/homebrew/bin/python3 is missing
#   modules: yaml
#
# `brew install pyyaml` is not the answer: Homebrew has disabled that formula
# because it no longer meets their criteria, so `brew install pyyaml` fails with
# "No available formula". Apple's own python3 has no yaml either. This is not
# about iOS 15 or about Xcode; it is a gap that only shows on a machine where
# nothing else has already pulled PyYAML in, which is every fresh CI runner.
#
# So put the module where meson's interpreter will find it rather than trying to
# change meson's interpreter.
#
# The interpreter is taken from meson's own shebang, NOT from `python3` on PATH:
# they need not be the same version, and a --user install into one does not help
# the other, because user site-packages are per-version
# (~/Library/Python/3.14/... vs 3.13/...). PYTHONPATH is used instead of --user
# precisely because it is version-agnostic -- every python3.x on the box will
# find a pure-Python `yaml` there -- so it cannot go stale against whichever
# Homebrew python meson happens to be built against.
MESON_PY="$(head -1 "$MESON" 2>/dev/null | sed -e 's|^#!||' -e 's|[[:space:]].*$||')"
[ -x "$MESON_PY" ] || MESON_PY="${MESON_PYTHON:-/opt/homebrew/bin/python3}"

ensure_meson_yaml () {
    if "$MESON_PY" -c 'import yaml' 2>/dev/null; then
        echo "==> PyYAML already available to $MESON_PY"
        return 0
    fi

    echo "==> giving the meson interpreter a PyYAML ($MESON_PY)"

    local venv="${TMPDIR:-/tmp}"
    venv="${venv%/}/husk-meson-py"
    if [ ! -x "$venv/bin/pip" ] && ! "$MESON_PY" -m venv "$venv" >/dev/null 2>&1; then
        echo "    could not create a venv" >&2
        return 1
    fi
    "$venv/bin/pip" install --quiet --disable-pip-version-check pyyaml >/dev/null 2>&1 || true

    local site
    # shellcheck disable=SC2086
    site="$(echo "$venv"/lib/python*/site-packages 2>/dev/null | head -1)"
    if [ -z "$site" ] || [ ! -d "$site" ]; then
        echo "    no site-packages under $venv" >&2
        return 1
    fi

    # meson is a child process of this script, so it inherits PYTHONPATH and
    # finds the module without its interpreter ever changing.
    export PYTHONPATH="${site}${PYTHONPATH:+:$PYTHONPATH}"

    if "$MESON_PY" -c 'import yaml' 2>/dev/null; then
        echo "    installed into a venv, exposed via PYTHONPATH=$site"
        return 0
    fi
    return 1
}

ensure_meson_yaml || {
    cat >&2 <<'MSG'
error: the meson interpreter cannot import yaml, and PyYAML could not be installed.
       virglrenderer needs it. Fix by hand with:
         python3 -m venv /tmp/husk-meson-py
         /tmp/husk-meson-py/bin/pip install pyyaml
         export PYTHONPATH=/tmp/husk-meson-py/lib/python3.14/site-packages
MSG
    exit 1
}

fetch () {
    local dir="$1"
    local url="$2"
    local commit="$3"
    [ -d "$GPU/$dir" ] || git clone -q "$url" "$GPU/$dir"
    ( cd "$GPU/$dir" && git checkout -q "$commit" )
}

fetch epoxy https://github.com/utmapp/libepoxy.git   "$EPOXY_COMMIT"
fetch virgl https://github.com/utmapp/virglrenderer.git "$VIRGL_COMMIT"

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

echo "==> libepoxy"
# epoxy dlopens EGL by a hardcoded per-platform name, and on iOS that is
# "EGL.framework/EGL". UTM satisfies it by packaging ANGLE as a framework; Husk
# embeds plain dylibs, so the name is repointed at ours instead. dlopen resolves
# @rpath against the loading image's LC_RPATH, which for an iOS app is its own
# Frameworks directory -- exactly how the QEMU dylib beside it is found.
( cd "$GPU/epoxy"
  git checkout -q -- src/dispatch_common.c 2>/dev/null || true
  patch -p1 --silent < "$HUSK_ROOT/patches/husk-epoxy-ios-egl-path.patch"
  rm -rf _build
  $MESON setup _build --cross-file "$HUSK_ROOT/build/ios-arm64/cross-ios.meson" \
      --prefix "$PREFIX" --default-library=static \
      -Dtests=false -Dglx=no -Degl=yes -Dx11=false
  $NINJA -C _build install ) > "$LOGS/epoxy.log" 2>&1 \
  || { echo "epoxy failed:" >&2; grep -a "error:\|FAILED:" "$LOGS/epoxy.log" | head -10 >&2; exit 1; }
echo "    $(ls -lh "$PREFIX/lib/libepoxy.a" | awk '{print $5}')"

echo "==> virglrenderer (render server in thread mode)"
# Two things this needs that the normal cross file does not give it.
#
# cross-ios-darwin.meson sets host system = darwin rather than ios. virglrenderer
# gates its Metal backend on host_machine.system() == 'darwin', so with 'ios' it
# never calls add_languages('objc') and dies with "No host machine compiler for
# vrend_metal.m". UTM's meson_darwin_build forces the same thing.
#
# render-server-mode=thread, because iOS cannot spawn processes -- the same
# constraint that makes QEMU an in-process library here. UTM uses process mode
# on macOS and thread mode everywhere else for exactly this reason.
( cd "$GPU/virgl"
  rm -rf _build
  $MESON setup _build --cross-file "$HUSK_ROOT/build/ios-arm64/cross-ios-darwin.meson" \
      --prefix "$PREFIX" --default-library=static \
      -Dtests=false -Dcheck-gl-errors=false -Dvenus=false -Dvulkan-dload=false \
      -Drender-server-mode=thread
  $NINJA -C _build install ) > "$LOGS/virgl.log" 2>&1 \
  || { echo "virglrenderer failed:" >&2; grep -a "error:\|FAILED:\|ERROR" "$LOGS/virgl.log" | head -10 >&2; exit 1; }
echo "    $(ls -lh "$PREFIX/lib/libvirglrenderer.a" | awk '{print $5}')"

echo "==> done; QEMU can now be configured with --enable-opengl --enable-virglrenderer"
