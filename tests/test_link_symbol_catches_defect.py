"""Prove the link-symbol check goes red when the JIT definitions are absent.

The fixture inside test_link_symbols.py proves the detector works on synthetic
input. This proves the *verdict* goes red on the real tree when the real
situation is recreated -- which is the one that cost four CI rounds. A check
that only ever runs against a tree that happens to be correct proves it would
have caught the bug it exists for; it does not.

Reversible: JitAbsent.c is moved aside, the check is run, and the file is put
back whatever happens.
"""
import os
import shutil
import subprocess
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

REPO = r"C:\Users\6u6\Documents\Husk15\Husk-main"
STUB = os.path.join(REPO, "src", "app", "Husk", "JitAbsent.c")
HIDDEN = STUB + ".hidden-by-defect-test"
TEST = os.path.join(REPO, "tests", "test_link_symbols.py")

EXPECTED = ["husk_ios_available_memory",
            "husk_ios_jit_detach",
            "husk_ios_jit_install_trap_handler",
            "husk_ios_jit_is_available",
            "husk_ios_jit_log_footprint",
            "husk_ios_jit_mapjit_works",
            "husk_ios_jit_prewarm",
            "husk_ios_jit_self_route"]

if not os.path.isfile(STUB):
    print("  FAIL %s is not there, so there is nothing to remove" % STUB)
    sys.exit(1)

print("=== with the definitions present ===")
clean = subprocess.run([sys.executable, TEST], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
print("  exit %d  (expected 0)" % clean.returncode)
if clean.returncode != 0:
    print(clean.stdout[-2500:])
    sys.exit(1)

os.replace(STUB, HIDDEN)
try:
    print("\n=== with src/app/Husk/JitAbsent.c removed ===")
    broke = subprocess.run([sys.executable, TEST], capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
    out = broke.stdout
    reported = sorted(s for s in EXPECTED if ("      " + s) in out)

    print("  exit %d  (expected non-zero)" % broke.returncode)
    print("  named %d of %d" % (len(reported), len(EXPECTED)))
    for s in EXPECTED:
        print("      %s %s" % ("ok  " if s in reported else "MISS", s))

    bad = []
    if broke.returncode == 0:
        bad.append("the check still passed with the definitions removed")
    if reported != sorted(EXPECTED):
        bad.append("it did not name exactly the eight JIT symbols (got %s)" % reported)
    if "no dead definitions" not in out:
        bad.append("it stopped before the dead-definition check, so this is not the same verdict")
finally:
    os.replace(HIDDEN, STUB)

print("\n=== restored ===")
again = subprocess.run([sys.executable, TEST], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
print("  exit %d  (expected 0)" % again.returncode)
if again.returncode != 0:
    bad.append("the check did not return to green once the file was back")

for b in bad:
    print("  FAIL %s" % b)
print("\n%d failed" % len(bad))
sys.exit(1 if bad else 0)