#!/bin/sh
# Lifecycle command tests — git only. No docker, no YAML backend required.
# Run directly:            ./test/lifecycle.sh
# Or from a linux suite:   sh /src/test/lifecycle.sh
set -eu

WT="${WT:-wt}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILED=0
TAB="$(printf '\t')"

ok()   { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1" >&2; FAILED=1; }

assert_eq() { # <expected> <actual> <label>
  if [ "$1" = "$2" ]; then ok "$3"; else fail "$3: expected [$1] got [$2]"; fi
}

assert_contains() { # <haystack> <needle> <label>
  case "$1" in
    *"$2"*) ok "$3" ;;
    *)      fail "$3: [$1] does not contain [$2]" ;;
  esac
}

assert_missing() { # <haystack> <needle> <label>
  case "$1" in
    *"$2"*) fail "$3: [$1] unexpectedly contains [$2]" ;;
    *)      ok "$3" ;;
  esac
}

assert_fails() { # <label> <cmd...>
  _l="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$_l: expected nonzero exit"; else ok "$_l"; fi
}

# Creates a repo with one commit on branch `master`; sets REPO and cds into it.
new_repo() {
  REPO="$TMP/$1"
  mkdir -p "$REPO"
  cd "$REPO"
  git init -q
  git config user.email t@t.t
  git config user.name t
  git symbolic-ref HEAD refs/heads/master
  echo hi > README.md
  git add README.md
  git commit -qm init
}

# ---------- Task 1: list ----------

new_repo listrepo
out="$("$WT" list)"
assert_contains "$out" master           "list: shows the primary branch"
assert_contains "$out" BRANCH           "list: prints a header"
assert_missing  "$out" "MISSING"        "list: no config is not an error"

git worktree add -q "$TMP/feat-one" -b feat/one
out="$("$WT" list)"
assert_contains "$out" "feat/one"       "list: shows a second worktree"
assert_contains "$out" "feat_one"       "list: slug matches ctx_init derivation"
assert_contains "$out" "clean"          "list: clean worktree reports clean"

echo dirty > "$TMP/feat-one/x.txt"
out="$("$WT" list)"
assert_contains "$out" "dirty"          "list: dirty worktree reports dirty"

git branch -q spare
out="$("$WT" list --all)"
assert_contains "$out" "spare"          "list --all: includes branches with no worktree"
out="$("$WT" list)"
assert_missing  "$out" "spare"          "list: plain list omits branchless branches"

# existing commands must still refuse to run without a config
assert_fails "run still requires config" "$WT" run -- true

# load_config_soft must never require docker: a compose config (the
# default runner when `runner:` is omitted) must not stop `wt list` from
# working when docker isn't even on PATH — only the ten pre-existing
# commands (via require_config) may demand it.
new_repo nodockerrepo
printf 'hooks:\n  server: "true"\n' > worktree-kit.yml
out="$(PATH=/usr/bin:/bin "$WT" list)"
assert_contains "$out" master "list: works with a compose config and no docker on PATH"

[ "$FAILED" = 0 ] || { echo "LIFECYCLE FAIL" >&2; exit 1; }
echo "LIFECYCLE PASS"
