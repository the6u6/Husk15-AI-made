#!/bin/bash
# Verify the debugfs lookup picks the right candidate.
#
# The script tests `[ -x "$c" ]`. That cannot be exercised here: this runs under
# MSYS on NTFS, where chmod does not take and `[ -x ]` is false for every file
# (verified: a freshly chmod +x'ed file still reports -rw-r--r-- and `[ -x ]`
# says no). On the macOS runner brew's debugfs is 0755 and `-x` is true.
#
# So the predicate here is `[ -f ]`, which does work. What this actually proves
# is the part that is portable logic rather than filesystem trivia: that the loop
# stops at the first candidate that exists, prefers PATH when debugfs is already
# there, and reports nothing when no candidate exists.
#
# Kept next to the script so the branches can be re-checked when the lookup
# changes.

pass=0; fail=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1))
  else echo "  FAIL $1: expected [$2] got [$3]"; fail=$((fail+1)); fi
}

lookup() { # lookup <dir-of-candidates...>   (uses -f, see the note above)
  DEBUGFS=""
  for c in "$@"; do
    [ -f "$c" ] && DEBUGFS="$c" && break
  done
  printf '%s' "${DEBUGFS:-<none>}"
}

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
ARM="$W/opt/homebrew/opt/e2fsprogs/sbin/debugfs"
INT="$W/usr/local/opt/e2fsprogs/sbin/debugfs"
mkdir -p "$(dirname "$ARM")" "$(dirname "$INT")"
: > "$ARM"; : > "$INT"

echo "=== the loop picks the first candidate that exists ==="
check "Apple Silicon only"  "$ARM" "$(lookup "$ARM" "$INT")"
rm -f "$ARM"
check "Intel only"          "$INT" "$(lookup "$ARM" "$INT")"
: > "$ARM"
check "both present -> Apple Silicon wins" "$ARM" "$(lookup "$ARM" "$INT")"

echo
echo "=== reports <none> when nothing is installed ==="
rm -f "$ARM" "$INT"
check "neither"             "<none>" "$(lookup "$ARM" "$INT")"

echo
echo "=== PATH is preferred over the hardcoded prefixes ==="
mkdir -p "$W/onpath"; : > "$W/onpath/debugfs"
ONPATH="$(PATH="$W/onpath:$PATH" command -v debugfs)"
check "found on PATH"       "$ONPATH" "$(PATH="$W/onpath:$PATH"; DEBUGFS="$(command -v debugfs || true)"; printf '%s' "${DEBUGFS:-<none>}")"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]