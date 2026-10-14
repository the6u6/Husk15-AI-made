"""The CI API sweep, plus the patterns it was missing.

Same patterns and the same exclusions as the `sweep for APIs above the floor`
step in .github/workflows/build.yml, so that running this locally answers the
same question CI will. Run it from the repository root.
"""
import io
import os
import re
import sys

# The repository root is the parent of this file. It was `dirname(__file__)`
# first, which is tests/, and so src/app did not exist under it: `sources()`
# yielded nothing, both scans reported zero, and the check passed having read no
# code at all. The same shape as the hit-testing check that emptied itself when
# ContentView was split -- a check that reads nothing looks exactly like a check
# that finds nothing to complain about.
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "src", "app")

if not os.path.isdir(APP):
    print("no src/app under %s -- this check would read nothing and pass" % ROOT)
    sys.exit(1)

WORKFLOW = os.path.join(ROOT, ".github", "workflows", "build.yml")


def patterns_from_workflow():
    """The banned-API pattern, read out of the CI step rather than copied.

    The first version of this file held its own copy of the list, which is
    exactly the way the two drift apart: CI grew a pattern, this file did not,
    and the local run answered a question CI was no longer asking. Reading the
    same lines CI greps with means there is one list.

    Returns (pattern, excludes) -- the --exclude arguments are read too, because
    Compat14/Compat15 are where the shims live and a sweep that flagged them
    would be flagging the replacements for what it is looking for.
    """
    if not os.path.isfile(WORKFLOW):
        print("no %s -- this check cannot read CI's list" % WORKFLOW)
        sys.exit(1)
    text = io.open(WORKFLOW, encoding="utf-8").read()
    pieces, excludes = [], []
    for m in re.finditer(r"^\s*pat(?:\+?=)'([^']*)'\s*$", text, re.M):
        pieces.append(m.group(1))
    for m in re.finditer(r"--exclude=(\S+)", text):
        excludes.append(os.path.basename(m.group(1)))
    if not pieces:
        print("no pat= lines in the workflow -- the list moved or was renamed")
        sys.exit(1)
    # Concatenated with nothing between them, because every piece after the first
    # already carries its own leading "|". Joining with "|" as well put an empty
    # alternative between them, and an empty alternative matches at position 0 of
    # every string -- so the sweep matched all 15,000 lines in the tree and
    # reported every one of them. Join them wrongly again and this says so rather
    # than returning a number that looks like a result.
    pattern = "".join(pieces)
    if re.search(pattern, "") is not None:
        print("the list from build.yml matches the empty string -- an alternative is empty")
        sys.exit(1)
    return pattern, sorted(set(excludes))


CI, EXCLUDE_FILES = patterns_from_workflow()

COMPILED = re.compile(CI)


def sources():
    for dp, dn, fn in os.walk(APP):
        dn[:] = [d for d in dn if d not in (".git", "__pycache__")]
        for name in sorted(fn):
            if name.endswith(".swift"):
                yield os.path.join(dp, name)


def scan(pattern, exclude):
    hits = []
    for path in sources():
        if exclude and os.path.basename(path) in EXCLUDE_FILES:
            continue
        for n, line in enumerate(io.open(path, encoding="utf-8").read().split("\n"), 1):
            stripped = line.strip()
            if stripped.startswith("//"):
                continue
            if pattern.search(line):
                hits.append((os.path.relpath(path, ROOT).replace("\\", "/"), n, stripped[:100]))
    return hits


print("=== CI's list, read from build.yml (%d piece(s), excluding %s) ==="
      % (CI.count("|") + 1, ", ".join(EXCLUDE_FILES)))
a = scan(COMPILED, True)
print("  %d hit(s)" % len(a))
for p, n, l in a:
    print("  %s:%d  %s" % (p, n, l))

print("\n=== the shim files themselves (excluded above, read anyway) ===")
b = scan(COMPILED, False)
extra = [h for h in b if os.path.basename(h[0]) in EXCLUDE_FILES]
print("  %d hit(s)" % len(extra))
for p, n, l in extra:
    print("  %s:%d  %s" % (p, n, l))

print("\n=== bold/fontWeight, the CI check's second half ===")
# View.bold() and View.fontWeight(_:) are iOS 16; Font.bold() and
# Font.fontWeight(_:) are iOS 13. A line inside a .font( is the Font spelling.
bold = []
for path in sources():
    if os.path.basename(path) in EXCLUDE_FILES:
        continue
    for n, line in enumerate(io.open(path, encoding="utf-8").read().split("\n"), 1):
        s = line.strip()
        if s.startswith("//"):
            continue
        if re.search(r"\.bold\(\)|\.fontWeight\(", line) and ".font(" not in line:
            bold.append((os.path.relpath(path, ROOT).replace("\\", "/"), n, s[:100]))
print("  %d hit(s)" % len(bold))
for p, n, l in bold:
    print("  %s:%d  %s" % (p, n, l))

total = len(a) + len(bold)
print("\n%d above the floor" % total)
sys.exit(1 if total else 0)