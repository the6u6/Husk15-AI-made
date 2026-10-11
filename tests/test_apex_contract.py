"""Check the extraction layout, and that the preflight list matches the real contract.

Two things the last CI run got wrong, neither of which a syntax check sees:

  The directory level. `debugfs rdump / D` produces D/<contents>, so copying
  D/. into the apex root put javalib/ and lib64/ at its top level. The script
  needs com.android.art/javalib/core-oj.jar. Verified here by running the copy
  the script runs, over a directory shaped the way rdump leaves one.

  The preflight list. build_java_runtime.sh is upstream's and will not change to
  suit us; if this list drifts from what it actually copies, the preflight
  passes on an apex root that is still missing something, and the run fails at
  the first `cp` again -- one file, no list. So the list is derived from the
  script rather than trusted.

The derivation walks the script a line at a time rather than matching whole
constructs, because the loops come in both shapes -- `for j in ...; do copy ...;
done` on one line for the art jars, and spread over three for the conscrypt
libraries. An earlier regex only matched the second and reported the art entries
as spurious, which had the check failing on the thing it was meant to verify.

Lines guarded by `[ -f ... ] &&` are optional and are excluded on purpose: they
must not fail a build.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

REPO = r"C:\Users\6u6\Documents\Husk15\Husk-main"
BJR = os.path.join(REPO, "scripts", "build_java_runtime.sh")
CI = os.path.join(REPO, "scripts", "build_java_runtime_ci.sh")
BASH = r"C:\Program Files\Git\bin\bash.exe"

fails = []


def check(label, cond, detail=""):
    print("  %s %s%s" % ("ok  " if cond else "FAIL", label,
                        ("\n         " + detail) if detail and not cond else ""))
    if not cond:
        fails.append(label)


# ---- 1. derive the contract from build_java_runtime.sh, line at a time ---------
src = open(BJR, encoding="utf-8").read().split("\n")

required, optional = set(), set()
var, names = None, []

for line in src:
    hdr = re.search(r"for (\w+) in ([^;]+); do", line)
    if hdr:
        var, names = hdr.group(1), hdr.group(2).split()
    guarded = bool(re.search(r"\[ -f [^\]]+\] &&", line))
    # Three positions for the copy, all of which occur in build_java_runtime.sh:
    #   `copy X` at the start of its own line       (the tzdata/conscrypt entries)
    #   `do copy X; done` on one line               (the art and conscrypt loops)
    #   `... ] && copy X; done`                    (the i18n lib64 loop, guarded)
    # Missing the third is not cosmetic: those files are optional, and a preflight
    # that listed them would fail a build that has a perfectly good runtime.
    for m in re.finditer(r"(?:^|;\s*do\s+|&&\s*)copy ([^\s;]+)|cp -R \"\$APEX/([^\"]+)\"", line):
        path = m.group(1) or m.group(2)
        path = path.strip().rstrip(";").rstrip('"')
        # Replace the shell token, not the bare name. build_java_runtime.sh's
        # loops use `j` and `l`, which occur inside `javalib`, `lib64` and
        # `.jar` -- substituting the name alone turns core-oj into
        # "com.android.art/core-ojavalib/$core-oj.core-ojar".
        hit = var and ("$" + var) in path
        targets = [path.replace("$" + var, n) for n in names] if hit else [path]
        (optional if guarded else required).update(targets)
    if re.search(r"\bdo\b.*;\s*done\s*$", line) or line.strip() == "done":
        var, names = None, []

print("=== required by build_java_runtime.sh (%d) ===" % len(required))
for r in sorted(required):
    print("    %s" % r)
print("=== guarded by [ -f ], so optional (%d) ===" % len(optional))
for r in sorted(optional):
    print("    %s" % r)

# ---- 2. compare against the preflight list in the CI script --------------------
ci = open(CI, encoding="utf-8").read()
m = re.search(r'REQUIRED="\n(.*?)\n"', ci, re.S)
if not m:
    print("\n  FAIL could not find the REQUIRED list")
    sys.exit(1)
listed = set(m.group(1).split())

print("\n=== preflight list vs contract ===")
check("every required path is in the preflight list", not (required - listed),
      "absent from the preflight: %s" % sorted(required - listed))
check("the preflight lists nothing optional", not (listed - required),
      "extra in the preflight: %s" % sorted(listed - required))

# ---- 3. the directory level, by running the copy the script runs ----------------
print("\n=== directory level: the copy the script performs ===")
work = tempfile.mkdtemp()
try:
    # shaped the way `debugfs rdump / D` leaves a directory: contents at D's top
    dumped = os.path.join(work, "m")
    os.makedirs(os.path.join(dumped, "javalib"))
    os.makedirs(os.path.join(dumped, "lib64"))
    open(os.path.join(dumped, "javalib", "core-oj.jar"), "w").close()
    open(os.path.join(dumped, "lib64", "libbase.so"), "w").close()

    apex_out = os.path.join(work, "apex-root")
    subprocess.run([BASH, "-c", 'mkdir -p "$1/$2" && cp -R "$3/." "$1/$2/"',
                    "x", apex_out, "com.android.art", dumped], check=True)
    want = os.path.join(apex_out, "com.android.art", "javalib", "core-oj.jar")
    check("com.android.art/javalib/core-oj.jar is where build_java_runtime.sh looks",
          os.path.exists(want),
          "root holds %s" % os.listdir(apex_out))

    wrong = os.path.join(work, "wrong")
    os.makedirs(wrong)
    subprocess.run([BASH, "-c", 'cp -R "$1/." "$2/"', "x", dumped, wrong], check=True)
    check("the old form really did flatten it (so that was the bug)",
          os.path.exists(os.path.join(wrong, "javalib", "core-oj.jar"))
          and not os.path.exists(os.path.join(wrong, "com.android.art")))
finally:
    shutil.rmtree(work, ignore_errors=True)

print("\n%d failed" % len(fails))
sys.exit(1 if fails else 0)