"""Check that every layer above the tab UI declares its hit-testing policy.

The app was inert once: the tab bar drew, every screen drew, and nothing
responded -- not a tab, not a button, not a scroll. Nothing in the Swift was
obviously wrong. The cause was a full-screen `GeometryReader` in ContentView's
root ZStack, on top of the TabView, with no `.allowsHitTesting`.

A view that occupies the screen and draws nothing still absorbs the touches
meant for whatever is beneath it. That is a property of how SwiftUI hit-tests,
not something a read of the code suggests, so nothing short of running it shows
it. Upstream knew: it wrote `.allowsHitTesting(showGuestScreen)` on
`AppWindowLayer` and the same idiom on `GuestScreenView`. Removing QEMU removed
`showGuestScreen`, and the modifier that named it went with it -- silently,
because the line it guarded was still perfectly valid Swift.

So this is a check about a construct, not a list. It reads ContentView's root
ZStack, finds the siblings that sit above the TabView, and requires each to say
what its hit-testing policy is. A new overlay layer added tomorrow has to state
one; that is the point.

The two ways to satisfy it are both legitimate and neither is a loophole:

  * `.allowsHitTesting(...)` somewhere on the layer's chain -- it says so.
  * the layer declares the policy itself and ContentView says so in a comment --
    AppWindowLayer does this, because the thing that needs the guard is its
    GeometryReader and putting it there means no call site can lose it again.

That second route is why this is not simply "grep for allowsHitTesting": the
right place for the guard moved away from where this check looks for it, and a
check that could not express that would have pushed it back to the fragile spot.

Derived from the file rather than written out by hand, and checked against a
synthetic ZStack first, because a guard against a missing modifier that has
never seen a missing modifier is not a guard.
"""
import io
import os
import re
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

REPO = r"C:\Users\6u6\Documents\Husk15\Husk-main"
CONTENT_VIEW = os.path.join(REPO, "src", "app", "Husk", "ContentView.swift")

fails = []


def check(label, cond, detail=""):
    print("  %s %s%s" % ("ok  " if cond else "FAIL", label,
                        ("\n         " + detail) if detail and not cond else ""))
    if not cond:
        fails.append(label)


def is_comment(line):
    s = line.strip()
    return s.startswith("//") or s.startswith("/*") or s.startswith("*")


def root_zstack(lines):
    """The body of ContentView's root ZStack: its top-level children, in order.

    Found by structure -- the ZStack that follows `var body: some View` at the
    shallowest indent in the file -- rather than by matching a literal, so
    reformatting the file does not empty this out silently. If it cannot find
    one that is itself a failure, not a pass.

    Comments are ignored for *structure* and kept in each child's text. Stripping
    them outright was the first version, and it removed the one thing this check
    reads: a layer that declares its policy in the type and points at it from
    here is saying so in a comment. Stripped, the real AppWindowLayer looked
    like it had no policy when it had one two lines up.

    The child indent comes from the shallowest non-comment line inside the braces,
    not from the `var body` indent: a ZStack nested one level down still indents
    its children four further, and the first version computed it as
    body + len("ZStack {"), which matched nothing and reported "no root ZStack"
    on a file that has one."""
    anchor = None
    for i, l in enumerate(lines):
        if is_comment(l):
            continue
        m = re.match(r"^(\s*)var body: some View \{\s*$", l)
        if not m:
            continue
        anchor = i
        for j in range(i + 1, min(i + 12, len(lines))):
            if not is_comment(lines[j]) and re.match(r"^\s+ZStack \{\s*$", lines[j]):
                return (i, j), zstack_children(lines, j)
        break
    return (anchor, None), []


def zstack_children(lines, zs):
    zs_indent = len(lines[zs]) - len(lines[zs].lstrip())
    body = []
    for l in lines[zs + 1:]:
        if l.strip() and not is_comment(l) and (len(l) - len(l.lstrip())) <= zs_indent:
            break
        body.append(l)
    indents = [len(l) - len(l.lstrip()) for l in body if l.strip() and not is_comment(l)]
    if not indents:
        return []
    child = min(indents)
    children, cur, depth = [], [], 0
    for l in body:
        indent = len(l) - len(l.lstrip())
        starts = (indent == child and depth == 0 and l.strip() and not is_comment(l))
        if starts:
            if cur:
                children.append("\n".join(cur))
            cur = [l]
        elif cur:
            cur.append(l)
        if not is_comment(l):
            depth += l.count("{") - l.count("}")
    if cur:
        children.append("\n".join(cur))
    return children


SWIFT_SOURCES = []
for _fn in sorted(os.listdir(os.path.join(REPO, "src", "app", "Husk"))):
    if _fn.endswith(".swift"):
        SWIFT_SOURCES.append((_fn, io.open(os.path.join(REPO, "src", "app", "Husk", _fn),
                                           encoding="utf-8").read()))


def type_body(name, sources=None):
    """The source of one type declaration, braces balanced.

    Searched across every Swift file rather than indexed by file name: the type
    is named after what it is, not after the file it happens to live in, and a
    lookup keyed on the file name silently found nothing -- which reads as "no
    policy declared" for a type whose policy is two lines inside its body.

    `sources` overrides the corpus, so a fixture can use a type that exists only
    in the fixture. The first version named the real AppWindowLayer in its "no
    policy" case, and the case went green the moment the real type was given the
    guard -- a fixture that reads the code it is testing stops testing it."""
    for _fn, src in (sources if sources is not None else SWIFT_SOURCES):
        pat = re.compile(r"^(?:public |internal |private |fileprivate )?"
                         r"(?:final )?(?:struct|class|enum|extension)\s+%s\b"
                         % re.escape(name), re.M)
        m = pat.search(src)
        if not m:
            continue
        depth = 0
        for i in range(m.start(), len(src)):
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
                if depth == 0:
                    return src[m.start():i + 1]
        return src[m.start():]
    return None


def subject_of(child):
    """The type a layer is made of: AppWindowLayer() -> AppWindowLayer."""
    for l in child.split("\n"):
        m = re.match(r"^[A-Z]\w*\(\)", l.strip())
        if m:
            return l.strip()[:-2]
    return None


def declared_policy(child, sources=None):
    """How this layer says what its hit-testing policy is, if it says at all.

    Two legitimate routes, and both are read from code rather than from prose.
    The first version tried to match the comment explaining a policy declared
    inside a type, and phrases like "lives here" are not a contract -- they are
    how one sentence happened to be written, and the check would have been right
    for the wrong reason on the day and wrong for the right reason after a
    reword. Looking in the type's own body cannot drift that way.
    """
    if ".allowsHitTesting(" in child:
        return "at the call site"
    name = subject_of(child)
    body = type_body(name, sources) if name else None
    if body and ".allowsHitTesting(" in body:
        return "inside %s" % name
    return None


def layers_above_tab(children):
    tab = next((i for i, c in enumerate(children) if "TabView(" in c), None)
    return children[tab + 1:] if tab is not None else []


# ---- 1. the fixture: does this catch a layer with no policy? --------------------
print("=== the fixture ===")

GOOD = """
    var body: some View {
        ZStack {
            TabView(selection: $router.tab) {
                HomeView()
            }
            // Christmas: snow over the tabs.
            if holiday {
                Snowfall()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            // Multitasking. The guard is inside AlphaLayer, on its GeometryReader.
            AlphaLayer()
                .ignoresSafeArea(.keyboard)
        }
    }
"""

BAD = """
    var body: some View {
        ZStack {
            TabView(selection: $router.tab) {
                HomeView()
            }
            if holiday {
                Snowfall()
                    .ignoresSafeArea()
            }
            BetaLayer()
                .ignoresSafeArea(.keyboard)
        }
    }
"""

# Two types that exist only here, so the fixture cannot pass or fail because of
# what the real code happens to say today.
SYNTH = [
    ("Synthetic.swift",
     "struct AlphaLayer: View {\n"
     "    var body: some View {\n"
     "        GeometryReader { _ in EmptyView() }\n"
     "            .allowsHitTesting(app != nil)\n"
     "    }\n"
     "}\n"),
    ("Synthetic.swift",
     "struct BetaLayer: View {\n"
     "    var body: some View { GeometryReader { _ in EmptyView() } }\n"
     "}\n"),
]

for label, src, want_flagged in (("both layers say so", GOOD, 0),
                                 ("neither layer says so", BAD, 2)):
    _anchor, kids = root_zstack(src.split("\n"))
    flagged = [subject_of(k) or k.split("\n")[0].strip()
               for k in layers_above_tab(kids)
               if declared_policy(k, SYNTH) is None]
    check("%s: %d layer(s) flagged as needing a policy" % (label, want_flagged),
          len(flagged) == want_flagged,
          "flagged %s" % flagged)
check("the fixture finds all three children in the good case",
      len(root_zstack(GOOD.split("\n"))[1]) == 3,
      "children: %s" % [k.split("\n")[0].strip() for k in root_zstack(GOOD.split("\n"))[1]])
check("a policy set in code counts, at the call site",
      declared_policy("Snowfall()\n  .allowsHitTesting(false)\n") == "at the call site")
check("a policy set inside the type counts, read from the type's own body",
      declared_policy("AlphaLayer()\n", SYNTH) == "inside AlphaLayer")
check("a layer whose type says nothing is flagged",
      declared_policy("BetaLayer()\n", SYNTH) is None)

# ---- 2. the real root -----------------------------------------------------------
print("\n=== ContentView's root ZStack ===")
lines = io.open(CONTENT_VIEW, encoding="utf-8").read().split("\n")
anchor, children = root_zstack(lines)
check("found the root ZStack", anchor is not None,
      "no 'var body: some View' followed by a ZStack at the same indent")

if anchor:
    _tab, kids = root_zstack(lines)
    check("found the TabView among the ZStack's children",
          any("TabView(" in c for c in kids))
    above = layers_above_tab(kids)
    print("  %d layer(s) above the TabView:" % len(above))
    flagged = []
    for c in above:
        name = subject_of(c) or c.strip().split("\n")[0]
        how = declared_policy(c)
        print("      %-24s %s" % (name, how or "NO POLICY"))
        if how is None:
            flagged.append(name)
    check("every layer above the TabView declares its hit-testing policy",
          not flagged,
          "no policy declared: %s -- a full-screen layer that draws nothing "
          "absorbs every touch under it" % flagged)

print("\n%d failed" % len(fails))
sys.exit(1 if fails else 0)