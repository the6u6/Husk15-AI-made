r"""Every Info.plist and storyboard must parse, and a double hyphen inside an XML
comment is the specific way this goes wrong.

Adding the launch storyboard for the iOS 13 floor broke two files in a row with
the same mistake: a comment written the way commit messages are written, with
`--` for an em dash. A double hyphen is not legal inside an XML comment. The
failure is `not well-formed (invalid token): line 103, column 19` with nothing
in it resembling the cause, and the build stops.

So this checks two things:

  * every plist and storyboard in the tree parses
  * no XML comment in any of them contains `--` inside its text

The second is the one that would have caught it *before* the first run rather
than after, and it is here because the general form of this failure -- a file
that is valid-looking and does not parse -- is invisible to every other check in
the repo. Bracket balance counts brackets; a comment with a double hyphen in it
has balanced brackets.
"""
import io
import os
import plistlib
import re
import sys
import xml.dom.minidom

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

REPO = r"C:\Users\6u6\Documents\Husk15\Husk-main"
SRC = os.path.join(REPO, "src", "app")

fails = []


def check(label, cond, detail=""):
    print("  %s %s%s" % ("ok  " if cond else "FAIL", label,
                        ("\n         " + detail) if detail and not cond else ""))
    if not cond:
        fails.append(label)


def targets():
    out = []
    for dirpath, dirnames, filenames in os.walk(SRC):
        for f in sorted(filenames):
            if f.endswith(".plist") or f.endswith(".storyboard") or f.endswith(".xib"):
                out.append(os.path.join(dirpath, f))
    return sorted(out)


# ---- 1. they parse ------------------------------------------------------------
print("=== every plist and storyboard parses ===")
files = targets()
for p in files:
    rel = os.path.relpath(p, REPO)
    try:
        if p.endswith(".plist"):
            plistlib.load(open(p, "rb"))
        else:
            xml.dom.minidom.parse(p)
        print("  ok   %s" % rel)
    except Exception as e:
        print("  FAIL %s\n         %s: %s" % (rel, type(e).__name__, e))
        fails.append(rel)
print("  %d file(s)" % len(files))

# ---- 2. no double hyphen inside an XML comment --------------------------------
# Both of those files were "obviously fine" to a reader and to every other check.
print("\n=== no double hyphen inside an XML comment ===")
COMMENT = re.compile(r"<!--(.*?)-->", re.S)
for p in files:
    text = io.open(p, encoding="utf-8", errors="replace").read()
    for i, m in enumerate(COMMENT.finditer(text)):
        inner = m.group(1)
        if "--" in inner:
            line = text[:m.start()].count("\n") + 1
            print("  FAIL %s:%d  '--' is not legal inside an XML comment"
                  % (os.path.relpath(p, REPO), line))
            print("         %s" % inner.strip()[:88])
            fails.append("%s:%d" % (os.path.relpath(p, REPO), line))
print("  (none found)" if not any(f.startswith(os.path.relpath(x, REPO)) for f in fails
                                  for x in files if "--" in
                                  " ".join(COMMENT.findall(
                                      io.open(x, encoding="utf-8", errors="replace").read())))
      else "")

# ---- 3. the iOS 13 full-screen contract, which is why any of this exists ------
print("\n=== the app can still take the whole screen on iOS 13 ===")
plist = plistlib.load(open(os.path.join(SRC, "Husk", "Info.plist"), "rb"))
check("UILaunchStoryboardName is set -- UILaunchScreen is 14+, and iOS 13 has no",
      bool(plist.get("UILaunchStoryboardName")), "13 cannot see a launch screen")
check("the storyboard it names exists",
      os.path.isfile(os.path.join(SRC, "Husk",
                                 str(plist.get("UILaunchStoryboardName", "")) + ".storyboard")))
check("UILaunchScreen is still there for 14 and later",
      "UILaunchScreen" in plist)
check("UIRequiresFullScreen is true",
      plist.get("UIRequiresFullScreen") is True,
      "with it false, iPadOS may put the app in both halves of a Split View")

print("\n%d failed" % len(fails))
sys.exit(1 if fails else 0)