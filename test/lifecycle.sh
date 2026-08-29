#!/bin/sh
# Lifecycle command tests — git only. No docker, no YAML backend required.
# Run directly:            ./test/lifecycle.sh
# Or from a linux suite:   sh /src/test/lifecycle.sh
set -eu

WT="${WT:-wt}"
TMP="$(mktemp -d)"
# Canonicalize: on macOS $TMPDIR lives under a symlink (/var -> /private/var),
# but git resolves absolute paths, so exact-path assertions below would
# otherwise compare an unresolved $TMP against wt's resolved output.
TMP="$(cd "$TMP" && pwd -P)"
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

# Setup calls whose failure is not itself the thing under test. Without this
# a regression in `wt new` (say) aborts the whole run under `set -eu` with no
# FAIL line at all — CI still notices (LIFECYCLE PASS never prints) but the
# diagnostic is gone. Never use it inside assert_fails, and never for a call
# whose output is being asserted (guard the capture instead).
wt_ok() { "$WT" "$@" >/dev/null 2>&1 || fail "setup: wt $*"; }

# Does this host have any YAML backend at all? Anything that makes wt read a
# worktree-kit.yml needs one; without it load_config dies and an unguarded
# capture would abort the suite silently.
have_yaml() {
  command -v yq >/dev/null 2>&1 || command -v ruby >/dev/null 2>&1 \
    || python3 -c 'import yaml' >/dev/null 2>&1
}

# A PATH on which `command -v docker` genuinely finds nothing.
#
# Two tests need docker to be *absent*, not merely broken: they cover
# `need docker` never firing for load_config_soft, and firing (so the stop
# fails and gets reported) for require_config. A stub that exits 127 would
# satisfy `command -v` and prove neither.
#
# Truncating PATH to /usr/bin:/bin is not it either: on Linux docker lives in
# /usr/bin, so the second assertion would invert and pass vacuously, and the
# truncation can take yq/ruby/python3 (and even git) down with it. Instead
# drop every directory that actually holds a docker executable, and symlink
# the tools wt needs into a scratch bin first so the drop cannot remove them.
NODOCKER_BIN="$TMP/nodocker-bin"
mkdir -p "$NODOCKER_BIN"
for _t in git sh awk sed grep tr cut head tail cat basename dirname mkdir rm mv \
          cksum wc find xargs column sort yq ruby python3; do
  _p="$(command -v "$_t" 2>/dev/null)" || continue
  case "$_p" in /*) ln -s "$_p" "$NODOCKER_BIN/$_t" 2>/dev/null || true ;; esac
done
NODOCKER_PATH="$NODOCKER_BIN"
_oldifs="$IFS"; IFS=:
for _d in $PATH; do
  [ -n "$_d" ] || _d=.
  if [ -x "$_d/docker" ]; then continue; fi
  NODOCKER_PATH="$NODOCKER_PATH:$_d"
done
IFS="$_oldifs"

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
out="$("$WT" list)" || fail "setup: wt list"
assert_contains "$out" master           "list: shows the primary branch"
assert_contains "$out" BRANCH           "list: prints a header"
# Was assert_missing "$out" "MISSING" — a string cmd_list has no code path to
# print (it belongs to cmd_doctor), i.e. an assertion that could not fail.
# What "no config is not an error" actually means for wt list is that the
# missing config draws no complaint on stderr and no nonzero exit.
err="$("$WT" list 2>&1 >/dev/null)" || fail "list: nonzero exit without a config"
assert_eq "" "$err"                     "list: no config is not an error"

git worktree add -q "$TMP/feat-one" -b feat/one
out="$("$WT" list)" || fail "setup: wt list"
assert_contains "$out" "feat/one"       "list: shows a second worktree"
assert_contains "$out" "feat_one"       "list: slug matches ctx_init derivation"
assert_contains "$out" "clean"          "list: clean worktree reports clean"

echo dirty > "$TMP/feat-one/x.txt"
out="$("$WT" list)" || fail "setup: wt list"
assert_contains "$out" "dirty"          "list: dirty worktree reports dirty"

git branch -q spare
out="$("$WT" list --all)" || fail "setup: wt list --all"
assert_contains "$out" "spare"          "list --all: includes branches with no worktree"
out="$("$WT" list)" || fail "setup: wt list"
assert_missing  "$out" "spare"          "list: plain list omits branchless branches"

# existing commands must still refuse to run without a config
assert_fails "run still requires config" "$WT" run -- true

# load_config_soft must never require docker: a compose config (the
# default runner when `runner:` is omitted) must not stop `wt list` from
# working when docker isn't even on PATH — only the ten pre-existing
# commands (via require_config) may demand it.
new_repo nodockerrepo
printf 'hooks:\n  server: "true"\n' > worktree-kit.yml
if have_yaml; then
  out="$(PATH="$NODOCKER_PATH" "$WT" list)" || fail "list: died with a compose config and no docker"
  assert_contains "$out" master "list: works with a compose config and no docker on PATH"
else
  ok "list: works with a compose config and no docker on PATH (skipped: no YAML backend)"
fi

# ---------- Task 2: new ----------

new_repo newrepo
out="$("$WT" new feat/refund-flow 2>/dev/null)" || fail "setup: wt new feat/refund-flow"
assert_eq "$TMP/newrepo-worktrees/feat_refund_flow" "$out" \
  "new: default template, branch sanitized for the path"
assert_eq "0" "$(test -d "$TMP/newrepo-worktrees/feat_refund_flow"; echo $?)" \
  "new: directory created"
assert_contains "$(git -C "$REPO" branch --list 'feat/refund-flow')" "feat/refund-flow" \
  "new: branch created with slashes intact"
assert_contains "$("$WT" list)" "feat_refund_flow" "new: slug is the last path segment"

# a branch that exists but has no worktree is adopted, not rejected
git -C "$REPO" branch -q orphan
out="$("$WT" new orphan 2>/dev/null)" || fail "setup: wt new orphan"
assert_eq "$TMP/newrepo-worktrees/orphan" "$out" "new: adopts an existing branch"

# a branch that already has a worktree is an error
assert_fails "new: rejects a branch that already has a worktree" "$WT" new orphan

# --from picks the base
git -C "$REPO" checkout -q -b basis
echo b > "$REPO/b.txt"; git -C "$REPO" add b.txt; git -C "$REPO" commit -qm basis
git -C "$REPO" checkout -q master
wt_ok new derived --from basis
assert_eq "0" "$(test -f "$TMP/newrepo-worktrees/derived/b.txt"; echo $?)" \
  "new --from: branched from the named base"

# expand_path feeds {parent} {repo} {home} and {branch_raw} to sed as
# REPLACEMENT text, where & means "the whole match" and \ starts an escape.
# The DEFAULT template uses {parent} and {repo}, so a repo directory holding
# an & silently produced a wrong path (R&D-app -> R{repo}D-app) — and the
# last segment of that path is what names the slug, the port, the redis slot
# and the database.
new_repo 'R&D-app'
ampout="$("$WT" new feat/amp 2>/dev/null)" || fail "setup: wt new in an & repo"
assert_eq "$TMP/R&D-app-worktrees/feat_amp" "$ampout" \
  "new: an & in the repo directory survives path expansion literally"
assert_eq "0" "$(test -d "$TMP/R&D-app-worktrees/feat_amp" && echo 0 || echo 1)" \
  "new: the & path is the directory actually created"

# a template that yields a space is refused before anything is created
new_repo spacerepo
printf 'runner: host\nhooks:\n  server: "true"\n' > worktree-kit.yml
cat > worktree-kit.local.yml <<'YML'
worktrees:
  path: "{parent}/has space/{branch}"
YML
assert_fails "new: refuses a path containing a space" "$WT" new anything
assert_eq "1" "$(test -d "$TMP/has space" && echo 0 || echo 1)" "new: nothing created on refusal"

# hooks.prepare must run exactly once. cmd_new used to hand the hook itself
# to `wt run` as its payload, on top of `wt run` already running the hook
# before execing its payload — silently double-running seed/migration
# scripts. The counter lives outside the worktree so it survives the
# prepare hook's own cwd (the new worktree) and can be inspected here.
new_repo prepcountrepo
_counter="$TMP/prepare-count.txt"
: > "$_counter"
printf 'runner: host\nhooks:\n  prepare: "echo x >> %s"\n  server: "true"\n' "$_counter" \
  > worktree-kit.yml
if have_yaml; then
  wt_ok new prepped
  assert_eq "1" "$(wc -l < "$_counter" | tr -d ' ')" "new: prepare hook runs exactly once"
else
  ok "new: prepare hook runs exactly once (skipped: no YAML backend)"
fi

# ---------- Task 3: switch and shell-init ----------

new_repo switchrepo
wt_ok new feat/alpha

# stdout carries only the path; the hint goes to stderr
out="$("$WT" switch feat/alpha 2>/dev/null)" || fail "setup: wt switch feat/alpha"
assert_eq "$TMP/switchrepo-worktrees/feat_alpha" "$out" "switch: stdout is the bare path"

err="$("$WT" switch feat/alpha 2>&1 >/dev/null)" || fail "setup: wt switch feat/alpha"
assert_contains "$err" "shell-init" "switch: hints about shell integration on stderr"

err="$(WT_SHELL_INTEGRATION=1 "$WT" switch feat/alpha 2>&1 >/dev/null)" \
  || fail "setup: wt switch feat/alpha under shell integration"
assert_eq "" "$err" "switch: no stderr noise under shell integration"

assert_fails "switch: unknown branch is an error" "$WT" switch nope
err="$("$WT" switch nope 2>&1 >/dev/null || true)"
assert_contains "$err" "nope" "switch: names the branch it could not find"

git -C "$REPO" branch -q lonely
err="$("$WT" switch lonely 2>&1 >/dev/null || true)"
assert_contains "$err" "wt new lonely" "switch: branch without a worktree points at wt new"

# shell-init emits a wrapper covering all four cd-channel commands
out="$("$WT" shell-init zsh)" || fail "setup: wt shell-init zsh"
assert_contains "$out" "switch|new|rm|merge" "shell-init: wraps every cd-channel command"
assert_contains "$out" "WT_SHELL_INTEGRATION=1" "shell-init: exports the marker"
assert_contains "$out" 'if [ -n "$__wt_d" ]; then' "shell-init: explicit if, not && (bug 1)"
out="$("$WT" shell-init fish)" || fail "setup: wt shell-init fish"
assert_contains "$out" "function wt" "shell-init: fish variant"
# fish gained single-command variable overrides (VAR=x cmd) late; on older
# releases that form is a SYNTAX error, which would make `eval (wt shell-init
# fish)` break the wt function outright. `env VAR=x cmd` parses everywhere.
assert_contains "$out" 'env WT_SHELL_INTEGRATION=1 wt $argv' \
  "shell-init: fish uses env, not a fish-version-dependent inline override"
assert_missing "$out" '(WT_SHELL_INTEGRATION=1 command wt' \
  "shell-init: fish avoids the inline override form entirely"
assert_fails "shell-init: rejects an unknown shell" "$WT" shell-init tcsh

# shell-init must work outside a git repo
out="$(cd "$TMP" && "$WT" shell-init bash)" || fail "setup: wt shell-init bash outside a repo"
assert_contains "$out" "command wt" "shell-init: works outside a git repo"

# ---------- Task 4: rm ----------

new_repo rmrepo
wt_ok new feat/gone
wtdir="$TMP/rmrepo-worktrees/feat_gone"

# fabricate the state files a server would have left behind
state="$REPO/.git/wt-state"
mkdir -p "$state/logs"
: > "$state/feat_gone.dbready"
: > "$state/feat_gone.port"
: > "$state/logs/feat_gone.log"

# a dirty worktree is refused without --force. assert_fails only pins the
# exit code, so each refusal below also pins WHY — a guard-ordering
# regression that refused for a different reason would otherwise pass.
echo scratch > "$wtdir/scratch.txt"
assert_fails "rm: refuses a dirty worktree" "$WT" rm feat/gone
err="$("$WT" rm feat/gone 2>&1 >/dev/null || true)"
assert_contains "$err" "uncommitted changes" "rm: the dirty refusal names uncommitted changes"
assert_eq "0" "$(test -d "$wtdir" && echo 0 || echo 1)" "rm: dirty worktree survives the refusal"
rm "$wtdir/scratch.txt"

# unmerged commits are refused without --force
( cd "$wtdir" && echo c > c.txt && git add c.txt && git commit -qm work )
assert_fails "rm: refuses unmerged commits" "$WT" rm feat/gone
err="$("$WT" rm feat/gone 2>&1 >/dev/null || true)"
assert_contains "$err" "commit(s) not in master" \
  "rm: the unmerged refusal names the commits and the trunk"

# --force removes it and reclaims every state file. Nothing may reach stdout:
# the removed worktree was not the caller's cwd, and stdout is the cd channel
# — a stray line there makes the shell wrapper cd to garbage.
rmout="$("$WT" rm feat/gone --force 2>/dev/null)" || fail "setup: wt rm feat/gone --force"
assert_eq "" "$rmout" "rm: silent on stdout when the cwd was not removed"
assert_eq "1" "$(test -d "$wtdir" && echo 0 || echo 1)"                    "rm --force: worktree gone"
assert_eq "1" "$(test -f "$state/feat_gone.dbready" && echo 0 || echo 1)"  "rm --force: dbready cleared"
assert_eq "1" "$(test -f "$state/feat_gone.port" && echo 0 || echo 1)"     "rm --force: port file cleared"
assert_eq "1" "$(test -f "$state/logs/feat_gone.log" && echo 0 || echo 1)" "rm --force: log cleared"
assert_missing "$(git -C "$REPO" branch --list 'feat/gone')" "feat/gone" \
  "rm --force: branch deleted"

# --keep-branch keeps the branch
wt_ok new feat/keep
wt_ok rm feat/keep --force --keep-branch
assert_contains "$(git -C "$REPO" branch --list 'feat/keep')" "feat/keep" \
  "rm --keep-branch: branch survives"

# the primary checkout is never removable
assert_fails "rm: refuses the primary checkout" "$WT" rm master --force

# a clean, fully merged worktree needs no --force, but does need a yes
wt_ok new feat/clean
printf 'y\n' | "$WT" rm feat/clean >/dev/null 2>&1 || fail "setup: wt rm feat/clean"
assert_eq "1" "$(test -d "$TMP/rmrepo-worktrees/feat_clean" && echo 0 || echo 1)" \
  "rm: clean merged worktree removed after confirmation"

# answering no leaves everything alone
wt_ok new feat/spared
printf 'n\n' | "$WT" rm feat/spared >/dev/null 2>&1 || true
assert_eq "0" "$(test -d "$TMP/rmrepo-worktrees/feat_spared" && echo 0 || echo 1)" \
  "rm: declining the prompt keeps the worktree"

# ---------- Task 4 fix round 1 ----------

# Item 3: from inside the worktree being removed, wt rm must survive git's
# cwd being yanked out from under it (git worktree remove deletes the cwd,
# then git branch -d's getcwd() call dies) and still land the caller in the
# primary via the cd channel. Runs first, in rmrepo, while $REPO/cwd still
# point there — every later block in this section calls new_repo again.
wt_ok new feat/herecwd
wtdir_here="$TMP/rmrepo-worktrees/feat_herecwd"
rmrepo_repo="$REPO"
out="$( (cd "$wtdir_here" && "$WT" rm feat/herecwd --force 2>/dev/null) || true )"
assert_eq "$rmrepo_repo" "$out" "rm: from inside the worktree, prints the primary for cd"

# Item 1: the entire HAS_CONFIG=1 teardown branch (server-stop, the db
# ownership gate, db_drop, redis_flush, the "left behind" notices, and the
# SLUG/N borrow) is otherwise never exercised — rmrepo above has no config.
new_repo cfgrmrepo
if have_yaml; then
db_sentinel="$TMP/db-drop.sentinel"
redis_sentinel="$TMP/redis-flush.sentinel"
# hooks.prepare records the cwd runner_exec used, so the teardown's target
# can be checked, not just its effect.
where_sentinel="$TMP/prepare-cwd.sentinel"
cat > worktree-kit.yml <<YML
runner: host
hooks:
  prepare: "pwd >> $where_sentinel"
  server: "true"
isolation:
  db_drop: "echo dropped-{slug} >> $db_sentinel"
  redis_flush: "echo flushed-{slug}-{n} >> $redis_sentinel"
YML
wt_ok new feat/owned
wt_ok new feat/adopted
cfgstate="$REPO/.git/wt-state"
# feat_owned: the kit bootstrapped this database itself.
: > "$cfgstate/feat_owned.dbready"
: > "$cfgstate/feat_owned.dbowned"
# feat_adopted: db_check found a pre-existing database and merely adopted
# it (ensure_own_db touches .dbready but never .dbowned on that path) — it
# stands in for a database wt rm must never drop.
: > "$cfgstate/feat_adopted.dbready"

# Discard what `wt new` itself recorded; only the teardown's runs matter.
: > "$where_sentinel"
wt_ok rm feat/owned --force
assert_contains "$(cat "$db_sentinel" 2>/dev/null)" "dropped-feat_owned" \
  "rm: drops a database the kit itself bootstrapped"
assert_contains "$(cat "$redis_sentinel" 2>/dev/null)" "flushed-feat_owned-" \
  "rm: flushes the redis slot for a configured worktree (SLUG/N borrow works)"
# teardown_worktree borrowed SLUG and N for the target but left $WT_PATH
# pointing at the CALLER's worktree, which is what runner_exec keys off: the
# repo's prepare hook re-ran in the caller (bundle install, npm ci, ...) and
# db_drop/redis_flush resolved relative paths against the wrong tree.
assert_contains "$(cat "$where_sentinel" 2>/dev/null)" \
  "$TMP/cfgrmrepo-worktrees/feat_owned" \
  "rm: teardown hooks run in the TARGET worktree"
# grep -xF, not assert_missing: $REPO is a string PREFIX of the target path,
# so a substring test could never distinguish the two.
assert_eq "" "$(grep -xF "$REPO" "$where_sentinel" 2>/dev/null || true)" \
  "rm: teardown hooks never re-run in the caller's worktree"

wt_ok rm feat/adopted --force
assert_missing "$(cat "$db_sentinel" 2>/dev/null)" "dropped-feat_adopted" \
  "rm: never drops a database it only adopted (.dbready without .dbowned)"

# The no-.dbowned notice is what every pre-0.2.0 user sees on their first
# wt rm: .dbowned did not exist before this release, so their kit-created
# databases carry only .dbready. It must not claim wt did not create them.
wt_ok new feat/msg
: > "$cfgstate/feat_msg.dbready"
err="$("$WT" rm feat/msg --force 2>&1 >/dev/null)" || true
assert_contains "$err" "no ownership marker" \
  "rm: the no-.dbowned notice does not assert the database was adopted"
assert_missing "$err" "adopted, not created by wt" \
  "rm: the no-.dbowned notice is not wrong for upgrading users"
else
  for _l in "rm: drops a database the kit itself bootstrapped" \
            "rm: flushes the redis slot for a configured worktree (SLUG/N borrow works)" \
            "rm: teardown hooks run in the TARGET worktree" \
            "rm: teardown hooks never re-run in the caller's worktree" \
            "rm: never drops a database it only adopted (.dbready without .dbowned)" \
            "rm: the no-.dbowned notice does not assert the database was adopted" \
            "rm: the no-.dbowned notice is not wrong for upgrading users"; do
    ok "$_l (skipped: no YAML backend)"
  done
fi

# Item 2: a configured trunk that does not resolve as a ref in this worktree
# must not be silently treated as "nothing unmerged" — "cannot check" must
# not mean "safe to delete" for a destructive command.
new_repo trunkguardrepo
printf 'runner: host\nhooks:\n  server: "true"\nworktrees:\n  trunk: develop\n' \
  > worktree-kit.yml
if have_yaml; then
  wt_ok new feat/risky
  ( cd "$TMP/trunkguardrepo-worktrees/feat_risky" && echo x > x.txt && git add x.txt && git commit -qm risky )
  printf 'y\n' | "$WT" rm feat/risky >/dev/null 2>&1 || true
  assert_eq "0" "$(test -d "$TMP/trunkguardrepo-worktrees/feat_risky" && echo 0 || echo 1)" \
    "rm: an unverifiable configured trunk refuses rather than failing open"
else
  ok "rm: an unverifiable configured trunk refuses rather than failing open (skipped: no YAML backend)"
fi

# Item 4: a failed server-stop must be surfaced, not swallowed — otherwise
# state files vanish, wt ps can no longer see the orphaned server, and wt rm
# still reports success.
new_repo swallowfailrepo
printf 'hooks:\n  server: "true"\n' > worktree-kit.yml
if have_yaml; then
  wt_ok new feat/failstop
  err="$(PATH="$NODOCKER_PATH" "$WT" rm feat/failstop --force 2>&1 >/dev/null)" || true
  assert_contains "$err" "could not stop the server" \
    "rm: a failed server-stop is reported, not swallowed"
else
  ok "rm: a failed server-stop is reported, not swallowed (skipped: no YAML backend)"
fi

# ---------- Task 4 fix round 2 ----------

# wt reset must clear both provenance markers together. A stale .dbowned
# surviving a reset would let a later, merely-adopted database (db_check
# touches only .dbready) inherit an ownership claim it never earned — the
# exact guarantee round 1's item 5 established for wt rm (and, imminently,
# wt merge, which does not prompt).
new_repo resetrepo
rstate="$REPO/.git/wt-state"
mkdir -p "$rstate"
: > "$rstate/someslug.dbready"
: > "$rstate/someslug.dbowned"
wt_ok reset someslug
assert_eq "1" "$(test -f "$rstate/someslug.dbready" && echo 0 || echo 1)" \
  "reset: clears the dbready marker"
assert_eq "1" "$(test -f "$rstate/someslug.dbowned" && echo 0 || echo 1)" \
  "reset: clears the dbowned marker too"

# ---------- Task 4 fix round 3: removal after the irreversible half ----------
#
# Both callers run teardown_worktree FIRST — server stopped, DROP DATABASE,
# FLUSHDB, every state file gone. Only then is the worktree/branch removed.
# Bare git calls there mean a failure at that point aborts under set -e with
# nothing but git's own stderr: no "removed", no cd-channel output, and no
# hint that the irreversible half already ran.

# The reachable case: `git branch -d` asks "merged into HEAD?", a different
# question from the "merged into trunk?" cmd_rm already answered. Removing a
# sibling worktree leaves cwd — and HEAD — on the sibling's branch, so -d can
# refuse a branch wt has verified.
new_repo unmergedheadrepo
wt_ok new feat/behind                      # stays at master's original commit
bhdir="$TMP/unmergedheadrepo-worktrees/feat_behind"
wt_ok new feat/ahead
ahdir="$TMP/unmergedheadrepo-worktrees/feat_ahead"
( cd "$ahdir" && echo z > z.txt && git add z.txt && git commit -qm z )
git -C "$REPO" merge -q --ff-only feat/ahead   # merged into trunk, not into feat/behind
rmerr="$( (cd "$bhdir" && printf 'y\n' | "$WT" rm feat/ahead 2>&1 >/dev/null) )" \
  || fail "rm: a git branch -d refusal must not abort after teardown"
assert_eq "1" "$(test -d "$ahdir" && echo 0 || echo 1)" \
  "rm: the worktree is still removed when git branch -d refuses"
assert_contains "$rmerr" "refused to delete branch" \
  "rm: a git branch -d refusal is reported, not fatal"

# The happy cross-worktree case: removing a sibling must succeed, delete the
# branch, and print nothing at all on the cd channel.
new_repo crossrmrepo
wt_ok new feat/a
adir="$TMP/crossrmrepo-worktrees/feat_a"
( cd "$adir" && echo a > a.txt && git add a.txt && git commit -qm a )
git -C "$REPO" merge -q --ff-only feat/a
wt_ok new feat/b                           # branched from master, which now has feat/a
bdir="$TMP/crossrmrepo-worktrees/feat_b"
crossout="$( (cd "$bdir" && printf 'y\n' | "$WT" rm feat/a 2>/dev/null) )" \
  || fail "rm: cross-worktree removal failed"
assert_eq "" "$crossout" "rm: silent on stdout when a sibling worktree was removed"
assert_missing "$(git -C "$REPO" branch --list 'feat/a')" "feat/a" \
  "rm: cross-worktree branch deleted"
assert_eq "1" "$(test -d "$adir" && echo 0 || echo 1)" "rm: cross-worktree directory removed"

# git worktree remove itself can fail after teardown (a locked worktree is
# the reliable trigger). The message must say the reclaim already happened.
new_repo lockedrmrepo
wt_ok new feat/locked
ldir="$TMP/lockedrmrepo-worktrees/feat_locked"
git -C "$REPO" worktree lock "$ldir"
lockerr="$(printf 'y\n' | "$WT" rm feat/locked 2>&1 >/dev/null || true)"
assert_contains "$lockerr" "already reclaimed" \
  "rm: a failed worktree removal says the server, database and state are already gone"
assert_contains "$lockerr" "git worktree prune" \
  "rm: a failed worktree removal prints the recovery command"
git -C "$REPO" worktree unlock "$ldir"

# ---------- Task 5: merge ----------

new_repo mergerepo
"$WT" new feat/work >/dev/null 2>&1 || fail "merge: setup — wt new feat/work failed"
wtdir="$TMP/mergerepo-worktrees/feat_work"
( cd "$wtdir" && echo one > one.txt && git add one.txt && git commit -qm "add one" )
( cd "$wtdir" && echo two > two.txt && git add two.txt && git commit -qm "add two" )
pre_merge_head="$(git -C "$wtdir" rev-parse HEAD)"

before="$(git -C "$REPO" rev-parse master)"
# Capture stdout rather than discarding it: the removed worktree is not the
# caller's cwd, so spec §5 requires nothing at all on the cd channel.
mout="$("$WT" merge feat/work 2>/dev/null)" || fail "merge: feat/work merge failed"
assert_eq "" "$mout" "merge: silent on stdout when the cwd was not removed"
after="$(git -C "$REPO" rev-parse master)"

# assert_eq "1" "$(test A = B; echo $?)" dies inside the substitution under
# set -eu whenever the test succeeds (before==after), i.e. exactly when the
# merge failed to advance master — so it could only ever fail for the right
# reason and never confirm success. Express the intent directly instead.
if [ "$before" = "$after" ]; then fail "merge: master advanced"; else ok "merge: master advanced"; fi
assert_eq "1" "$(git -C "$REPO" rev-list --count "$before..$after")" \
  "merge: two commits squashed into one"
assert_contains "$(git -C "$REPO" log -1 --format=%s)" "add one" \
  "merge: subject taken from the first commit"
assert_contains "$(git -C "$REPO" log -1 --format=%B)" "add two" \
  "merge: remaining subjects form the body"
assert_eq "1" "$(test -d "$wtdir" && echo 0 || echo 1)" "merge: worktree removed by default"
# Proves both the ref's name AND its value/timing: the squash's parent is
# the merge-base (the repo's init commit), not "add one" — so a backup
# written after the squash (instead of before) would point at a commit
# with a different parent than pre_merge_head, and this would catch it
# regardless of any commit-timestamp coincidence.
backup_head="$(git -C "$REPO" rev-parse --verify --quiet refs/wt/premerge/feat_work 2>/dev/null || echo MISSING)"
assert_eq "$pre_merge_head" "$backup_head" \
  "merge: backup ref captures the branch's pre-squash HEAD, written before the rewrite"

# --no-remove leaves the worktree in place
"$WT" new feat/stay >/dev/null 2>&1 || fail "merge --no-remove: setup — wt new feat/stay failed"
( cd "$TMP/mergerepo-worktrees/feat_stay" && echo s > s.txt && git add s.txt && git commit -qm stay )
"$WT" merge feat/stay --no-remove >/dev/null 2>&1 || fail "merge --no-remove: merge failed"
assert_eq "0" "$(test -d "$TMP/mergerepo-worktrees/feat_stay" && echo 0 || echo 1)" \
  "merge --no-remove: worktree survives"

# a conflicting rebase restores the branch exactly and leaves the worktree alone
#
# feat/conflict gets TWO commits (not one) deliberately: squashing a
# single-commit branch can produce a commit identical in every field but
# timestamp to the original, and if both land in the same wall-clock
# second, the squash commit hashes IDENTICALLY to $orig — so a bare
# "rebase --abort" (no explicit restore at all) would coincidentally leave
# HEAD at a SHA equal to $orig, and the SHA-equality assertion below would
# pass even with the restore code deleted. Two commits make the squash
# collapse two parents into one, which changes the history SHAPE
# (2 commits -> 1) regardless of any timestamp coincidence, so the
# rev-list --count assertion cannot pass by accident.
new_repo conflictrepo
echo base > f.txt && git add f.txt && git commit -qm base
base="$(git -C "$REPO" rev-parse HEAD)"
"$WT" new feat/conflict >/dev/null 2>&1 || fail "merge: setup — wt new feat/conflict failed"
cdir="$TMP/conflictrepo-worktrees/feat_conflict"
( cd "$cdir" && echo mid > mid.txt && git add mid.txt && git commit -qm mid )
( cd "$cdir" && echo theirs > f.txt && git add f.txt && git commit -qm theirs )
orig="$(git -C "$cdir" rev-parse HEAD)"
echo ours > f.txt && git add f.txt && git commit -qm ours
master_before="$(git -C "$REPO" rev-parse master)"

assert_fails "merge: conflict is an error" "$WT" merge feat/conflict
assert_eq "$orig" "$(git -C "$cdir" rev-parse HEAD)" \
  "merge: branch restored to its pre-squash commit after a conflict"
assert_eq "2" "$(git -C "$cdir" rev-list --count "$base..HEAD")" \
  "merge: pre-squash history restored, not just aborted"
assert_eq "$master_before" "$(git -C "$REPO" rev-parse master)" \
  "merge: master untouched after a conflict"
assert_eq "0" "$(test -d "$cdir" && echo 0 || echo 1)" "merge: worktree survives a conflict"
assert_eq "" "$(git -C "$cdir" status --porcelain)" \
  "merge: working tree left clean after a conflict"
# status --porcelain reports working-tree state, not rebase state — an
# interrupted rebase with a clean tree passes it. Ask git for the real thing:
# neither rebase state directory may exist (merge backend or am backend).
rebase_state=0
for _d in rebase-merge rebase-apply; do
  if [ -e "$(git -C "$cdir" rev-parse --git-path "$_d")" ]; then rebase_state=1; fi
done
assert_eq "0" "$rebase_state" "merge: no rebase left in progress"

# guards
new_repo guardrepo
"$WT" new feat/empty >/dev/null 2>&1 || fail "merge: setup — wt new feat/empty failed"
assert_fails "merge: refuses a branch with no commits ahead" "$WT" merge feat/empty

"$WT" new feat/dirty >/dev/null 2>&1 || fail "merge: setup — wt new feat/dirty failed"
( cd "$TMP/guardrepo-worktrees/feat_dirty" && echo d > d.txt && git add d.txt \
    && git commit -qm d && echo x > x.txt )
assert_fails "merge: refuses a dirty worktree" "$WT" merge feat/dirty

"$WT" new feat/ok >/dev/null 2>&1 || fail "merge: setup — wt new feat/ok failed"
( cd "$TMP/guardrepo-worktrees/feat_ok" && echo o > o.txt && git add o.txt && git commit -qm o )
echo primarydirt > "$REPO/dirt.txt"
assert_fails "merge: refuses when the primary checkout is dirty" "$WT" merge feat/ok
rm -f "$REPO/dirt.txt"

# trunk not checked out at the primary. assert_fails alone is not enough
# here: without this guard, "wt merge feat/tc" would ff-only-merge into
# whatever IS checked out ("other") instead of refusing, and since "other"
# happens to be fully mergeable it exits 0 having done real damage — so
# what actually proves the guard fired is that master (the real trunk)
# never moved, not just a nonzero exit.
new_repo trunkcheckoutrepo
"$WT" new feat/tc >/dev/null 2>&1 || fail "merge: setup — wt new feat/tc failed"
( cd "$TMP/trunkcheckoutrepo-worktrees/feat_tc" && echo t > t.txt && git add t.txt && git commit -qm t )
git -C "$REPO" checkout -qb other
master_before_tc="$(git -C "$REPO" rev-parse master)"
assert_fails "merge: refuses when trunk is not checked out at the primary" "$WT" merge feat/tc
assert_eq "0" "$(test -d "$TMP/trunkcheckoutrepo-worktrees/feat_tc" && echo 0 || echo 1)" \
  "merge: refused-trunk-checkout worktree survives"
assert_eq "$master_before_tc" "$(git -C "$REPO" rev-parse master)" \
  "merge: refused-trunk-checkout master untouched — the guard fires before any rewrite"

# a branch with an upstream is refused unless --force (squashing would
# rewrite already-published history) — this is --force's only consumer
# in wt merge, so exercise both the refusal and the override.
#
# assert_fails alone is not enough here either: without this guard, the
# squash/rebase/ff-only-merge all still succeed (master DOES advance), and
# the command only fails at the very end, when "git branch -d" hits ITS
# OWN unrelated safety check (a branch not merged to its upstream) — an
# entirely different, incidental refusal that fires only after the
# destructive rewrite already happened. The real proof our guard (not
# git's) is what's stopping this is that master and the branch never move.
new_repo upstreamrepo
remote_bare="$TMP/upstream-bare.git"
git init -q --bare "$remote_bare"
"$WT" new feat/pushed >/dev/null 2>&1 || fail "merge: setup — wt new feat/pushed failed"
pdir="$TMP/upstreamrepo-worktrees/feat_pushed"
( cd "$pdir" && echo p > p.txt && git add p.txt && git commit -qm p )
git -C "$pdir" remote add origin "$remote_bare"
git -C "$pdir" push -q origin feat/pushed
git -C "$pdir" branch -q --set-upstream-to=origin/feat/pushed feat/pushed
pushed_head="$(git -C "$pdir" rev-parse HEAD)"
master_before_upstream="$(git -C "$REPO" rev-parse master)"

assert_fails "merge: refuses a branch with an upstream without --force" "$WT" merge feat/pushed
uerr="$("$WT" merge feat/pushed 2>&1 >/dev/null || true)"
assert_contains "$uerr" "has an upstream" \
  "merge: the upstream refusal names the upstream, not some later incidental failure"
assert_eq "0" "$(test -d "$pdir" && echo 0 || echo 1)" \
  "merge: refused-upstream worktree survives"
assert_eq "$master_before_upstream" "$(git -C "$REPO" rev-parse master)" \
  "merge: refused-upstream master untouched — the guard fires before any rewrite"
assert_eq "$pushed_head" "$(git -C "$pdir" rev-parse HEAD)" \
  "merge: refused-upstream branch untouched — the guard fires before any rewrite"

upstream_before="$(git -C "$REPO" rev-parse master)"
"$WT" merge feat/pushed --force >/dev/null 2>&1 || fail "merge --force: merge failed"
if [ "$upstream_before" = "$(git -C "$REPO" rev-parse master)" ]; then
  fail "merge --force: overrides the upstream guard and merges anyway"
else
  ok "merge --force: overrides the upstream guard and merges anyway"
fi

# wt merge from inside the worktree being merged must survive the cwd being
# yanked out from under it (git worktree remove deletes the cwd, then
# git branch -d's getcwd() call dies) and still land the caller in the
# primary via the cd channel — the same defect Task 4 fixed for wt rm.
new_repo cwdrepo
"$WT" new feat/incwd >/dev/null 2>&1 || fail "merge: setup — wt new feat/incwd failed"
wtdir_incwd="$TMP/cwdrepo-worktrees/feat_incwd"
( cd "$wtdir_incwd" && echo w > w.txt && git add w.txt && git commit -qm w )
cwdrepo_repo="$REPO"
out="$( (cd "$wtdir_incwd" && "$WT" merge feat/incwd 2>/dev/null) || true )"
assert_eq "$cwdrepo_repo" "$out" "merge: from inside the worktree, prints the primary for cd"

# ---------- Task 6: doctor ----------

new_repo doctorrepo
out="$("$WT" doctor 2>&1)" || fail "setup: wt doctor"
assert_contains "$out" "wt path:" "doctor: reports the path template"
assert_contains "$out" "fzf:"     "doctor: reports fzf availability"
assert_contains "$out" "shell:"   "doctor: reports shell integration state"

out="$(WT_SHELL_INTEGRATION=1 "$WT" doctor 2>&1)" || fail "setup: wt doctor under integration"
assert_contains "$out" "integration active" "doctor: detects an active wrapper"

# $HOME is dereferenced unguarded under set -eu in two places doctor reaches:
# the {home} path expansion (evaluated whether or not the template uses it)
# and the rc-file scan. env -i, some CI runners and some container
# entrypoints leave HOME unset, where a bare $HOME is a fatal
# parameter-not-set rather than a missing-integration report.
if ( unset HOME; "$WT" doctor >/dev/null 2>&1 ); then
  ok "doctor: survives an unset HOME"
else
  fail "doctor: survives an unset HOME"
fi
homeout="$( (unset HOME; "$WT" doctor 2>&1) || true )"
assert_contains "$homeout" "shell:" "doctor: still reports shell integration with HOME unset"

# The two template warnings need a YAML backend to read the .local file, AND
# a main worktree-kit.yml to exist — load_config_soft gates on $CONFIG (the
# non-local file), not $LOCAL_CONFIG, so with only the .local file present
# HAS_CONFIG stays 0 and path_template() never consults either file. runner:
# host is mandatory here (not compose) — require_config would otherwise
# demand docker, which is not running in this environment.
if have_yaml; then
  printf 'runner: host\nhooks:\n  server: "true"\n' > worktree-kit.yml
  cat > worktree-kit.local.yml <<'YML'
worktrees:
  path: "{parent}/{repo}-worktrees/fixed"
YML
  out="$("$WT" doctor 2>&1)" || fail "setup: wt doctor with a fixed template"
  assert_contains "$out" "not branch-unique" "doctor: warns on a non-branch-unique template"

  cat > worktree-kit.local.yml <<'YML'
worktrees:
  path: "{parent}/has space/{branch}"
YML
  out="$("$WT" doctor 2>&1)" || fail "setup: wt doctor with a spacey template"
  # Not "space" alone: the unconditional "wt path:" line above already
  # echoes the raw template, which contains "has space" from the fixture's
  # own directory name — that substring would match whether or not the WARN
  # line fires. Assert on text only the WARN line itself can produce.
  assert_contains "$out" "wt new will refuse it" "doctor: warns on a template that yields a space"
  rm -f worktree-kit.local.yml worktree-kit.yml
else
  ok "doctor: template warnings skipped (no YAML backend installed)"
fi

# ---------- worktrees.path from the COMMITTED config ----------
#
# All ten shipped templates carry worktrees.path in worktree-kit.yml, but
# every other path test above writes worktree-kit.local.yml — so only
# local_get was covered and path_template()'s cfg_get fallback never ran.
# runner: host, not compose: compose would make wt new demand docker.
new_repo cfgpathrepo
if have_yaml; then
  cat > worktree-kit.yml <<'YML'
runner: host
hooks:
  server: "true"
worktrees:
  path: "{parent}/wt-committed-path/{branch}"
YML
  out="$("$WT" new feat/mainpath 2>/dev/null)" || fail "setup: wt new under a committed worktrees.path"
  assert_eq "$TMP/wt-committed-path/feat_mainpath" "$out" \
    "worktrees.path: a committed (non-.local) template drives the created path"
  assert_eq "0" "$(test -d "$TMP/wt-committed-path/feat_mainpath" && echo 0 || echo 1)" \
    "worktrees.path: the committed template's directory is the one created"
  assert_contains "$("$WT" list)" "feat_mainpath" \
    "worktrees.path: the slug follows the committed template's last segment"
else
  ok "worktrees.path: a committed (non-.local) template drives the created path (skipped: no YAML backend)"
  ok "worktrees.path: the committed template's directory is the one created (skipped: no YAML backend)"
  ok "worktrees.path: the slug follows the committed template's last segment (skipped: no YAML backend)"
fi

[ "$FAILED" = 0 ] || { echo "LIFECYCLE FAIL" >&2; exit 1; }
echo "LIFECYCLE PASS"
