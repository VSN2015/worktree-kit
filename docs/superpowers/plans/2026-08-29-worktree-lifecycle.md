# Worktree Lifecycle Commands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `new`, `switch`, `list`, `rm`, `merge`, and `shell-init` to `bin/wt`, so a worktree can be created, found, merged, and fully torn down — reclaiming the server, database, Redis slot, and state files the kit provisioned for it.

**Architecture:** The five lifecycle commands are a peer layer that needs only `git`. `require_config` is split into a soft loader (`load_config_soft`, sets `HAS_CONFIG`) and the existing strict wrapper; the ten existing commands keep the strict wrapper and behave identically. Stdout becomes a dedicated "cd channel" — lifecycle commands print a path there and nothing else, with all human output on stderr, so a shell wrapper can `cd` to it.

**Tech Stack:** POSIX sh (`bin/wt`, one file, `set -eu`). `git` is the only hard dependency of this layer; `fzf` is optional. Tests are linear shell scripts with `grep`/`case` assertions, matching `test/linux-alpine.sh`.

**Spec:** `docs/superpowers/specs/2026-08-29-worktree-lifecycle-design.md`

## Global Constraints

These apply to **every** task. Copied from the spec and CONTEXT.md.

- **One file.** All code goes in `bin/wt`. No `lib/`, no new runtime files. CONTEXT.md §2 rejected `lib/*.sh` for vendoring simplicity.
- **POSIX sh only.** No bashisms in `bin/wt` — it runs under dash and BusyBox ash. No arrays, no `[[`, no `local` (except inside the emitted *user-shell* function in Task 3, which runs in bash/zsh).
- **CONTEXT.md §5 bug 1 — never let a function end with `[ cond ] && cmd`.** Under `set -e` a false condition makes the function return nonzero and kills the caller. Use explicit `if`, or end the function with `true`. This applies to the shell snippets `shell-init` emits, too.
- **CONTEXT.md §7 — word-splitting is load-bearing.** Worktree paths must never contain spaces.
- **Slug derivation is frozen.** `slugify(basename(path))` at `bin/wt:30-36` must not change; it determines existing ports, Redis slots, and database names.
- **Lookup is always `git worktree list --porcelain`,** never a recomputed path template.
- **Stdout is the cd channel.** Only a path, or nothing. Every note, every git subcommand's chatter, every hook's output goes to stderr.
- **Config gating.** Read config only when `HAS_CONFIG=1`; `cfg_get`/`local_get` are not safe to call otherwise.
- **`wt --version` is bumped once, in Task 6.** Do not bump it in earlier tasks.
- **Variable naming.** `bin/wt` has no `local`, so every variable is global. Every new variable in this plan is `_`-prefixed to avoid colliding with `ctx_init`'s globals.

### Two deliberate deviations from the spec

1. **ASCII status markers.** The spec's §9 example shows up/down arrows and an em-dash. Use `+2` / `-1` / `-` instead. BusyBox `printf` and `column` handle multibyte width inconsistently, and the Alpine suite compares column output. Cosmetic only.
2. **The backup ref survives a successful merge.** The spec (§10.2) introduces `refs/wt/premerge/<slug>` for failure recovery. Keeping it after success too costs nothing and is the only undo for a squash plus fast-forward. `wt merge` prints the undo command on success.

---

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `bin/wt` | All implementation. New helpers grouped in a `# ---------- lifecycle ----------` section placed after `worktree_paths()` (line 266) and before `# ---------- ports ----------`. Command functions (`cmd_*`) go with the other `cmd_*` functions. | 1-6 |
| `test/lifecycle.sh` | New. Git-only lifecycle suite: scratch repos in a temp dir, no docker, no YAML backend. Runnable directly on macOS. | 1-6 |
| `test/linux-debian.sh`, `test/linux-alpine.sh` | Modified. Each gains one line invoking `test/lifecycle.sh`. | 1 |
| `templates/{compose,host}/*.yml` | Modified (10 files). Gain a `worktrees:` block and `isolation.db_drop` / `isolation.redis_flush`. | 6 |
| `README.md` | Modified. New commands, shell integration, config reference entries. | 6 |

---

## Task 1: Test harness, soft config loading, and `wt list`

**Files:**
- Create: `test/lifecycle.sh`
- Modify: `bin/wt:53-64` (`require_config` split), `bin/wt:266` (add lifecycle section), `bin/wt:592-628` (usage + dispatch)
- Modify: `test/linux-debian.sh`, `test/linux-alpine.sh` (one line each)

**Interfaces:**
- Consumes: `slugify()`, `local_get()`, `cfg_get()`, `load_config()`, `note()`, `die()`, and the `ctx_init` globals `PRIMARY`, `WT_PATH`, `STATE_DIR`, `PROJECT`, `CONFIG`.
- Produces:
  - `load_config_soft()` — sets `HAS_CONFIG=0|1`; on 1 also sets `RUNNER`, `SERVICE`, `WORKDIR`, `CONTAINER_PORT`, `PREPARE`, `BUILD`, `SERVER_CMD`. Never exits.
  - `require_config()` — unchanged contract: dies when there is no config.
  - `resolve_trunk()` — prints the trunk branch name, or empty.
  - `worktree_for_branch <branch>` — prints the worktree path for a branch, or empty. Exit status is always 0.
  - `worktree_rows()` — prints one TAB-separated row per worktree: `branch  slug  status  server  iso  path`.
  - `TAB` — a global holding a literal tab.

- [ ] **Step 1: Write the failing test**

Create `test/lifecycle.sh`:

```sh
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

git worktree add -q "$TMP/listrepo-wt" -b feat/one
out="$("$WT" list)"
assert_contains "$out" "feat/one"       "list: shows a second worktree"
assert_contains "$out" "feat_one"       "list: slug matches ctx_init derivation"
assert_contains "$out" "clean"          "list: clean worktree reports clean"

echo dirty > "$TMP/listrepo-wt/x.txt"
out="$("$WT" list)"
assert_contains "$out" "dirty"          "list: dirty worktree reports dirty"

git branch -q spare
out="$("$WT" list --all)"
assert_contains "$out" "spare"          "list --all: includes branches with no worktree"
out="$("$WT" list)"
assert_missing  "$out" "spare"          "list: plain list omits branchless branches"

# existing commands must still refuse to run without a config
assert_fails "run still requires config" "$WT" run -- true

[ "$FAILED" = 0 ] || { echo "LIFECYCLE FAIL" >&2; exit 1; }
echo "LIFECYCLE PASS"
```

Make it executable: `chmod +x test/lifecycle.sh`

- [ ] **Step 2: Run test to verify it fails**

Run: `./test/lifecycle.sh`
Expected: FAIL — `wt: unknown command: list`

- [ ] **Step 3: Split `require_config`**

Replace `bin/wt:53-64` entirely with:

```sh
load_config_soft() {
  if [ -f "$CONFIG" ]; then
    HAS_CONFIG=1
    load_config
    RUNNER="$(cfg_get runner compose)"
    SERVICE="$(cfg_get compose.service app)"
    WORKDIR="$(cfg_get compose.workdir /app)"
    CONTAINER_PORT="$(cfg_get hooks.container_port 3000)"
    PREPARE="$(cfg_get hooks.prepare "")"
    BUILD="$(cfg_get hooks.build "")"
    SERVER_CMD="$(cfg_get hooks.server "")"
    if [ "$RUNNER" = compose ]; then need docker; fi
  else
    HAS_CONFIG=0
    RUNNER=""; SERVICE=""; WORKDIR=""; CONTAINER_PORT=3000
    PREPARE=""; BUILD=""; SERVER_CMD=""
  fi
}

require_config() {
  load_config_soft
  if [ "$HAS_CONFIG" = 0 ]; then
    die "no worktree-kit.yml at $PRIMARY — run 'wt init' in that repo"
  fi
}
```

The `need docker` check moves inside the `if`, so a config-less repo never demands docker.

- [ ] **Step 4: Add the lifecycle helpers**

Insert after `worktree_paths()` (currently `bin/wt:266`), under a new banner:

```sh
# ---------- lifecycle ----------

TAB="$(printf '\t')"

resolve_trunk() { # prints the trunk branch name, or empty
  _t=""
  if [ "${HAS_CONFIG:-0}" = 1 ]; then
    _t="$(local_get worktrees.trunk "")"
    if [ -z "$_t" ]; then _t="$(cfg_get worktrees.trunk "")"; fi
  fi
  if [ -z "$_t" ]; then
    _t="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')" || _t=""
  fi
  if [ -z "$_t" ]; then
    if git show-ref --verify --quiet refs/heads/main; then
      _t=main
    elif git show-ref --verify --quiet refs/heads/master; then
      _t=master
    fi
  fi
  printf '%s\n' "$_t"
}

worktree_for_branch() { # <branch> -> path, or empty. Always exits 0.
  git worktree list --porcelain | awk -v b="refs/heads/$1" '
    /^worktree /{ p = $2 }
    $1 == "branch" && $2 == b { print p; exit }
  '
  true
}

# One TAB-separated row per worktree: branch, slug, status, server, iso, path.
# wt list and the picker both read this, so they cannot drift.
worktree_rows() {
  _trunk="$(resolve_trunk)"
  git worktree list --porcelain | awk '
    /^worktree /  { p = $2 }
    /^branch /    { b = $2; sub("refs/heads/", "", b); print p "\t" b }
    /^detached/   { print p "\t(detached)" }
  ' | while IFS="$TAB" read -r _p _b; do
    _s="$(slugify "$_p")"

    _st=clean
    if [ -n "$(git -C "$_p" status --porcelain 2>/dev/null)" ]; then _st=dirty; fi
    if [ -n "$_trunk" ] && git -C "$_p" rev-parse --verify --quiet "$_trunk" >/dev/null 2>&1; then
      _c="$(git -C "$_p" rev-list --left-right --count "$_trunk...HEAD" 2>/dev/null || printf '0\t0')"
      _behind="$(printf '%s' "$_c" | cut -f1)"
      _ahead="$(printf '%s' "$_c" | cut -f2)"
      if [ "${_ahead:-0}"  -gt 0 ]; then _st="$_st +$_ahead"; fi
      if [ "${_behind:-0}" -gt 0 ]; then _st="$_st -$_behind"; fi
    fi

    _srv="-"; _iso="-"
    if [ "${HAS_CONFIG:-0}" = 1 ]; then
      if [ "$RUNNER" = compose ]; then
        _srv="$(docker ps --filter "label=wt.project=$PROJECT" --filter "label=wt.slug=$_s" \
                  --format '{{.Label "wt.port"}}' 2>/dev/null | head -1)"
        _iso="$(docker ps --filter "label=wt.project=$PROJECT" --filter "label=wt.slug=$_s" \
                  --format '{{.Label "wt.isolation"}}' 2>/dev/null | head -1)"
      elif [ -f "$STATE_DIR/$_s.pid" ]; then
        _srv="$(cat "$STATE_DIR/$_s.port" 2>/dev/null || echo '?')"
      fi
    fi
    if [ -n "$_srv" ] && [ "$_srv" != "-" ]; then _srv=":$_srv"; else _srv="-"; fi
    if [ -z "$_iso" ]; then _iso="-"; fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$_b" "$_s" "$_st" "$_srv" "$_iso" "$_p"
  done
  true
}
```

`worktree_rows` ends with `true` — under `set -e` the trailing `while` would otherwise leak its exit status to the caller (CONTEXT.md §5 bug 1).

- [ ] **Step 5: Add `cmd_list`**

Insert alongside the other `cmd_*` functions, before `usage()`:

```sh
cmd_list() {
  load_config_soft
  _all=0
  for _a in "$@"; do
    case "$_a" in
      --all) _all=1 ;;
      *)     die "unknown flag: $_a (wt list [--all])" ;;
    esac
  done

  _out="BRANCH${TAB}SLUG${TAB}STATUS${TAB}SERVER${TAB}ISO${TAB}PATH
$(worktree_rows)"

  if [ "$_all" = 1 ]; then
    for _b in $(git for-each-ref --format='%(refname:short)' refs/heads); do
      if [ -z "$(worktree_for_branch "$_b")" ]; then
        _out="$_out
$_b${TAB}-${TAB}(no worktree)${TAB}-${TAB}-${TAB}-"
      fi
    done
  fi

  if command -v column >/dev/null 2>&1; then
    printf '%s\n' "$_out" | column -t -s "$TAB"
  else
    printf '%s\n' "$_out"
  fi
}
```

- [ ] **Step 6: Wire up dispatch and usage**

In `usage()`, add above the `wt init` line:

```
  wt list [--all]        list worktrees (branch, slug, status, server, isolation)
```

In the dispatch `case`, add before `init)`:

```sh
  list) shift; cmd_list "$@" ;;
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `./test/lifecycle.sh`
Expected: all `ok -` lines, ending `LIFECYCLE PASS`

- [ ] **Step 8: Hook the suite into the linux runs**

In both `test/linux-debian.sh` and `test/linux-alpine.sh`, add immediately before the final `echo "... PASS"` line:

```sh
# lifecycle commands: git only, no docker, no YAML backend
sh /src/test/lifecycle.sh
```

- [ ] **Step 9: Run the linux suites**

Run: `./test/linux.sh`
Expected: `ALL LINUX TESTS PASSED`. If docker is unavailable, run `./test/lifecycle.sh` alone and say plainly that the container suites were not run.

- [ ] **Step 10: Commit**

```bash
git add bin/wt test/lifecycle.sh test/linux-debian.sh test/linux-alpine.sh
git commit -m "wt list: worktree overview, and a config-optional loader"
```

---

## Task 2: `wt new`

**Files:**
- Modify: `bin/wt` (lifecycle section, `cmd_*` section, usage, dispatch)
- Modify: `test/lifecycle.sh` (append a section)

**Interfaces:**
- Consumes: `worktree_for_branch()`, `load_config_soft()`, `HAS_CONFIG`, `PREPARE`, `PRIMARY`.
- Produces:
  - `sanitize_branch <branch>` — prints a filesystem-safe branch name.
  - `path_template()` — prints the worktree path template.
  - `expand_path <template> <raw-branch>` — prints the expanded absolute path.
  - `emit_cd <path>` — prints the path on stdout, plus a stderr hint when shell integration is absent.
  - `cmd_new` — `wt new <branch> [--from <base>] [--server]`.

- [ ] **Step 1: Write the failing test**

Append to `test/lifecycle.sh`, immediately before the final `[ "$FAILED" = 0 ]` line:

```sh
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
cat > worktree-kit.local.yml <<'YML'
worktrees:
  path: "{parent}/has space/{branch}"
YML
assert_fails "new: refuses a path containing a space" "$WT" new anything
assert_eq "1" "$(test -d "$TMP/has space"; echo $?)" "new: nothing created on refusal"
```

The last two assertions need a YAML backend to read the `.local` file. On a machine with none, `path_template` falls back to the default and they will fail — report that in the run rather than weakening the test; every CI image under `test/` installs a backend.

- [ ] **Step 2: Run test to verify it fails**

Run: `./test/lifecycle.sh`
Expected: FAIL — `wt: unknown command: new`

- [ ] **Step 3: Add the path-template helpers**

Append to the `# ---------- lifecycle ----------` section:

```sh
sanitize_branch() { # <branch> -> filesystem-safe
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

path_template() {
  _t=""
  if [ "${HAS_CONFIG:-0}" = 1 ]; then
    _t="$(local_get worktrees.path "")"
    if [ -z "$_t" ]; then _t="$(cfg_get worktrees.path "")"; fi
  fi
  if [ -z "$_t" ]; then _t='{parent}/{repo}-worktrees/{branch}'; fi
  printf '%s\n' "$_t"
}

# {branch_raw} MUST be substituted before {branch}, or the longer token is
# eaten by the shorter one and leaves a stray "_raw".
expand_path() { # <template> <raw-branch>
  _pb="$(sanitize_branch "$2")"
  _pp="$(dirname "$PRIMARY")"
  _pr="$(basename "$PRIMARY")"
  printf '%s' "$1" | sed \
    -e "s|{branch_raw}|$2|g" \
    -e "s|{parent}|$_pp|g" \
    -e "s|{repo}|$_pr|g" \
    -e "s|{branch}|$_pb|g" \
    -e "s|{home}|$HOME|g"
}

# stdout is the cd channel: a path, and nothing else.
emit_cd() { # <path>
  printf '%s\n' "$1"
  if [ -z "${WT_SHELL_INTEGRATION:-}" ]; then
    note "not cd'd — install shell integration: eval \"\$(wt shell-init zsh)\""
  fi
}
```

- [ ] **Step 4: Add `cmd_new`**

```sh
cmd_new() {
  load_config_soft
  _base=""; _start_server=0; _branch=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --from)   _base="${2:-}"; [ -n "$_base" ] || die "--from needs a branch or commit"; shift 2 ;;
      --server) _start_server=1; shift ;;
      -*)       die "unknown flag: $1 (wt new <branch> [--from <base>] [--server])" ;;
      *)        _branch="$1"; shift ;;
    esac
  done
  [ -n "$_branch" ] || die "usage: wt new <branch> [--from <base>] [--server]"

  _existing="$(worktree_for_branch "$_branch")"
  if [ -n "$_existing" ]; then
    die "branch $_branch already has a worktree at $_existing — use: wt switch $_branch"
  fi

  _path="$(expand_path "$(path_template)" "$_branch")"
  case "$_path" in
    *" "*) die "worktrees.path expands to a path containing a space:
  $_path
wt splits unquoted strings when building compose args and host env lists, so
worktree paths must be space-free. Change worktrees.path or the branch name." ;;
  esac
  if [ -e "$_path" ]; then die "$_path already exists"; fi

  mkdir -p "$(dirname "$_path")"
  if git show-ref --verify --quiet "refs/heads/$_branch"; then
    note "adopting existing branch $_branch"
    git worktree add "$_path" "$_branch" >&2
  elif [ -n "$_base" ]; then
    git worktree add -b "$_branch" "$_path" "$_base" >&2
  else
    git worktree add -b "$_branch" "$_path" >&2
  fi

  # Hook output goes to stderr so it cannot pollute the cd channel.
  if [ "$HAS_CONFIG" = 1 ] && [ -n "${PREPARE:-}" ]; then
    note "prepare: $PREPARE"
    if ! ( cd "$_path" && "$0" run --shared -- sh -c "$PREPARE" ) >&2; then
      die "prepare hook failed — worktree left at $_path"
    fi
  fi

  if [ "$_start_server" = 1 ]; then
    if [ "$HAS_CONFIG" = 0 ]; then die "--server needs worktree-kit.yml — run 'wt init'"; fi
    ( cd "$_path" && "$0" server ) >&2 || die "server failed to start in $_path"
  fi

  emit_cd "$_path"
}
```

- [ ] **Step 5: Wire up dispatch and usage**

In `usage()`, above the `wt list` line:

```
  wt new <branch> [--from <base>] [--server]   create a branch + worktree
```

In the dispatch `case`, before `list)`:

```sh
  new) shift; cmd_new "$@" ;;
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `./test/lifecycle.sh`
Expected: `LIFECYCLE PASS`

- [ ] **Step 7: Commit**

```bash
git add bin/wt test/lifecycle.sh
git commit -m "wt new: create or adopt a branch's worktree from a path template"
```

---

## Task 3: `wt switch`, the picker, and `wt shell-init`

**Files:**
- Modify: `bin/wt` (lifecycle section, `cmd_*` section, usage, both dispatch blocks)
- Modify: `test/lifecycle.sh` (append a section)

**Interfaces:**
- Consumes: `worktree_rows()`, `worktree_for_branch()`, `emit_cd()`, `STATE_DIR`, `TAB`.
- Produces:
  - `pick_worktree()` — prints the chosen worktree path on stdout; returns nonzero if the user cancels.
  - `cmd_switch` — `wt switch [<branch>]`.
  - `cmd_shell_init` — `wt shell-init [bash|zsh|fish]`.

- [ ] **Step 1: Write the failing test**

Append to `test/lifecycle.sh`, before the final `[ "$FAILED" = 0 ]` line:

```sh
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./test/lifecycle.sh`
Expected: FAIL — `wt: unknown command: switch`

- [ ] **Step 3: Add the picker**

Append to the `# ---------- lifecycle ----------` section:

```sh
# Prints the selected worktree path. fzf draws on /dev/tty and prints only
# the selection to stdout, so it composes with the cd channel.
pick_worktree() {
  _rows="$(worktree_rows)"
  if [ -z "$_rows" ]; then die "no worktrees"; fi

  if command -v fzf >/dev/null 2>&1; then
    _sel="$(printf '%s\n' "$_rows" | fzf \
      --delimiter="$TAB" --with-nth=1,2,3,4 \
      --preview 'git -C {6} log --oneline -10; echo; git -C {6} status -s' \
      --preview-window=right:60%)" || return 1
  else
    _tmp="$STATE_DIR/.picker.$$"
    printf '%s\n' "$_rows" > "$_tmp"
    _i=0
    while IFS="$TAB" read -r _b _s _st _srv _iso _p; do
      _i=$((_i + 1))
      printf '%2d) %-28s %s\n' "$_i" "$_b" "$_p" >&2
    done < "$_tmp"
    printf 'select worktree [1-%d]: ' "$_i" >&2
    if ! read -r _n < /dev/tty; then rm -f "$_tmp"; return 1; fi
    case "$_n" in
      ''|*[!0-9]*) rm -f "$_tmp"; die "not a number: $_n" ;;
    esac
    if [ "$_n" -lt 1 ] || [ "$_n" -gt "$_i" ]; then rm -f "$_tmp"; die "out of range: $_n"; fi
    _sel="$(sed -n "${_n}p" "$_tmp")"
    rm -f "$_tmp"
  fi

  printf '%s' "$_sel" | cut -f6
}
```

- [ ] **Step 4: Add `cmd_switch` and `cmd_shell_init`**

```sh
cmd_switch() {
  load_config_soft
  if [ $# -eq 0 ]; then
    _p="$(pick_worktree)" || exit 1
    if [ -z "$_p" ]; then exit 1; fi
    emit_cd "$_p"
    return 0
  fi

  _p="$(worktree_for_branch "$1")"
  if [ -z "$_p" ]; then
    if git show-ref --verify --quiet "refs/heads/$1"; then
      die "branch $1 has no worktree — create one: wt new $1"
    fi
    die "no worktree or branch named $1 (see: wt list --all)"
  fi
  emit_cd "$_p"
}

cmd_shell_init() {
  _kind="${1:-}"
  if [ -z "$_kind" ]; then _kind="$(basename "${SHELL:-sh}")"; fi
  case "$_kind" in
    bash|zsh)
      cat <<'EOF'
wt() {
  case "${1:-}" in
    switch|new|rm|merge)
      local __wt_d
      __wt_d="$(WT_SHELL_INTEGRATION=1 command wt "$@")" || return $?
      # explicit if, not &&: a command that prints no path must still return 0
      if [ -n "$__wt_d" ]; then cd "$__wt_d"; fi
      ;;
    *) command wt "$@" ;;
  esac
}
EOF
      ;;
    fish)
      cat <<'EOF'
function wt
  switch "$argv[1]"
    case switch new rm merge
      set -l __wt_d (WT_SHELL_INTEGRATION=1 command wt $argv)
      or return $status
      if test -n "$__wt_d"
        cd $__wt_d
      end
    case '*'
      command wt $argv
  end
end
EOF
      ;;
    *) die "unsupported shell: $_kind (bash, zsh, fish)" ;;
  esac
}
```

- [ ] **Step 5: Wire up dispatch and usage**

In `usage()`, after the `wt new` line:

```
  wt switch [<branch>]   cd to a worktree; no argument opens a picker
```

and after the `wt doctor` line:

```
  wt shell-init [bash|zsh|fish]   emit the shell function that makes switch cd
```

`shell-init` must work outside a git repo, so dispatch it in the **pre-`ctx_init`** case at the top of the file, not the main dispatch:

```sh
case "${1:-}" in
  -h|--help|help|'') usage; exit 0 ;;
  -v|--version) echo "wt $WT_VERSION"; exit 0 ;;
  shell-init) shift; cmd_shell_init "$@"; exit 0 ;;
esac
```

Add only `switch` to the post-`ctx_init` dispatch:

```sh
  switch) shift; cmd_switch "$@" ;;
```

`cmd_shell_init` is defined above that top-level `case` already, since all function definitions precede it.

- [ ] **Step 6: Run the test to verify it passes**

Run: `./test/lifecycle.sh`
Expected: `LIFECYCLE PASS`

- [ ] **Step 7: Verify the wrapper by hand in a real shell**

Run:

```bash
cd /tmp && rm -rf wtdemo && mkdir wtdemo && cd wtdemo && git init -q \
  && git commit -q --allow-empty -m init \
  && eval "$(wt shell-init bash)" && wt new demo && pwd
```

Expected: `pwd` prints `/tmp/wtdemo-worktrees/demo`.

- [ ] **Step 8: Commit**

```bash
git add bin/wt test/lifecycle.sh
git commit -m "wt switch: picker, branch lookup, and shell integration"
```

---

## Task 4: `wt rm`

**Files:**
- Modify: `bin/wt` (lifecycle section, `cmd_*` section, usage, dispatch)
- Modify: `test/lifecycle.sh` (append a section)

**Interfaces:**
- Consumes: `worktree_for_branch()`, `resolve_trunk()`, `emit_cd()`, `expand()`, `runner_exec()`, `cfg_get()`, `slugify()`, `hashnum()`, `STATE_DIR`, `PRIMARY`, `WT_PATH`, `SLUG`, `N`.
- Produces:
  - `teardown_worktree <slug> <path>` — stops the server, drops the database, flushes the Redis slot, clears state files. Never removes the worktree itself. Always returns 0.
  - `remove_worktree_and_branch <branch> <path> <keep_branch 0|1> <force 0|1>`.
  - `confirm <prompt>` — 0 on yes; reads `/dev/tty`, falling back to stdin.
  - `cmd_rm` — `wt rm [<branch>] [--keep-branch] [--force]`.

- [ ] **Step 1: Write the failing test**

Append to `test/lifecycle.sh`, before the final `[ "$FAILED" = 0 ]` line:

```sh
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
assert_eq "0" "$(test -d "$wtdir"; echo $?)" "rm: dirty worktree survives the refusal"
rm "$wtdir/scratch.txt"

# unmerged commits are refused without --force
( cd "$wtdir" && echo c > c.txt && git add c.txt && git commit -qm work )
assert_fails "rm: refuses unmerged commits" "$WT" rm feat/gone

# --force removes it and reclaims every state file
"$WT" rm feat/gone --force >/dev/null 2>&1
assert_eq "1" "$(test -d "$wtdir"; echo $?)"                    "rm --force: worktree gone"
assert_eq "1" "$(test -f "$state/feat_gone.dbready"; echo $?)"  "rm --force: dbready cleared"
assert_eq "1" "$(test -f "$state/feat_gone.port"; echo $?)"     "rm --force: port file cleared"
assert_eq "1" "$(test -f "$state/logs/feat_gone.log"; echo $?)" "rm --force: log cleared"
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
assert_eq "1" "$(test -d "$TMP/rmrepo-worktrees/feat_clean"; echo $?)" \
  "rm: clean merged worktree removed after confirmation"

# answering no leaves everything alone
"$WT" new feat/spared >/dev/null 2>&1
printf 'n\n' | "$WT" rm feat/spared >/dev/null 2>&1 || true
assert_eq "0" "$(test -d "$TMP/rmrepo-worktrees/feat_spared"; echo $?)" \
  "rm: declining the prompt keeps the worktree"
```

The confirmation prompt reads `/dev/tty` when one exists and stdin otherwise; the pipes above exercise the stdin path, which is what runs in CI.

- [ ] **Step 2: Run test to verify it fails**

Run: `./test/lifecycle.sh`
Expected: FAIL — `wt: unknown command: rm`

- [ ] **Step 3: Add the teardown helpers**

Append to the `# ---------- lifecycle ----------` section:

```sh
# Reclaims everything the kit provisioned for a slug. Does NOT touch the
# worktree directory or the branch. Overlays under $OVERLAY_DIR are per-file
# and personal, never per-worktree — they are deliberately left alone.
teardown_worktree() { # <slug> <path>
  _ts="$1"; _tp="$2"

  if [ "${HAS_CONFIG:-0}" = 1 ]; then
    "$0" down "$_ts" >&2 || true

    # expand() reads the globals SLUG and N; borrow them for the target slug
    _old_slug="$SLUG"; _old_n="$N"
    SLUG="$_ts"; N=$(( $(hashnum "$_ts") % 15 + 1 ))

    if [ -f "$STATE_DIR/$_ts.dbready" ]; then
      _drop="$(cfg_get isolation.db_drop "")"
      if [ -n "$_drop" ]; then
        note "dropping database for $_ts"
        runner_exec own_db "$(expand "$_drop")" >&2 || note "db_drop failed — the database may remain"
      else
        note "no isolation.db_drop configured — the database for slug $_ts is left in place"
      fi
    fi

    _flush="$(cfg_get isolation.redis_flush "")"
    if [ -n "$_flush" ]; then
      note "flushing redis db $N for $_ts"
      runner_exec isolated "$(expand "$_flush")" >&2 || note "redis_flush failed — db $N may still hold keys"
    else
      note "no isolation.redis_flush configured — redis db $N is left as is"
    fi

    SLUG="$_old_slug"; N="$_old_n"
  fi

  rm -f "$STATE_DIR/$_ts.pid" "$STATE_DIR/$_ts.port" \
        "$STATE_DIR/$_ts.dbready" "$STATE_DIR/logs/$_ts.log"
  true
}

remove_worktree_and_branch() { # <branch> <path> <keep_branch 0|1> <force 0|1>
  if [ "$4" = 1 ]; then
    git worktree remove --force "$2" >&2
  else
    git worktree remove "$2" >&2
  fi
  if [ "$3" = 0 ]; then
    if [ "$4" = 1 ]; then
      git branch -D "$1" >&2
    else
      git branch -d "$1" >&2
    fi
  fi
  true
}

confirm() { # <prompt> — 0 on yes. Reads /dev/tty, falling back to stdin.
  printf '%s [y/N] ' "$1" >&2
  if [ -r /dev/tty ]; then
    read -r _ans < /dev/tty || _ans=n
  else
    read -r _ans || _ans=n
  fi
  case "$_ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}
```

- [ ] **Step 4: Add `cmd_rm`**

```sh
cmd_rm() {
  load_config_soft
  _force=0; _keep=0; _branch=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--force)    _force=1; shift ;;
      --keep-branch) _keep=1; shift ;;
      -*)            die "unknown flag: $1 (wt rm [<branch>] [--keep-branch] [--force])" ;;
      *)             _branch="$1"; shift ;;
    esac
  done
  if [ -z "$_branch" ]; then _branch="$(git rev-parse --abbrev-ref HEAD)"; fi

  _path="$(worktree_for_branch "$_branch")"
  if [ -z "$_path" ]; then die "no worktree for branch $_branch (see: wt list)"; fi
  if [ "$_path" = "$PRIMARY" ]; then die "refusing to remove the primary checkout at $PRIMARY"; fi

  if [ "$_force" = 0 ]; then
    if [ -n "$(git -C "$_path" status --porcelain)" ]; then
      die "$_branch has uncommitted changes — commit them, or use --force"
    fi
    # Deliberately reachability, not "unpushed": a local-only branch has no
    # upstream, so an unpushed test would refuse every agent worktree.
    _trunk="$(resolve_trunk)"
    if [ -n "$_trunk" ]; then
      _un="$(git -C "$_path" rev-list --count "$_trunk..$_branch" 2>/dev/null || echo 0)"
      if [ "$_un" -gt 0 ]; then
        die "$_branch has $_un commit(s) not in $_trunk — merge them (wt merge $_branch), or use --force"
      fi
    fi
  fi

  _slug="$(slugify "$_path")"
  note "about to remove:"
  note "  worktree  $_path"
  if [ "$_keep" = 0 ]; then note "  branch    $_branch"; fi
  note "  state     $STATE_DIR/$_slug.*"
  if [ "${HAS_CONFIG:-0}" = 1 ] && [ -f "$STATE_DIR/$_slug.dbready" ]; then
    note "  database  provisioned for slug $_slug"
  fi
  if [ "$_force" = 0 ]; then
    confirm "proceed?" || die "aborted"
  fi

  _removed_cwd=0
  if [ "$WT_PATH" = "$_path" ]; then _removed_cwd=1; fi

  teardown_worktree "$_slug" "$_path"
  remove_worktree_and_branch "$_branch" "$_path" "$_keep" "$_force"
  note "removed $_branch"

  if [ "$_removed_cwd" = 1 ]; then emit_cd "$PRIMARY"; fi
}
```

- [ ] **Step 5: Wire up dispatch and usage**

In `usage()`, after the `wt switch` line:

```
  wt rm [<branch>] [--keep-branch] [--force]   tear down and remove a worktree
```

In the dispatch `case`:

```sh
  rm) shift; cmd_rm "$@" ;;
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `./test/lifecycle.sh`
Expected: `LIFECYCLE PASS`

- [ ] **Step 7: Commit**

```bash
git add bin/wt test/lifecycle.sh
git commit -m "wt rm: reclaim the server, database, redis slot, and state files"
```

---

## Task 5: `wt merge`

**Files:**
- Modify: `bin/wt` (`cmd_*` section, usage, dispatch)
- Modify: `test/lifecycle.sh` (append a section)

**Interfaces:**
- Consumes: `worktree_for_branch()`, `resolve_trunk()`, `teardown_worktree()`, `remove_worktree_and_branch()`, `emit_cd()`, `slugify()`, `PRIMARY`, `WT_PATH`.
- Produces: `cmd_merge` — `wt merge [<branch>] [--into <trunk>] [--no-remove] [-m <msg>] [--force]`.

- [ ] **Step 1: Write the failing test**

Append to `test/lifecycle.sh`, before the final `[ "$FAILED" = 0 ]` line:

```sh
# ---------- Task 5: merge ----------

new_repo mergerepo
"$WT" new feat/work >/dev/null 2>&1
wtdir="$TMP/mergerepo-worktrees/feat_work"
( cd "$wtdir" && echo one > one.txt && git add one.txt && git commit -qm "add one" )
( cd "$wtdir" && echo two > two.txt && git add two.txt && git commit -qm "add two" )

before="$(git -C "$REPO" rev-parse master)"
"$WT" merge feat/work >/dev/null 2>&1
after="$(git -C "$REPO" rev-parse master)"

assert_eq "1" "$(test "$before" = "$after"; echo $?)" "merge: master advanced"
assert_eq "1" "$(git -C "$REPO" rev-list --count "$before..$after")" \
  "merge: two commits squashed into one"
assert_contains "$(git -C "$REPO" log -1 --format=%s)" "add one" \
  "merge: subject taken from the first commit"
assert_contains "$(git -C "$REPO" log -1 --format=%B)" "add two" \
  "merge: remaining subjects form the body"
assert_eq "1" "$(test -d "$wtdir"; echo $?)" "merge: worktree removed by default"
assert_contains "$(git -C "$REPO" show-ref)" "refs/wt/premerge/feat_work" \
  "merge: backup ref kept as the undo"

# --no-remove leaves the worktree in place
"$WT" new feat/stay >/dev/null 2>&1
( cd "$TMP/mergerepo-worktrees/feat_stay" && echo s > s.txt && git add s.txt && git commit -qm stay )
"$WT" merge feat/stay --no-remove >/dev/null 2>&1
assert_eq "0" "$(test -d "$TMP/mergerepo-worktrees/feat_stay"; echo $?)" \
  "merge --no-remove: worktree survives"

# a conflicting rebase restores the branch exactly and leaves the worktree alone
new_repo conflictrepo
echo base > f.txt && git add f.txt && git commit -qm base
"$WT" new feat/conflict >/dev/null 2>&1
cdir="$TMP/conflictrepo-worktrees/feat_conflict"
( cd "$cdir" && echo theirs > f.txt && git add f.txt && git commit -qm theirs )
orig="$(git -C "$cdir" rev-parse HEAD)"
echo ours > f.txt && git add f.txt && git commit -qm ours
master_before="$(git -C "$REPO" rev-parse master)"

assert_fails "merge: conflict is an error" "$WT" merge feat/conflict
assert_eq "$orig" "$(git -C "$cdir" rev-parse HEAD)" \
  "merge: branch restored to its pre-squash commit after a conflict"
assert_eq "$master_before" "$(git -C "$REPO" rev-parse master)" \
  "merge: master untouched after a conflict"
assert_eq "0" "$(test -d "$cdir"; echo $?)" "merge: worktree survives a conflict"
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./test/lifecycle.sh`
Expected: FAIL — `wt: unknown command: merge`

- [ ] **Step 3: Add `cmd_merge`**

```sh
cmd_merge() {
  load_config_soft
  _trunk=""; _msg=""; _no_remove=0; _force=0; _branch=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --into)      _trunk="${2:-}"; [ -n "$_trunk" ] || die "--into needs a branch"; shift 2 ;;
      -m)          _msg="${2:-}";   [ -n "$_msg" ]   || die "-m needs a message";   shift 2 ;;
      --no-remove) _no_remove=1; shift ;;
      -f|--force)  _force=1; shift ;;
      -*)          die "unknown flag: $1 (wt merge [<branch>] [--into <trunk>] [--no-remove] [-m <msg>] [--force])" ;;
      *)           _branch="$1"; shift ;;
    esac
  done
  if [ -z "$_branch" ]; then _branch="$(git rev-parse --abbrev-ref HEAD)"; fi

  _path="$(worktree_for_branch "$_branch")"
  if [ -z "$_path" ]; then die "no worktree for branch $_branch (see: wt list)"; fi
  if [ "$_path" = "$PRIMARY" ]; then die "refusing to merge the primary checkout's own branch"; fi

  if [ -z "$_trunk" ]; then _trunk="$(resolve_trunk)"; fi
  if [ -z "$_trunk" ]; then die "cannot determine trunk — pass --into <branch> or set worktrees.trunk"; fi
  if [ "$_trunk" = "$_branch" ]; then die "$_branch is the trunk"; fi

  # ---- guards, before anything is rewritten ----
  if [ -n "$(git -C "$_path" status --porcelain)" ]; then
    die "$_branch has uncommitted changes — commit or stash them first"
  fi
  _ahead="$(git -C "$_path" rev-list --count "$_trunk..$_branch" 2>/dev/null || echo 0)"
  if [ "$_ahead" -eq 0 ]; then die "$_branch has no commits ahead of $_trunk"; fi

  _primary_branch="$(git -C "$PRIMARY" rev-parse --abbrev-ref HEAD)"
  if [ "$_primary_branch" != "$_trunk" ]; then
    die "$_trunk is not checked out at $PRIMARY (found $_primary_branch)"
  fi
  if [ -n "$(git -C "$PRIMARY" status --porcelain)" ]; then
    die "the primary checkout at $PRIMARY is dirty — commit or stash first"
  fi
  if git -C "$_path" rev-parse --verify --quiet "$_branch@{upstream}" >/dev/null 2>&1; then
    if [ "$_force" = 0 ]; then
      die "$_branch has an upstream — squashing rewrites published history; pass --force to proceed"
    fi
  fi

  # ---- backup ref: the undo for everything below ----
  _slug="$(slugify "$_path")"
  _backup="refs/wt/premerge/$_slug"
  _orig="$(git -C "$_path" rev-parse HEAD)"
  git -C "$_path" update-ref "$_backup" "$_orig"
  note "backup: $_backup -> $_orig"

  # ---- squash ----
  _base="$(git -C "$_path" merge-base "$_trunk" "$_branch")"
  if [ -z "$_msg" ]; then
    _subj="$(git -C "$_path" log --format='%s' --reverse "$_base..$_branch" | head -1)"
    _body="$(git -C "$_path" log --format='%s' --reverse "$_base..$_branch" | tail -n +2)"
    if [ -n "$_body" ]; then
      _msg="$_subj

$_body"
    else
      _msg="$_subj"
    fi
  fi
  git -C "$_path" reset --soft "$_base" >&2
  if ! git -C "$_path" commit -q -m "$_msg" >&2; then
    git -C "$_path" reset --hard "$_orig" >&2
    die "squash commit failed — $_branch restored to $_orig"
  fi

  # ---- rebase ----
  if ! git -C "$_path" rebase "$_trunk" >&2; then
    git -C "$_path" rebase --abort >/dev/null 2>&1 || true
    git -C "$_path" reset --hard "$_orig" >&2
    die "rebase of $_branch onto $_trunk hit a conflict — $_branch restored to $_orig
resolve by hand:  git -C $_path rebase $_trunk"
  fi

  # ---- fast-forward trunk ----
  _trunk_before="$(git -C "$PRIMARY" rev-parse "$_trunk")"
  if ! git -C "$PRIMARY" merge --ff-only "$_branch" >&2; then
    git -C "$_path" reset --hard "$_orig" >&2
    die "$_trunk could not fast-forward to $_branch — it moved underneath us; $_branch restored to $_orig"
  fi
  note "merged $_branch into $_trunk"
  note "undo:   git -C $PRIMARY reset --hard $_trunk_before   (branch backup: $_backup)"

  # ---- teardown ----
  if [ "$_no_remove" = 1 ]; then return 0; fi

  _removed_cwd=0
  if [ "$WT_PATH" = "$_path" ]; then _removed_cwd=1; fi
  teardown_worktree "$_slug" "$_path"
  remove_worktree_and_branch "$_branch" "$_path" 0 0
  if [ "$_removed_cwd" = 1 ]; then emit_cd "$PRIMARY"; fi
}
```

- [ ] **Step 4: Wire up dispatch and usage**

In `usage()`, after the `wt rm` line:

```
  wt merge [<branch>] [--into <trunk>] [-m <msg>] [--no-remove] [--force]
                         squash, rebase, fast-forward trunk, then tear down
```

In the dispatch `case`:

```sh
  merge) shift; cmd_merge "$@" ;;
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `./test/lifecycle.sh`
Expected: `LIFECYCLE PASS`

- [ ] **Step 6: Run the linux suites**

Run: `./test/linux.sh`
Expected: `ALL LINUX TESTS PASSED`

- [ ] **Step 7: Commit**

```bash
git add bin/wt test/lifecycle.sh
git commit -m "wt merge: squash, rebase, fast-forward, tear down — with a backup ref"
```

---

## Task 6: `doctor` checks, templates, docs, version bump

**Files:**
- Modify: `bin/wt:571-590` (`cmd_doctor`), `bin/wt:16` (`WT_VERSION`)
- Modify: all ten `templates/{compose,host}/*.yml`
- Modify: `README.md`, `package.json`
- Modify: `test/lifecycle.sh` (append a section)

**Interfaces:**
- Consumes: `path_template()`, `expand_path()`, everything from Tasks 1-5.
- Produces: no new functions.

- [ ] **Step 1: Write the failing test**

Append to `test/lifecycle.sh`, before the final `[ "$FAILED" = 0 ]` line:

```sh
# ---------- Task 6: doctor ----------

new_repo doctorrepo
out="$("$WT" doctor 2>&1)"
assert_contains "$out" "wt path:" "doctor: reports the path template"
assert_contains "$out" "fzf:"     "doctor: reports fzf availability"
assert_contains "$out" "shell:"   "doctor: reports shell integration state"

out="$(WT_SHELL_INTEGRATION=1 "$WT" doctor 2>&1)"
assert_contains "$out" "integration active" "doctor: detects an active wrapper"

# The two template warnings need a YAML backend to read the .local file.
if command -v yq >/dev/null 2>&1 || command -v ruby >/dev/null 2>&1 \
   || python3 -c 'import yaml' >/dev/null 2>&1; then
  cat > worktree-kit.local.yml <<'YML'
worktrees:
  path: "{parent}/{repo}-worktrees/fixed"
YML
  out="$("$WT" doctor 2>&1)"
  assert_contains "$out" "not branch-unique" "doctor: warns on a non-branch-unique template"

  cat > worktree-kit.local.yml <<'YML'
worktrees:
  path: "{parent}/has space/{branch}"
YML
  out="$("$WT" doctor 2>&1)"
  assert_contains "$out" "space" "doctor: warns on a template that yields a space"
  rm -f worktree-kit.local.yml
else
  ok "doctor: template warnings skipped (no YAML backend installed)"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./test/lifecycle.sh`
Expected: FAIL — `doctor: reports the path template`

- [ ] **Step 3: Extend `cmd_doctor`**

Insert immediately after the existing `config:` line in `cmd_doctor`, before the `yaml_backend` call:

```sh
  load_config_soft
  _tmpl="$(path_template)"
  echo "wt path:   $_tmpl"
  _last="${_tmpl##*/}"
  case "$_last" in
    *'{branch}'*|*'{branch_raw}'*) ;;
    *) echo "WARN: worktrees.path's last segment is not branch-unique — every worktree would share a slug, and with it a port, redis slot, and database" ;;
  esac
  _probe="$(expand_path "$_tmpl" wt-doctor-probe)"
  case "$_probe" in
    *" "*) echo "WARN: worktrees.path expands to a path containing a space ($_probe) — wt new will refuse it" ;;
  esac
```

Append before the final `echo "ok"`:

```sh
  if command -v fzf >/dev/null 2>&1; then
    echo "fzf:       $(fzf --version 2>/dev/null | head -1)"
  else
    echo "fzf:       not installed (wt switch falls back to a numbered menu)"
  fi

  if [ -n "${WT_SHELL_INTEGRATION:-}" ]; then
    echo "shell:     integration active"
  else
    _rc_found=""
    for _rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.config/fish/config.fish"; do
      if [ -f "$_rc" ] && grep -q 'wt shell-init' "$_rc" 2>/dev/null; then _rc_found="$_rc"; break; fi
    done
    if [ -n "$_rc_found" ]; then
      echo "shell:     shell-init found in $_rc_found (open a new shell to activate)"
    else
      echo "shell:     unknown — no WT_SHELL_INTEGRATION set and no 'wt shell-init' in your rc files"
    fi
  fi
```

`cmd_doctor` already guards its own config read with `if [ -f "$CONFIG" ]`; the added `load_config_soft` call is safe unconditionally and sets `HAS_CONFIG` for `path_template`.

- [ ] **Step 4: Run the doctor test to verify it passes**

Run: `./test/lifecycle.sh`
Expected: `LIFECYCLE PASS`

- [ ] **Step 5: Add the `worktrees:` block to all ten templates**

Insert into each of `templates/compose/{rails,laravel,node,django,go}.yml` and `templates/host/{rails,laravel,node,django,go}.yml`, immediately after the `runner:` line:

```yaml
# Where `wt new <branch>` puts a new worktree. The LAST path segment becomes
# the slug — and the slug names the port, the redis db {n}, and the database.
# Keep {branch} last. Personal layouts belong in worktree-kit.local.yml.
worktrees:
  path: "{parent}/{repo}-worktrees/{branch}"
  # trunk: master     # optional; what `wt merge` merges into.
                      # Default: origin/HEAD, then main, then master.
```

- [ ] **Step 6: Add `db_drop` and `redis_flush` to all ten templates**

Add both keys to each template's `isolation:` block, **mirroring the client, host, and credentials that template's own `db_bootstrap` already uses**. Where a template declares no `db_bootstrap`, add both keys commented out with the same explanatory comment.

`templates/compose/rails.yml` — append to `isolation:`:

```yaml
  # db_drop (optional): destroys the per-worktree DB. `wt rm` runs it only
  # when the .dbready marker exists — i.e. only for a DB wt itself created.
  # Without this key wt prints the DB name and leaves it in place.
  db_drop: "SKIP_TEST_DATABASE=1 bundle exec rails db:drop"
  # redis_flush (optional): empties this worktree's redis db on `wt rm`.
  redis_flush: "redis-cli -h redis -n {n} flushdb"
```

`templates/host/node.yml` — append to `isolation:`:

```yaml
  # db_drop (optional): destroys the per-worktree DB. `wt rm` runs it only
  # when the .dbready marker exists — i.e. only for a DB wt itself created.
  # Without this key wt prints the DB name and leaves it in place.
  db_drop: "dropdb --if-exists wt_{slug}"
  # redis_flush (optional): empties this worktree's redis db on `wt rm`.
  redis_flush: "redis-cli -n {n} flushdb"
```

Apply the same shape to the remaining eight, matching each one's existing bootstrap and its redis host (`redis` under compose, `localhost` under host):

- **rails host** — `db_drop: "SKIP_TEST_DATABASE=1 bundle exec rails db:drop"`, `redis_flush: "redis-cli -n {n} flushdb"`.
- **laravel** (both) — `db_drop: "php artisan db:wipe --force"`.
- **django** (both) — mirror the template's bootstrap connection: `dropdb --if-exists wt_{slug}` on host, or the same `psql` host and user its bootstrap uses under compose, running `DROP DATABASE IF EXISTS wt_{slug}`.
- **node compose** — `dropdb` against the same host its bootstrap connects to.
- **go** (both) — mirror its bootstrap; if it declares none, add both keys commented out.

Then verify every template still parses:

```bash
for f in templates/compose/*.yml templates/host/*.yml; do
  yq -o=json "$f" > /dev/null || echo "INVALID: $f"
done
```

If `yq` is absent, use `python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$f"`.

- [ ] **Step 7: Update the README**

Add to the command reference, in the style of the existing entries:

- `wt new <branch> [--from <base>] [--server]`
- `wt switch [<branch>]`
- `wt list [--all]`
- `wt rm [<branch>] [--keep-branch] [--force]`
- `wt merge [<branch>] [--into <trunk>] [-m <msg>] [--no-remove] [--force]`
- `wt shell-init [bash|zsh|fish]`

Add a **Shell integration** section showing `eval "$(wt shell-init zsh)"`, and explaining that without it `wt switch` prints a path instead of changing directory.

Add to the config reference: `worktrees.path` (with the last-segment-becomes-the-slug rule and the no-spaces rule), `worktrees.trunk`, `isolation.db_drop`, `isolation.redis_flush`. Note that `worktrees.path` is the natural thing to override in `worktree-kit.local.yml`.

- [ ] **Step 8: Bump the version**

In `bin/wt:16`: `WT_VERSION="0.2.0"`
In `package.json`: `"version": "0.2.0"`

A minor bump, not a patch: this adds six commands.

- [ ] **Step 9: Run everything**

Run: `./test/lifecycle.sh && ./test/linux.sh`
Expected: `LIFECYCLE PASS` then `ALL LINUX TESTS PASSED`

- [ ] **Step 10: Verify the README against the real binary**

Run: `wt --help`
Confirm every command documented in the README appears in `usage()`, and every command in `usage()` is documented in the README.

- [ ] **Step 11: Commit**

```bash
git add bin/wt templates README.md package.json test/lifecycle.sh
git commit -m "wt 0.2.0: doctor checks, template config, and docs for the lifecycle commands"
```

---

## Post-implementation

Release is a separate, manual step and is **not** part of this plan. `wt` is published to npm and has a Homebrew tap; follow the existing release flow, and get explicit approval before any `git push` or `npm publish`.

## Notes for the implementer

- **Read CONTEXT.md before Task 1.** Its §5 lists eight bugs found while building this tool; three of them (1, 7, 8) are traps you can walk straight back into.
- The Alpine suite is the one that matters. BusyBox `ash` is where the `set -e` function-return bug, the mtime-granularity bug, and the process-group bug all surfaced. If you can run only one container suite, run that one.
- `runner_exec` and `expand` read globals (`SLUG`, `N`, `WT_PATH`). `teardown_worktree` borrows and restores `SLUG`/`N` deliberately — do not "clean this up" by passing parameters without also changing `expand`.
