"""Prove the fixed fixture catches the bug it was written for.

A fixture that encodes a field the way the code under test reads it tests
nothing. So: take the real script, revert entry_name() to the ASCII read that
actually shipped, and confirm the test goes red. If it still passes, the fixture
is still agreeing with the parser and proves nothing.

Nothing is written back -- the script is patched in a temp copy only.
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

REPO = r"C:\Users\6u6\Documents\Husk15\Husk-main"
TEST = os.path.join(REPO, "tests", "test_gpt_extract.py")

FIXED = "        return e[56:128].decode('utf-16-le', 'ignore').split('\\x00')[0]"
SHIPPED = "        return e[56:128].split(b'\\x00')[0].decode()"

work = tempfile.mkdtemp()
try:
    shutil.copytree(REPO, os.path.join(work, "repo"),
                    ignore=shutil.ignore_patterns(".git", "__pycache__", "build", "third_party"))
    sandbox = os.path.join(work, "repo")

    r = subprocess.run([sys.executable, TEST], capture_output=True)
    tail = r.stdout.decode().strip().splitlines()[-1] if r.stdout else ""
    print("  fixed parser    -> exit %d  %s" % (r.returncode, tail))
    if r.returncode != 0:
        raise SystemExit("  the fixed parser does not pass; fix that first")

    target = os.path.join(sandbox, "scripts", "build_java_runtime_ci.sh")
    s = open(target, encoding="utf-8").read()
    if FIXED not in s:
        raise SystemExit("  could not find entry_name() to revert; pattern drifted")
    open(target, "w", encoding="utf-8", newline="").write(s.replace(FIXED, SHIPPED))

    r = subprocess.run([sys.executable, os.path.join(sandbox, "tests", "test_gpt_extract.py")],
                       capture_output=True)
    out = (r.stdout + r.stderr).decode("utf-8", "replace").strip()
    last = out.splitlines()[-1] if out else ""
    print("  shipped parser  -> exit %d  %s" % (r.returncode, last[:88]))

    if r.returncode == 0:
        print("  FAIL  the fixture passes with an ASCII parser: it proves nothing")
        raise SystemExit(1)
    print("  ok   the fixture rejects the exact parser that shipped")
finally:
    shutil.rmtree(work, ignore_errors=True)