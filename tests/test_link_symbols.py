"""Check that every C symbol Swift calls is actually *defined* somewhere the build compiles.

This is the check whose absence cost four CI rounds.

Three audits passed while the build failed at link:

  * every C function Swift calls is declared in a header          -- passed
  * the bridging header declares no removed VM symbol             -- passed
  * the bridge has no stale declarations                          -- passed

None of them asked the linker's question, which is not "is this declared" but
"does anything define this". Those two diverge exactly when a definition is
removed: the declaration stays, every call site still compiles, and the failure
arrives at the last step with a page of `Undefined symbols for architecture arm64`
and no file name. QemuAbsent.c held 33 such definitions; 7 of them were
`husk_ios_jit_*`, which the VM removal left declared and called while deleting
the file that defined them.

So: derive the compiled source list from project.yml rather than naming the
trees from memory, collect every definition, and require that the set of symbols
Swift calls is covered. The first version of this check hardcoded two
directories -- and so could not see src/app/Husk/JitAbsent.c, which is where the
answer was, and reported the eight symbols it had just defined as undefined.

Three kinds of name reach Swift from C, and confusing them is what produced the
false positives while getting this right:

  * a function        -- declared in a header, defined in a .c. Needs both.
  * a type            -- `typedef struct husk_tl_perf {...} husk_tl_perf;` imports
                         as a Swift struct, and `husk_tl_perf()` is its memberwise
                         initialiser, not a call to anything. Two symbols looked
                         undefined for this reason.
  * an imported object -- nothing in this repo; only relevant because the Rust
                         pairing library has no C source to walk. Taken from its
                         header, which is the contract, rather than a list.

The reverse direction is checked too: a definition nothing references is dead
code, which is what the other 26 symbols in QemuAbsent.c were. "Not called from
Swift" is not "dead" -- a C definition called from another C file, or handed out
as a callback, is used -- so the reference set includes C call sites.

Everything is checked against a synthetic fixture first, because a harness that
answers "no problems" when handed a symbol nothing defines is worse than no
harness at all. The first run of this file failed six of its own fixture checks,
which is the reason to believe the ones that pass mean something.
"""
import io
import os
import re
import shutil
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, os.pardir))
PROJECT_YML = os.path.join(REPO, "src", "app", "project.yml")
RPPAIRING_H = os.path.join(REPO, "src", "app", "Husk", "HuskRPPairing.h")
HUSK_DIR = os.path.join(REPO, "src", "app", "Husk")
SRC_SUFFIXES = (".c", ".m", ".mm", ".cpp")
HDR_SUFFIXES = (".h", ".hpp")

fails = []


def check(label, cond, detail=""):
    print("  %s %s%s" % ("ok  " if cond else "FAIL", label,
                        ("\n         " + detail) if detail and not cond else ""))
    if not cond:
        fails.append(label)


# ---- 1. the source list comes from project.yml, not from a list I remembered ---
#
# project.yml is YAML but PyYAML is not guaranteed on the box that runs this
# (build_gpu_ios.sh goes to some length over exactly that), so the block is read
# by indentation: the `sources:` key of the Husk target, then the `- path:` items
# under it, stopping when the indentation comes back out.
def source_roots():
    roots, in_target, in_sources = [], False, False
    target_indent = sources_indent = 0
    for line in io.open(PROJECT_YML, encoding="utf-8").read().split("\n"):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())

        if not in_target:
            m = re.match(r"^(\s+)(\w+):\s*$", line)
            if m and m.group(2) == "Husk":
                in_target, target_indent = True, len(m.group(1))
            continue

        if not in_sources:
            if re.match(r"^\s*sources:\s*$", line):
                in_sources, sources_indent = True, indent
            elif indent <= target_indent:
                break
            continue

        m = re.match(r"^\s*-\s+path:\s*(\S+)\s*$", line)
        if m:
            roots.append(os.path.normpath(os.path.join(REPO, "src", "app", m.group(1))))
        elif indent <= sources_indent and not line.strip().startswith("-"):
            in_sources = False  # the list ended; `settings:` or similar follows
    return roots


ROOTS = source_roots()


def strip_noise(text):
    """Remove comments and replace string/char literals, so their contents cannot
    be read as code. A name inside a comment or a quoted message is not a symbol."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        two = text[i:i + 2]
        if two == "//":
            while i < n and text[i] != "\n":
                i += 1
        elif two == "/*":
            i += 2
            while i + 1 < n and text[i:i + 2] != "*/":
                i += 1
            i += 2
            out.append("\n")
        elif c in "\"'":
            q, i = c, i + 1
            while i < n and text[i] != q:
                i += 2 if text[i] == "\\" else 1
            i += 1
            out.append('""')
        else:
            out.append(c)
            i += 1
    return "".join(out)


# A signature is: modifiers, return type, the husk_ name, an argument list, then
# either `{` (a definition) or `;` (a declaration). Walking to the terminator
# rather than assuming the signature fits on one line is what lets a multi-line
# definition be seen. An earlier regex used \s inside a character class -- which
# includes a newline -- and so matched across two functions and reported two
# symbols as undefined when both were defined.
SIGNATURE = re.compile(r"(?:^|[\n{};])\s*((?:[A-Za-z_][\w]*\s+|\*|\s)*?)\b(husk_\w+)\s*\(")
# `typedef struct husk_tl_perf { ... } husk_tl_perf;` -- the trailing name is the
# type's own name, and only that one introduces a name into Swift.
TYPEDEF = re.compile(r"typedef\b[^;{}]*\b(husk_\w+)\s*(?:\[[^\]]*\])?\s*;", re.S)
TYPEDEF_STRUCT = re.compile(r"\}\s*(husk_\w+)\s*;", re.S)
CALLSITE = re.compile(r"(?<![\w.])(husk_\w+)\s*\(")


def signatures(body):
    """Yield (name, is_static, terminator, start) for every husk_ signature in `body`."""
    for m in SIGNATURE.finditer(body):
        mods = m.group(1)
        # m.end() is just past the signature's own '(', so depth is already 1. The
        # walk must continue *past* the closing paren rather than stopping on it
        # -- looping `while depth > 0` ends at the ')' and never sees the '{' or
        # ';' that distinguishes a definition from a declaration.
        i, depth, term = m.end(), 1, None
        while i < len(body):
            c = body[i]
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            elif depth == 0 and c in ";{":
                term = c
                break
            i += 1
        yield m.group(2), "static" in mods.split(), term, m.start(2)


WORD = re.compile(r"\bhusk_\w+\b")


def appearances(bodies):
    """How many times each husk_ name occurs, across everything the build reads.

    Counting occurrences rather than trying to classify each one is what makes
    "dead" a safe question. Deciding per-occurrence whether a name is a definition
    or a call does not work: a call preceded by `{` is lexically identical to a
    definition, and comparing match offsets between two different regexes failed
    because SIGNATURE starts at the newline in front of a signature while CALLSITE
    starts at the name. A name's own definition is exactly one occurrence, so
    anything appearing more than once is referenced by something.

    Whole words, not callsites, because a function handed out as a callback --
    `handlers = husk_cocos_key_down;` -- is a reference with no parenthesis, and a
    check that only saw calls would call it dead."""
    counts = {}
    for body in bodies:
        for m in WORD.finditer(body):
            counts[m.group(0)] = counts.get(m.group(0), 0) + 1
    return counts


def c_files(roots, suffixes):
    out = []
    for root in roots:
        if os.path.isfile(root):
            out.append(root)
        elif os.path.isdir(root):
            for dirpath, dirnames, filenames in os.walk(root):
                dirnames[:] = [d for d in dirnames if d not in (".git", "build", "Resources")]
                out += [os.path.join(dirpath, f) for f in filenames if f.endswith(suffixes)]
    return out


def definitions(paths):
    defined = set()
    for path in paths:
        body = strip_noise(io.open(path, encoding="utf-8", errors="replace").read())
        for name, is_static, term, _start in signatures(body):
            if term == "{" and not is_static:
                defined.add(name)
    return defined


def declarations(paths):
    """Every husk_ name a header introduces: a function declaration, or a typedef
    naming a type. Headers are read regardless of whether the target compiles
    them -- a header that is excluded from the build still documents the ABI, and
    husk-tl-unity-app.h is one project.yml excludes and so a .c-only scan missed
    thirteen declarations."""
    declared, types = set(), set()
    for path in paths:
        body = strip_noise(io.open(path, encoding="utf-8", errors="replace").read())
        for name, is_static, term, _start in signatures(body):
            if term == ";" and not is_static:
                declared.add(name)
        for m in TYPEDEF.finditer(body):
            types.add(m.group(1))
        # the name a struct typedef introduces is the one after the closing brace
        for m in TYPEDEF_STRUCT.finditer(body):
            if re.search(r"typedef\b[^;{}]*\bstruct\b[^;{}]*\{", body[:m.start()]):
                types.add(m.group(1))
    return declared, types


def swift_calls():
    """Every husk_ identifier Swift calls, with the files that call it. Whole-line
    comments are dropped so a commented call site is not read as a missing
    definition -- a distinction worth making explicitly rather than assuming."""
    called = {}
    for fn in sorted(os.listdir(HUSK_DIR)):
        if not fn.endswith(".swift"):
            continue
        code = "\n".join(l for l in io.open(os.path.join(HUSK_DIR, fn), encoding="utf-8",
                                           errors="replace").read().split("\n")
                         if not l.strip().startswith("//"))
        for m in CALLSITE.finditer(code):
            called.setdefault(m.group(1), set()).add(fn)
    return called


# ---- 2. the fixture, so that "no problems" is known to mean something -----------
print("=== the fixture: does this check bite at all? ===")
FX = os.path.join(REPO, "tests", ".link-symbols-fixture")
os.makedirs(FX, exist_ok=True)
try:
    io.open(os.path.join(FX, "a.c"), "w").write(
        "/* husk_commented() is only in a comment and must not be seen. */\n"
        "const char *husk_quoted(void) { return \"husk_quoted_text()\"; }\n"
        "int husk_defined_one(void) { return 1; }\n"
        "static int husk_private(void) { return 2; }\n"
        "int husk_defined_two(\n"
        "    int a,\n"
        "    int b) { return a + b; }\n"
        "int husk_declared_only(void);\n"
        "void husk_fixture_caller(void) { husk_defined_one(); husk_defined_two(1, 2); }\n")
    io.open(os.path.join(FX, "b.h"), "w").write(
        "int husk_declared_only(void);\n"
        "void husk_fixture_caller(void);\n"
        "typedef struct husk_fixture_type {\n"
        "    double fps;\n"
        "} husk_fixture_type;\n")

    fx_defined = definitions([os.path.join(FX, "a.c")])
    fx_declared, fx_types = declarations([os.path.join(FX, "b.h")])
    fx_called = {"husk_defined_one", "husk_defined_two", "husk_declared_only",
                 "husk_private", "husk_absent", "husk_fixture_type"}

    check("sees a definition", "husk_defined_one" in fx_defined)
    check("sees a definition split over several lines", "husk_defined_two" in fx_defined)
    check("sees a declaration", "husk_declared_only" in fx_declared)
    check("ignores a name that appears only in a comment",
          "husk_commented" not in fx_defined | fx_declared)
    check("ignores a name that appears only inside a string literal",
          "husk_quoted_text" not in fx_defined | fx_declared)
    check("a static definition is not exported", "husk_private" not in fx_defined)
    check("sees the type a struct typedef introduces", "husk_fixture_type" in fx_types)

    # The check's actual verdict over the fixture. All three kinds of miss are
    # named, because all three have happened here: absent outright, declared but
    # never defined (which is exactly the husk_ios_jit_* case -- the declaration
    # survived the removal and the definition did not), and private.
    unresolved = sorted(s for s in fx_called
                        if s not in fx_defined and s not in fx_types)
    check("it names all three kinds of miss",
          unresolved == ["husk_absent", "husk_declared_only", "husk_private"],
          "reported %s" % unresolved)

    # Dead means the name occurs nowhere but its own definition. Counting
    # occurrences is what makes the question answerable: "not called from Swift"
    # is not "dead" -- the first version reported thirteen live definitions as dead
    # for exactly that reason. Bodies are stripped first, so a name in a comment or
    # a quoted message is not a reference.
    fx_seen = appearances([strip_noise(io.open(os.path.join(FX, "a.c"), encoding="utf-8").read()),
                           strip_noise(io.open(os.path.join(FX, "b.h"), encoding="utf-8").read())])
    dead = sorted(s for s in fx_defined
                  if s not in fx_declared and fx_seen.get(s, 0) <= 1)
    check("a definition nothing references is dead, and one with a C caller is not",
          dead == ["husk_quoted"], "reported %s" % dead)
    check("a definition that a C file calls is not dead",
          "husk_defined_one" not in dead and "husk_defined_two" not in dead,
          "reported %s" % dead)
    check("a definition a header declares is not dead, even with no caller",
          "husk_fixture_caller" not in dead, "reported %s" % dead)
    check("a definition is not counted as a reference to itself",
          fx_seen.get("husk_defined_one", 0) > 1, "seen: %s" % sorted(fx_seen))
    check("a name in a comment or a string is not a reference",
          "husk_commented" not in fx_seen and "husk_quoted_text" not in fx_seen,
          "seen: %s" % sorted(fx_seen))
finally:
    shutil.rmtree(FX, ignore_errors=True)

# ---- 3. the real source list ---------------------------------------------------
print("\n=== source roots, derived from project.yml ===")
for r in ROOTS:
    kind = "file" if os.path.isfile(r) else ("dir" if os.path.isdir(r) else "MISSING")
    print("    %-44s %s" % (os.path.relpath(r, REPO), kind))
check("project.yml yielded a source list", len(ROOTS) >= 4, "found %d" % len(ROOTS))
check("every root in project.yml exists", all(os.path.exists(r) for r in ROOTS),
      "missing: %s" % [os.path.relpath(r, REPO) for r in ROOTS if not os.path.exists(r)])
check("src/app/Husk is among them, which is where the answer was last time",
      os.path.normpath(HUSK_DIR) in ROOTS)

compiled_c = c_files(ROOTS, SRC_SUFFIXES)
all_headers = []
for dirpath, dirnames, filenames in os.walk(REPO):
    dirnames[:] = [d for d in dirnames if d not in (".git", "build", "Resources")]
    all_headers += [os.path.join(dirpath, f) for f in filenames if f.endswith(HDR_SUFFIXES)]

rp_text = io.open(RPPAIRING_H, encoding="utf-8").read()
rp_symbols = set(CALLSITE.findall(rp_text))
check("the pairing header exists and declares symbols", len(rp_symbols) > 0)
print("    %d compiled C file(s), %d header(s); %d pairing symbol(s) come from the\n"
      "    Rust library and have no C source to walk" % (len(compiled_c), len(all_headers),
                                                         len(rp_symbols)))

defined = definitions(compiled_c)
declared, types = declarations(all_headers)
called = swift_calls()

# ---- 4. the link-time verdict ---------------------------------------------------
print("\n=== called from Swift: %d distinct names ===" % len(called))
print("=== defined in the compiled sources: %d;  declared: %d;  types: %d ==="
      % (len(defined), len(declared), len(types)))

IMPORTED = rp_symbols
unresolved = sorted(s for s in called if s not in defined and s not in IMPORTED
                    and s not in types)
print("\n  called from Swift, but neither a defined function nor an imported type: %d"
      % len(unresolved))
for s in unresolved:
    print("      %-36s %s" % (s, ", ".join(sorted(called[s]))))
check("every name Swift calls is a definition, an imported type, or the Rust library",
      not unresolved, "unresolved: %s" % unresolved)

# Nothing calls husk_ios_available_memory, so it is not a link error on its own --
# a declaration with no definition links fine until someone calls it. It is still
# the shape this check exists for, and the bridging header is where the eight
# names live, so the header is checked as its own contract: every name it
# declares must be a definition or an imported type.
bridge_declared, _ = declarations([os.path.join(HUSK_DIR, "HuskBridge.h")])
bridge_undefined = sorted(s for s in bridge_declared
                          if s not in defined and s not in IMPORTED and s not in types)
print("\n  declared by the bridging header but defined nowhere: %d" % len(bridge_undefined))
for s in bridge_undefined:
    print("      %s" % s)
check("every symbol the bridging header declares has a definition",
      not bridge_undefined, "declared but undefined: %s" % bridge_undefined)

# A definition referenced by nothing is dead code, which is what the other 26
# symbols in QemuAbsent.c were. A definition is referenced by its own declaration,
# by a Swift call site, or by appearing anywhere else in the C -- including as a
# bare callback, which has no parenthesis to match on.
seen = appearances([strip_noise(io.open(p, encoding="utf-8", errors="replace").read())
                    for p in compiled_c + all_headers])
dead = sorted(s for s in defined
              if s not in declared and s not in called and seen.get(s, 0) <= 1)
print("\n  defined but referenced by nothing (dead): %d" % len(dead))
for s in dead:
    print("      %s" % s)
check("no dead definitions", not dead, "dead: %s" % dead)

# A name Swift calls but which is defined only *outside* the app target still links
# today by accident of the build configuration, and stops the day someone prunes a
# path list. Named rather than quietly tolerated.
inside = {os.path.normpath(p) for p in compiled_c}
strays = sorted(p for p in c_files([REPO], SRC_SUFFIXES) if os.path.normpath(p) not in inside)
outside = definitions(strays)
orphans = sorted(s for s in unresolved if s in outside)
print("\n  C sources outside the app target: %d file(s), defining %d symbol(s)"
      % (len(strays), len(outside)))
for s in orphans:
    print("      %s" % s)
check("nothing Swift calls is defined only outside the app target", not orphans,
      "orphans: %s" % orphans)

print("\n%d failed" % len(fails))
sys.exit(1 if fails else 0)