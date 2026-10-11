r"""Run build_java_runtime_ci.sh end to end against a fake system image.

Five CI round-trips on this script each found a different assumption to be
wrong, and each cost a 1.1 GB download and a macOS runner. The assumptions are
cheap to get wrong and expensive to discover: the last one was a `rm -f` placed
after the dump it was meant to precede, so it deleted the file it had just
verified -- and every module then failed in zipfile with the dump having worked
perfectly. Nothing here can see that. `bash -n` passes, the script reads
correctly, and every line is defensible in isolation.

So the flow is exercised here instead. tests/fake_debugfs.sh stands in for
debugfs and serves a synthetic image, and build_java_runtime.sh is replaced with
a stub that checks the same contract, so what runs is this fork's extraction and
preflight with everything else held constant.

Two cases:

  the happy path      every module present; the apex root must come out in the
                      layout build_java_runtime.sh expects, including the module
                      directory level -- the bug that made com.android.art
                      extract successfully and then not be found.

  a module missing    HUSK_FAKE_MISSING=com.android.tzdata. The preflight must
                      fail, and must name tzdata rather than dying on whichever
                      file happened to be copied first.

Two notes on the harness, neither of them about the script:

  The stub JDK is javac.exe. The script gates on `[ -x "$JDK/bin/javac" ]`, and
  under MSYS on NTFS `-x` is false for everything that does not carry an
  executable extension.

  PATH comes from `bash -c 'echo $PATH'`, not os.environ. Passing the Windows
  PATH through leaves /usr/bin off the search path, so the script's `find`
  resolves to C:\Windows\System32\find.exe -- the text searcher rather than the
  file walker -- which takes a path and a maxdepth as a search pattern and
  filenames, and appears to hang rather than fail.
"""
import os
import shutil
import subprocess
import sys
import tempfile

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
BASH = r"C:\Program Files\Git\bin\bash.exe"
FAKE = os.path.join(HERE, "fake_debugfs.sh")


def bash_path():
    """The PATH Git Bash gives itself -- see the module docstring."""
    r = subprocess.run([BASH, "-c", "printf '%s' \"$PATH\""], capture_output=True)
    return r.stdout.decode("utf-8", "replace").strip()


STUB_BJR = '''#!/bin/bash
# Stands in for the upstream script: checks the apex root it was given and
# writes the one artefact the caller verifies afterwards.
set -u
APEX="${1:?}"; OUT="$(cd "$(dirname "$0")/.." && pwd)/build/java-runtime"
rm -rf "$OUT"; mkdir -p "$OUT"
miss=0
for f in com.android.art/javalib/core-oj.jar com.android.art/lib64/libbase.so \\
         com.android.i18n/javalib/core-icu4j.jar com.android.i18n/etc/icu \\
         com.android.tzdata/etc com.android.conscrypt/javalib/conscrypt.jar \\
         com.android.conscrypt/lib64/libssl.so; do
  [ -e "$APEX/$f" ] || { echo "stub: apex root is missing $f" >&2; miss=1; }
done
[ "$miss" -eq 0 ] || exit 1
echo stub > "$OUT/husk-framework.dex"
exit 0
'''


def shim(path, body):
    for ext in ("", ".exe"):
        open(path + ext, "w", newline="\n").write(body)


def make_sandbox(root):
    """A tree the script can run in unchanged."""
    shutil.copytree(os.path.join(REPO, "scripts"), os.path.join(root, "scripts"))
    for d in ("bin", os.path.join("jdk", "bin"), "build"):
        os.makedirs(os.path.join(root, d))

    shutil.copy(FAKE, os.path.join(root, "bin", "debugfs"))
    shutil.copy(FAKE, os.path.join(root, "bin", "debugfs.exe"))

    shim(os.path.join(root, "jdk", "bin", "javac"), "#!/bin/sh\nexit 0\n")
    # The script gates on `command -v python3` and `command -v qemu-img` and
    # exits 0 when either is missing. Without these the run stops before touching
    # anything and every assertion below passes vacuously against an empty dir.
    shim(os.path.join(root, "bin", "python3"),
         '#!/bin/sh\nexec "%s" "$@"\n' % sys.executable)
    shim(os.path.join(root, "bin", "qemu-img"), "#!/bin/sh\nexit 0\n")

    open(os.path.join(root, "scripts", "build_java_runtime.sh"), "w",
         newline="\n").write(STUB_BJR)

    # Both files, system.img newer, so the GPT unpack is skipped and the test
    # exercises extraction rather than the parser (which has its own test).
    vda = os.path.join(root, "build", "lineage-vda.qcow2")
    sysimg = os.path.join(root, "build", "system.img")
    open(vda, "w").write("synthetic\n")
    open(sysimg, "w").write("synthetic\n")
    os.utime(vda, (1000, 1000))
    os.utime(sysimg, (2000, 2000))
    open(os.path.join(root, "build", "r8.jar"), "w").write("stub\n")
    return root


def run(root, missing=None, timeout=120):
    env = dict(os.environ)
    env["PATH"] = os.path.join(root, "bin") + ":" + bash_path()
    env["HUSK_JDK"] = os.path.join(root, "jdk")
    env["HUSK_D8"] = os.path.join(root, "build", "r8.jar")
    if missing:
        env["HUSK_FAKE_MISSING"] = missing
    return subprocess.run(
        [BASH, os.path.join(root, "scripts", "build_java_runtime_ci.sh"),
         os.path.join(root, "build", "lineage-vda.qcow2")],
        capture_output=True, env=env, timeout=timeout)


def run_checks(repo, work, quiet=False):
    """The checks, against an explicit repo. Returns the number of failures."""
    global REPO
    REPO = repo
    fails = []

    def emit(msg):
        if not quiet:
            print(msg)

    def check(label, cond, detail=""):
        emit("  %s %s%s" % ("ok  " if cond else "FAIL", label,
                            ("\n         " + detail) if detail and not cond else ""))
        if not cond:
            fails.append(label)

    os.makedirs(work, exist_ok=True)
    try:
        emit("=== case 1: happy path ===")
        sb = make_sandbox(os.path.join(work, "ok"))
        r = run(sb)
        out = (r.stdout + r.stderr).decode("utf-8", "replace")
        emit("    exit %d" % r.returncode)
        for line in out.strip().splitlines()[-5:]:
            emit("    | %s" % line[:96])

        apex = os.path.join(sb, "build", "java-apex-root")
        for f in ("com.android.art/javalib/core-oj.jar",
                  "com.android.art/lib64/libbase.so",
                  "com.android.i18n/javalib/core-icu4j.jar",
                  "com.android.i18n/etc/icu",
                  "com.android.tzdata/etc",
                  "com.android.conscrypt/javalib/conscrypt.jar"):
            check("apex root has %s" % f, os.path.exists(os.path.join(apex, f.replace("/", os.sep))))

        check("the module directory level is present (the bug that hid com.android.art)",
              os.path.isdir(os.path.join(apex, "com.android.art", "javalib")))
        check("the script succeeded", r.returncode == 0, out.strip()[-400:])
        check("java-runtime/husk-framework.dex was written",
              os.path.exists(os.path.join(sb, "build", "java-runtime", "husk-framework.dex")))
        check("nothing was reported as extracted to nothing",
              "extracted to nothing" not in out,
              "; ".join(l for l in out.splitlines() if "nothing" in l))

        emit("\n=== case 2: com.android.tzdata absent from the image ===")
        sb2 = make_sandbox(os.path.join(work, "missing"))
        r2 = run(sb2, missing="com.android.tzdata")
        out2 = (r2.stdout + r2.stderr).decode("utf-8", "replace")
        emit("    exit %d" % r2.returncode)
        for line in out2.strip().splitlines()[-5:]:
            emit("    | %s" % line[:96])

        check("the run failed rather than shipping a partial runtime", r2.returncode != 0)
        check("it named the module that is missing", "com.android.tzdata" in out2)
        check("the other three still extracted",
              all(os.path.isdir(os.path.join(sb2, "build", "java-apex-root", m))
                  for m in ("com.android.art", "com.android.i18n", "com.android.conscrypt")))
        check("no husk-framework.dex, so it stopped before assembling",
              not os.path.exists(os.path.join(sb2, "build", "java-runtime", "husk-framework.dex")))
    finally:
        shutil.rmtree(work, ignore_errors=True)

    return len(fails)


def main_quiet(root, repo=None, quiet=True):
    """Used by the proof script: the identical checks, an explicit repo, no noise."""
    work = tempfile.mkdtemp()
    try:
        return run_checks(repo or REPO, root, quiet=quiet)
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    work = tempfile.mkdtemp()
    try:
        n = run_checks(REPO, work)
        print("\n%d failed" % n)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    sys.exit(1 if n else 0)