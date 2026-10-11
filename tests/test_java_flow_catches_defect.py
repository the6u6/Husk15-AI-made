"""Prove the flow test catches the bug that actually shipped.

A green test means nothing until it has been shown to go red on the defect it
exists for. The defect here was an `rm -f` placed after the dump it was meant to
precede, so it deleted the file it had just verified -- every module then failed
in zipfile with the dump having worked perfectly, and the discovery loop had
already printed "com.android.art <- /system/apex/com.android.art.capex".

The script is reverted to that in a temp copy and the flow test is run against
it. Nothing is written back.
"""
import os
import shutil
import sys
import tempfile

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = r"C:\Users\6u6\Documents\Husk15\Husk-main\tests"
sys.path.insert(0, HERE)
import test_java_runtime_flow as T  # noqa: E402

REPO = os.path.dirname(HERE)
SCRIPT = os.path.join(REPO, "scripts", "build_java_runtime_ci.sh")

# the fix: clear before each attempt, and report the size instead of deleting
FIXED_BEFORE = """      rm -f "$WORK/$m.zip"
      if "$DEBUGFS" -R "dump $p $WORK/$m.zip" "$SYS_IMG" 2>/dev/null && [ -s "$WORK/$m.zip" ]; then"""
FIXED_AFTER = '''  echo "    $m <- $found ($(du -h "$WORK/$m.zip" | cut -f1))"'''

# what shipped: no rm before, and an rm after the successful dump
SHIPPED_BEFORE = '''      if "$DEBUGFS" -R "dump $p $WORK/$m.zip" "$SYS_IMG" 2>/dev/null && [ -s "$WORK/$m.zip" ]; then'''
SHIPPED_AFTER = '''  echo "    $m <- $found"
  rm -f "$WORK/$m.zip"'''

work = tempfile.mkdtemp()
fails = []
try:
    # 1. the real script passes
    r = T.main_quiet(os.path.join(work, "ok"))
    print("  current script -> %s" % ("pass" if r == 0 else "FAIL (%d)" % r))
    if r != 0:
        fails.append("the current script does not pass")

    # 2. revert it in a sandbox and confirm the test goes red
    sandbox_repo = os.path.join(work, "repo")
    shutil.copytree(REPO, sandbox_repo,
                    ignore=shutil.ignore_patterns(".git", "__pycache__", "build", "third_party"))
    target = os.path.join(sandbox_repo, "scripts", "build_java_runtime_ci.sh")
    s = open(target, encoding="utf-8").read()
    for old, new in ((FIXED_BEFORE, SHIPPED_BEFORE), (FIXED_AFTER, SHIPPED_AFTER)):
        if s.count(old) != 1:
            print("  MISS could not revert %r" % old[:40])
            fails.append("pattern drifted")
            raise SystemExit(1)
        s = s.replace(old, new)
    open(target, "w", encoding="utf-8", newline="").write(s)
    print("  reverted the rm -f placement in a temp copy")

    # 3. run the same test against the sandbox
    original_repo = T.REPO
    T.REPO = sandbox_repo
    try:
        r2 = T.main_quiet(os.path.join(work, "bad"))
    finally:
        T.REPO = original_repo
    print("  shipped script -> %s" % ("pass" if r2 == 0 else "FAIL (%d)" % r2))
    if r2 == 0:
        print("  FAIL the flow test passes against the script that shipped")
        fails.append("test does not catch the defect")
    else:
        print("  ok   the flow test goes red on the exact defect that shipped")
finally:
    shutil.rmtree(work, ignore_errors=True)

print("\n%d problem(s)" % len(fails))
sys.exit(1 if fails else 0)