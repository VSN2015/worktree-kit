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

# ---------- Task 2: new ----------

new_repo newrepo
out="$("$WT" new feat/refund-flow 2>/dev/null)"
assert_eq "$TMP/newrepo-worktrees/feat_refund_flow" "$out" \
  "new: default template, branch sanitized for the path"
assert_eq "0" "$(test -d "$TMP/newrepo-worktrees/feat_refund_flow"; echo $?)" \
  "new: directory created"
assert_contains "$(git -C "$REPO" branch --list 'feat/refund-flow')" "feat/refund-flow" \
  "new: branch created with slashes intact"
assert_contains "$("$WT" list)" "feat_refund_flow" "new: slug is the last path segment"

# a branch that exists but has no worktree is adopted, not rejected
git -C "$REPO" branch -q orphan
out="$("$WT" new orphan 2>/dev/null)"
assert_eq "$TMP/newrepo-worktrees/orphan" "$out" "new: adopts an existing branch"

# a branch that already has a worktree is an error
assert_fails "new: rejects a branch that already has a worktree" "$WT" new orphan

# --from picks the base
git -C "$REPO" checkout -q -b basis
echo b > "$REPO/b.txt"; git -C "$REPO" add b.txt; git -C "$REPO" commit -qm basis
git -C "$REPO" checkout -q master
"$WT" new derived --from basis >/dev/null 2>&1
assert_eq "0" "$(test -f "$TMP/newrepo-worktrees/derived/b.txt"; echo $?)" \
  "new --from: branched from the named base"

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
"$WT" new prepped >/dev/null 2>&1
assert_eq "1" "$(wc -l < "$_counter" | tr -d ' ')" "new: prepare hook runs exactly once"

# ---------- Task 3: switch and shell-init ----------

new_repo switchrepo
"$WT" new feat/alpha >/dev/null 2>&1

# stdout carries only the path; the hint goes to stderr
out="$("$WT" switch feat/alpha 2>/dev/null)"
assert_eq "$TMP/switchrepo-worktrees/feat_alpha" "$out" "switch: stdout is the bare path"

err="$("$WT" switch feat/alpha 2>&1 >/dev/null)"
assert_contains "$err" "shell-init" "switch: hints about shell integration on stderr"

err="$(WT_SHELL_INTEGRATION=1 "$WT" switch feat/alpha 2>&1 >/dev/null)"
assert_eq "" "$err" "switch: no stderr noise under shell integration"

assert_fails "switch: unknown branch is an error" "$WT" switch nope
err="$("$WT" switch nope 2>&1 >/dev/null || true)"
assert_contains "$err" "nope" "switch: names the branch it could not find"

git -C "$REPO" branch -q lonely
err="$("$WT" switch lonely 2>&1 >/dev/null || true)"
assert_contains "$err" "wt new lonely" "switch: branch without a worktree points at wt new"

# shell-init emits a wrapper covering all four cd-channel commands
out="$("$WT" shell-init zsh)"
assert_contains "$out" "switch|new|rm|merge" "shell-init: wraps every cd-channel command"
assert_contains "$out" "WT_SHELL_INTEGRATION=1" "shell-init: exports the marker"
assert_contains "$out" 'if [ -n "$__wt_d" ]; then' "shell-init: explicit if, not && (bug 1)"
out="$("$WT" shell-init fish)"
assert_contains "$out" "function wt" "shell-init: fish variant"
assert_fails "shell-init: rejects an unknown shell" "$WT" shell-init tcsh

# shell-init must work outside a git repo
out="$(cd "$TMP" && "$WT" shell-init bash)"
assert_contains "$out" "command wt" "shell-init: works outside a git repo"

# ---------- Task 4: rm ----------

new_repo rmrepo
"$WT" new feat/gone >/dev/null 2>&1
wtdir="$TMP/rmrepo-worktrees/feat_gone"

# fabricate the state files a server would have left behind
state="$REPO/.git/wt-state"
mkdir -p "$state/logs"
: > "$state/feat_gone.dbready"
: > "$state/feat_gone.port"
: > "$state/logs/feat_gone.log"

# a dirty worktree is refused without --force
echo scratch > "$wtdir/scratch.txt"
assert_fails "rm: refuses a dirty worktree" "$WT" rm feat/gone
assert_eq "0" "$(test -d "$wtdir" && echo 0 || echo 1)" "rm: dirty worktree survives the refusal"
rm "$wtdir/scratch.txt"

# unmerged commits are refused without --force
( cd "$wtdir" && echo c > c.txt && git add c.txt && git commit -qm work )
assert_fails "rm: refuses unmerged commits" "$WT" rm feat/gone

# --force removes it and reclaims every state file
"$WT" rm feat/gone --force >/dev/null 2>&1
assert_eq "1" "$(test -d "$wtdir" && echo 0 || echo 1)"                    "rm --force: worktree gone"
assert_eq "1" "$(test -f "$state/feat_gone.dbready" && echo 0 || echo 1)"  "rm --force: dbready cleared"
assert_eq "1" "$(test -f "$state/feat_gone.port" && echo 0 || echo 1)"     "rm --force: port file cleared"
assert_eq "1" "$(test -f "$state/logs/feat_gone.log" && echo 0 || echo 1)" "rm --force: log cleared"
assert_missing "$(git -C "$REPO" branch --list 'feat/gone')" "feat/gone" \
  "rm --force: branch deleted"

# --keep-branch keeps the branch
"$WT" new feat/keep >/dev/null 2>&1
"$WT" rm feat/keep --force --keep-branch >/dev/null 2>&1
assert_contains "$(git -C "$REPO" branch --list 'feat/keep')" "feat/keep" \
  "rm --keep-branch: branch survives"

# the primary checkout is never removable
assert_fails "rm: refuses the primary checkout" "$WT" rm master --force

# a clean, fully merged worktree needs no --force, but does need a yes
"$WT" new feat/clean >/dev/null 2>&1
printf 'y\n' | "$WT" rm feat/clean >/dev/null 2>&1
assert_eq "1" "$(test -d "$TMP/rmrepo-worktrees/feat_clean" && echo 0 || echo 1)" \
  "rm: clean merged worktree removed after confirmation"

# answering no leaves everything alone
"$WT" new feat/spared >/dev/null 2>&1
printf 'n\n' | "$WT" rm feat/spared >/dev/null 2>&1 || true
assert_eq "0" "$(test -d "$TMP/rmrepo-worktrees/feat_spared" && echo 0 || echo 1)" \
  "rm: declining the prompt keeps the worktree"

# ---------- Task 4 fix round 1 ----------

# Item 3: from inside the worktree being removed, wt rm must survive git's
# cwd being yanked out from under it (git worktree remove deletes the cwd,
# then git branch -d's getcwd() call dies) and still land the caller in the
# primary via the cd channel. Runs first, in rmrepo, while $REPO/cwd still
# point there — every later block in this section calls new_repo again.
"$WT" new feat/herecwd >/dev/null 2>&1
wtdir_here="$TMP/rmrepo-worktrees/feat_herecwd"
rmrepo_repo="$REPO"
out="$( (cd "$wtdir_here" && "$WT" rm feat/herecwd --force 2>/dev/null) || true )"
assert_eq "$rmrepo_repo" "$out" "rm: from inside the worktree, prints the primary for cd"

# Item 1: the entire HAS_CONFIG=1 teardown branch (server-stop, the db
# ownership gate, db_drop, redis_flush, the "left behind" notices, and the
# SLUG/N borrow) is otherwise never exercised — rmrepo above has no config.
new_repo cfgrmrepo
db_sentinel="$TMP/db-drop.sentinel"
redis_sentinel="$TMP/redis-flush.sentinel"
cat > worktree-kit.yml <<YML
runner: host
hooks:
  server: "true"
isolation:
  db_drop: "echo dropped-{slug} >> $db_sentinel"
  redis_flush: "echo flushed-{slug}-{n} >> $redis_sentinel"
YML
"$WT" new feat/owned >/dev/null 2>&1
"$WT" new feat/adopted >/dev/null 2>&1
cfgstate="$REPO/.git/wt-state"
# feat_owned: the kit bootstrapped this database itself.
: > "$cfgstate/feat_owned.dbready"
: > "$cfgstate/feat_owned.dbowned"
# feat_adopted: db_check found a pre-existing database and merely adopted
# it (ensure_own_db touches .dbready but never .dbowned on that path) — it
# stands in for a database wt rm must never drop.
: > "$cfgstate/feat_adopted.dbready"

"$WT" rm feat/owned --force >/dev/null 2>&1
assert_contains "$(cat "$db_sentinel" 2>/dev/null)" "dropped-feat_owned" \
  "rm: drops a database the kit itself bootstrapped"
assert_contains "$(cat "$redis_sentinel" 2>/dev/null)" "flushed-feat_owned-" \
  "rm: flushes the redis slot for a configured worktree (SLUG/N borrow works)"

"$WT" rm feat/adopted --force >/dev/null 2>&1
assert_missing "$(cat "$db_sentinel" 2>/dev/null)" "dropped-feat_adopted" \
  "rm: never drops a database it only adopted (.dbready without .dbowned)"

# Item 2: a configured trunk that does not resolve as a ref in this worktree
# must not be silently treated as "nothing unmerged" — "cannot check" must
# not mean "safe to delete" for a destructive command.
new_repo trunkguardrepo
printf 'runner: host\nhooks:\n  server: "true"\nworktrees:\n  trunk: develop\n' \
  > worktree-kit.yml
"$WT" new feat/risky >/dev/null 2>&1
( cd "$TMP/trunkguardrepo-worktrees/feat_risky" && echo x > x.txt && git add x.txt && git commit -qm risky )
printf 'y\n' | "$WT" rm feat/risky >/dev/null 2>&1 || true
assert_eq "0" "$(test -d "$TMP/trunkguardrepo-worktrees/feat_risky" && echo 0 || echo 1)" \
  "rm: an unverifiable configured trunk refuses rather than failing open"

# Item 4: a failed server-stop must be surfaced, not swallowed — otherwise
# state files vanish, wt ps can no longer see the orphaned server, and wt rm
# still reports success.
new_repo swallowfailrepo
printf 'hooks:\n  server: "true"\n' > worktree-kit.yml
"$WT" new feat/failstop >/dev/null 2>&1
err="$(PATH=/usr/bin:/bin "$WT" rm feat/failstop --force 2>&1 >/dev/null)"
assert_contains "$err" "could not stop the server" \
  "rm: a failed server-stop is reported, not swallowed"

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
"$WT" reset someslug >/dev/null 2>&1
assert_eq "1" "$(test -f "$rstate/someslug.dbready" && echo 0 || echo 1)" \
  "reset: clears the dbready marker"
assert_eq "1" "$(test -f "$rstate/someslug.dbowned" && echo 0 || echo 1)" \
  "reset: clears the dbowned marker too"

# ---------- Task 5: merge ----------

new_repo mergerepo
"$WT" new feat/work >/dev/null 2>&1
wtdir="$TMP/mergerepo-worktrees/feat_work"
( cd "$wtdir" && echo one > one.txt && git add one.txt && git commit -qm "add one" )
( cd "$wtdir" && echo two > two.txt && git add two.txt && git commit -qm "add two" )
pre_merge_head="$(git -C "$wtdir" rev-parse HEAD)"

before="$(git -C "$REPO" rev-parse master)"
"$WT" merge feat/work >/dev/null 2>&1
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
"$WT" new feat/stay >/dev/null 2>&1
( cd "$TMP/mergerepo-worktrees/feat_stay" && echo s > s.txt && git add s.txt && git commit -qm stay )
"$WT" merge feat/stay --no-remove >/dev/null 2>&1
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
"$WT" new feat/conflict >/dev/null 2>&1
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
  "merge: no rebase left in progress"

# guards
new_repo guardrepo
"$WT" new feat/empty >/dev/null 2>&1
assert_fails "merge: refuses a branch with no commits ahead" "$WT" merge feat/empty

"$WT" new feat/dirty >/dev/null 2>&1
( cd "$TMP/guardrepo-worktrees/feat_dirty" && echo d > d.txt && git add d.txt \
    && git commit -qm d && echo x > x.txt )
assert_fails "merge: refuses a dirty worktree" "$WT" merge feat/dirty

"$WT" new feat/ok >/dev/null 2>&1
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
"$WT" new feat/tc >/dev/null 2>&1
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
"$WT" new feat/pushed >/dev/null 2>&1
pdir="$TMP/upstreamrepo-worktrees/feat_pushed"
( cd "$pdir" && echo p > p.txt && git add p.txt && git commit -qm p )
git -C "$pdir" remote add origin "$remote_bare"
git -C "$pdir" push -q origin feat/pushed
git -C "$pdir" branch -q --set-upstream-to=origin/feat/pushed feat/pushed
pushed_head="$(git -C "$pdir" rev-parse HEAD)"
master_before_upstream="$(git -C "$REPO" rev-parse master)"

assert_fails "merge: refuses a branch with an upstream without --force" "$WT" merge feat/pushed
assert_eq "0" "$(test -d "$pdir" && echo 0 || echo 1)" \
  "merge: refused-upstream worktree survives"
assert_eq "$master_before_upstream" "$(git -C "$REPO" rev-parse master)" \
  "merge: refused-upstream master untouched — the guard fires before any rewrite"
assert_eq "$pushed_head" "$(git -C "$pdir" rev-parse HEAD)" \
  "merge: refused-upstream branch untouched — the guard fires before any rewrite"

upstream_before="$(git -C "$REPO" rev-parse master)"
"$WT" merge feat/pushed --force >/dev/null 2>&1
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
"$WT" new feat/incwd >/dev/null 2>&1
wtdir_incwd="$TMP/cwdrepo-worktrees/feat_incwd"
( cd "$wtdir_incwd" && echo w > w.txt && git add w.txt && git commit -qm w )
cwdrepo_repo="$REPO"
out="$( (cd "$wtdir_incwd" && "$WT" merge feat/incwd 2>/dev/null) || true )"
assert_eq "$cwdrepo_repo" "$out" "merge: from inside the worktree, prints the primary for cd"

[ "$FAILED" = 0 ] || { echo "LIFECYCLE FAIL" >&2; exit 1; }
echo "LIFECYCLE PASS"
