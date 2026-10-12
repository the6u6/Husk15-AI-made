r"""A Swift file must have balanced parentheses outside strings and comments.

This exists because a regex rewrite ate the inside of four string literals in
one pass and left two of them unterminated. The damage was invisible to every
check that was already here:

  * the brace counter in check_consistent.py counts braces and ignores
    strings -- correctly, because a brace inside a string is not a brace. So a
    line whose string literal had been eaten mid-way still balanced.
  * the caller of the rewrite counted its own matches before and after, and it
    had done exactly what it said: fifteen sites in, fifteen sites out.
  * the navigationBarItems pass counted parentheses without noticing that one of
    them was inside "Repositories", and inserted `leading: AnyView(EmptyView())`
    in the middle of the word.

What caught it was the compiler, four errors deep, and it said "unterminated
string literal" rather than "something you rewrote was wrong".

So this counts parentheses and brackets the same way a Swift lexer would: strings
and comments are removed first, and then every bracket has to balance. It is
stricter than the brace counter -- brackets were never checked at all -- and it
runs over all 57 files recursively, which is the third time a walk here has had
to be widened after finding something the narrow one missed.
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
HUSK = os.path.join(REPO, "src", "app", "Husk")


def lex(text):
    """Remove comments and string literals, leaving code and its brackets.

    Done as a scan rather than as a regex, because that is the entire point: the
    regexes are what lost the text. Triple-quoted strings are handled because
    several files use them for multi-line reports.
    """
    out, i, n = [], 0, len(text)
    while i < n:
        two = text[i:i + 2]
        if two == "//":
            while i < n and text[i] != "\n":
                i += 1
        elif two == "/*":
            depth, i = 1, i + 2
            while i < n and depth:
                if text[i:i + 2] == "/*":
                    depth += 1
                    i += 2
                elif text[i:i + 2] == "*/":
                    depth -= 1
                    i += 2
                else:
                    i += 1
            out.append(" ")
        elif text[i:i + 3] == '"""':
            end = text.find('"""', i + 3)
            out.append('""')
            i = (end + 3) if end >= 0 else n
        elif text[i] == '"':
            i += 1
            while i < n and text[i] != '"':
                # a backslash escape inside the literal
                i += 2 if text[i] == "\\" else 1
            if i < n and text[i] == '"':
                i += 1
            elif i >= n:
                return None, "unterminated string literal"
            out.append('""')
        else:
            out.append(text[i])
            i += 1
    return "".join(out), None


PAIRS = {"(": ")", "[": "]", "{": "}"}


def check_file(path):
    """(errors) for one file: every unbalanced bracket, with its line."""
    raw = io.open(path, encoding="utf-8", errors="replace").read()
    code, bad = lex(raw)
    if bad:
        return [("whole file", bad)]
    stack, errors = [], []
    line = 1
    for ch in code:
        if ch == "\n":
            line += 1
        elif ch in PAIRS:
            stack.append((ch, line))
        elif ch in PAIRS.values():
            if not stack:
                errors.append((line, "a closing %s with nothing open" % ch))
            elif PAIRS[stack[-1][0]] != ch:
                errors.append((line, "a closing %s closing a %s from line %d"
                               % (ch, stack[-1][0], stack[-1][1])))
                stack.pop()
            else:
                stack.pop()
    for opener, where in stack:
        errors.append((where, "a %s that is never closed" % opener))
    return errors


def main():
    files = []
    for dirpath, _dn, fns in os.walk(HUSK):
        files += [os.path.join(dirpath, f) for f in fns if f.endswith(".swift")]
    files.sort()
    print("=== %d Swift files (recursive) ===" % len(files))

    total = 0
    for p in files:
        for line, msg in check_file(p):
            print("  FAIL %s:%d  %s" % (os.path.relpath(p, HUSK), line, msg))
            total += 1

    print("\n=== the detector itself, on files it must get right ===")
    # The literal whose quote is never closed. A lexer must notice, not carry on
    # counting brackets as if it were code -- which is the failure that let a
    # rewrite eat four string literals without any check objecting.
    unterminated = os.path.join(os.environ["TEMP"], "husk_bracket_unterminated.swift")
    io.open(unterminated, "w", encoding="utf-8").write(
        'let a = f("text ( unbalanced\n')
    errs = check_file(unterminated)
    print("  %s an unterminated literal is reported as one"
          % ("ok  " if errs == [("whole file", "unterminated string literal")] else "FAIL"))

    # Brackets inside literals must not count; one real imbalance must be caught.
    mixed = os.path.join(os.environ["TEMP"], "husk_bracket_mixed.swift")
    io.open(mixed, "w", encoding="utf-8").write(
        'let a = "text ( unbalanced"\n'
        'let b = "a } b"\n'
        "let c = \"it's\"\n"
        'let d = f(g(1, 2)\n'          # the real imbalance
        "let e = [1, 2]\n")
    errs = check_file(mixed)
    # The line is an integer 4, not the text "line 4" -- asserting on the
    # rendering rather than the value is the sort of thing that makes a check
    # green for the wrong reason.
    only_the_real_one = len(errs) == 1 and errs[0][0] == 4
    print("  %s brackets inside string literals are ignored"
          % ("ok  " if only_the_real_one else "FAIL"))
    print("  %s it reports exactly the one real imbalance: %s"
          % ("ok  " if only_the_real_one else "FAIL", errs))
    if not only_the_real_one:
        total += 1

    print("\n  %d problem(s)" % total)
    return 1 if total else 0


raise SystemExit(main())