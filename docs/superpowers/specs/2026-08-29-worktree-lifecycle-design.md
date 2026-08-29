# Worktree lifecycle commands for `wt`

**Status:** implemented in worktree-kit 0.2.0. Three places where the
implementation deliberately diverged are marked inline below as RESOLVED
DEVIATION (§6.3 hyphen folding, §10.1 step 5 ownership marker, §10.2 merge
teardown); this document is otherwise the binding design.
**Date:** 2026-08-29
**Base commit:** `fbdf060` (worktree-kit 0.1.8)

## 1. Problem

`wt` today runs things *inside* worktrees that already exist: `run`, `server`,
`up`, `down`, `ps`, `logs`, `localize`, `reset`, `init`, `doctor`. It has no
way to create, find, or destroy a worktree. Users create them by hand with
`git worktree add` (or via Orca), and when they are done they delete the
directory — leaving behind the server, the `wt_<slug>` database, the Redis
slot, and the files under `wt-state/`.

[worktrunk](https://github.com/max-sixty/worktrunk) solves the other half:
`switch`, `list`, `merge`, `remove`, with path templates and an interactive
picker. It is a Rust binary and knows nothing about databases, servers, or
isolation, so its `remove` leaks every resource `wt` provisions.

The two halves are complementary and there is zero command overlap. This
design adds the lifecycle half to `wt`, wired into the isolation machinery
that already exists.

**Name collision, noted and accepted:** worktrunk's binary is also `wt`. The
two cannot be installed side by side. This design proceeds on the assumption
that worktree-kit owns the name for its users.

## 2. Goals

- Create, navigate, list, merge, and destroy worktrees from `wt`.
- Destroying a worktree reclaims *everything* the kit provisioned for it.
- Lifecycle commands work in any git repo, with or without `worktree-kit.yml`.
- Existing worktrees keep their current slug, port, Redis slot, and DB name.
- Stay one POSIX-sh file, one required dependency (`git`), no `lib/`.

## 3. Non-goals

Explicitly out of scope, and not to be added later without a fresh design:

- LLM-generated commit messages.
- CI status columns or AI summaries in `list`.
- `pr:123` checkout syntax and any `gh` dependency.
- Copying build caches (`node_modules`, `target/`) between worktrees.
  CONTEXT.md §5 bug 6 documents why shared dependency directories thrash
  between branch lockfiles. If this is ever revisited it must be an explicit
  opt-in list, never inferred.
- Pushing. `wt merge` is entirely local.
- Restructuring the existing ten commands. The CLI surface is additive; the
  package is published and has a Homebrew tap.

## 4. Architecture: lifecycle as a git-only peer layer

The five new commands require only `git`. They load `worktree-kit.yml` if it
is present and skip config-dependent steps with a one-line note if it is not.

This is the one structural change to existing code:

- `require_config` currently dies when `$CONFIG` is missing.
- Split it into `load_config_soft` (sets `HAS_CONFIG=0|1`, never dies) and
  `require_config` (calls the soft loader, dies when `HAS_CONFIG=0`).
- The ten existing commands keep calling `require_config` and behave
  identically. The five new ones call `load_config_soft`.

Consequence: `wt new` and `wt list` are useful the moment `wt` is installed,
in any repo, which is the adoption path the tool currently lacks — today a
new user must author a YAML file before the tool does anything at all.

## 5. Command surface

```
wt new <branch> [--from <base>] [--server]
wt switch [<branch>]
wt list [--all]
wt rm [<branch>] [--keep-branch] [--force]
wt merge [<branch>] [--into <trunk>] [--no-remove] [-m <msg>] [--force]
wt shell-init [bash|zsh|fish]
```

`new` rather than worktrunk's `switch -c`: the existing surface is imperative
verbs (`up`, `down`, `ps`), and a create flag on a navigate command reads
badly beside them.

Where `<branch>` is optional and omitted, the command acts on the current
worktree — except `switch`, which opens the picker.

**Stdout is the cd channel.** Every lifecycle command prints, on stdout,
either a path the shell should `cd` to or nothing at all. `new` and `switch`
print the target worktree. `rm` and `merge` print the primary checkout **only
when the worktree they removed was the caller's cwd**, and print nothing
otherwise. All human-readable output goes to stderr. This single rule is what
makes the shell wrapper in §8.1 uniform across all four commands.

## 6. Naming and the path model

### 6.1 The constraint

`ctx_init` derives `SLUG` from the **directory basename** (`bin/wt:46`), and
`SLUG` determines:

- the port, via `3000 + cksum(slug) % 900`
- the Redis slot, via `N = cksum(slug) % 15 + 1`
- the database name, via `own_db_env` templates such as `wt_{slug}`
- every `wt-state/<slug>.*` file and the compose container labels

Slug derivation is therefore **not changed by this design**. Changing it
would silently move an existing worktree's port and database — e.g. the
`phase02` worktree on port 3207 with DB `wt_phase02`.

The path template carries the constraint instead: **its last segment becomes
the slug.**

### 6.2 Default template

```
{parent}/{repo}-worktrees/{branch}
```

Branch `feat/refund-flow` produces directory
`<parent>/DepositCloud-worktrees/feat_refund_flow`, slug `feat_refund_flow`,
DB `wt_feat_refund_flow`.

The existing Orca layout (`~/orca/workspaces/DepositCloud/<task>/`) already
satisfies the constraint, so worktrees created outside `wt` keep working and
keep their identity.

A template whose last segment is not branch-unique (e.g. `{repo}.{branch}`,
giving slug `depositcloud_feat_refund_flow`) still functions; it only makes
uglier database names. `wt doctor` warns; it does not forbid.

### 6.3 Template variables

Path templates expand `{parent}` `{repo}` `{branch}` `{branch_raw}` `{home}`.

These are a **separate expansion function** from the existing `expand()`,
because `{slug}`, `{n}`, and `{port}` do not exist yet at create time.

- `{branch}` is sanitized for the filesystem (slashes and other non
  `[A-Za-z0-9._]` characters become `_`).
- `{branch_raw}` is the branch name as git stores it.
- `{parent}` is `dirname` of the primary checkout.
- `{repo}` is the primary checkout's basename, unsanitized.

> **RESOLVED DEVIATION (implementation, 2026-08-29).** This section
> originally specified the keep-set as `[A-Za-z0-9._-]`, i.e. hyphens
> preserved. The implementation's `sanitize_branch` keeps `[A-Za-z0-9._]` and
> folds hyphens too, so that the directory basename equals the slug exactly —
> `slugify` folds hyphens as well, and a mismatch would mean `wt list`'s PATH
> column and its SLUG column disagreed about the same worktree. Branch
> `feat/refund-flow` therefore gives directory *and* slug `feat_refund_flow`.
>
> The invariant is near-total, not total: `.` is kept by `sanitize_branch` but
> folded by `slugify`, so branch `feat.x` yields directory `feat.x` and slug
> `feat_x`. Left as-is — the residual only affects branch names containing a
> dot, and closing it would change the directory names of existing worktrees.

### 6.4 Lookup is always via git

`wt switch`, `wt rm`, and `wt merge` resolve a branch to a path by reading
`git worktree list --porcelain` and matching the branch — **never** by
recomputing the template. This is what makes them work on worktrees created
by Orca, by hand, or under a previous template setting. The template is used
at create time only.

This preserves the CONTEXT.md §2 principle "context from git, not config":
config now says where to *put* a new worktree, but never where to *find* one.

## 7. `wt new`

1. Resolve the target path from the template; **hard error** if the expansion
   contains a space (see §11).
2. If the branch does not exist: `git worktree add -b <branch> <path> <base>`,
   where `<base>` is `--from` or the current HEAD.
3. If the branch exists but has no worktree: **adopt** it —
   `git worktree add <path> <branch>`.
4. If the branch exists and already has a worktree: error, naming the path,
   and point at `wt switch`.
5. If `HAS_CONFIG=1` and `hooks.prepare` is set, run it in the new worktree
   through the configured runner. **Its output is redirected to stderr**, so
   it cannot pollute the cd channel (§5); the hook's exit status is still
   checked and a failure aborts before step 7.
6. With `--server`, invoke the existing `wt server` in the new worktree.
   Off by default — starting servers unasked is noisy past a few worktrees.
7. Print the new path on stdout (so the shell function can `cd` to it).

## 8. `wt switch`, shell integration, and the picker

### 8.1 Shell integration

A process cannot change its parent's directory. `wt switch` prints the
resolved path on **stdout** and everything else on **stderr** — a split the
script already observes, since `note()` and `die()` write to stderr.

`wt shell-init zsh` emits:

```sh
wt() {
  case "${1:-}" in
    switch|new|rm|merge)
      local d; d="$(WT_SHELL_INTEGRATION=1 command wt "$@")" || return
      [ -n "$d" ] && cd "$d" ;;
    *) command wt "$@" ;;
  esac
}
```

Installed with `eval "$(wt shell-init zsh)"` in the user's rc file. `bash` is
identical; `fish` needs its own syntax.

Without the wrapper, `wt switch feat/x` still prints the path and adds a
stderr hint about `shell-init`. `WT_SHELL_INTEGRATION=1` suppresses the hint.

### 8.2 Picker

`wt switch` with no argument opens a picker.

- With `fzf`: rows from the shared row-builder (§9), preview pane running
  `git -C <path> log --oneline -10` and `git -C <path> status -s`. fzf draws
  on `/dev/tty` and prints only the selection to stdout, so it composes
  correctly with the shell wrapper.
- Without `fzf`: a numbered menu reading from `/dev/tty`.

`fzf` is strictly optional. `doctor` reports whether it is present; nothing
requires it. `git` remains the only hard dependency of the lifecycle layer.

## 9. `wt list`

`wt list` and the picker share **one row-builder function**, so their
contents cannot drift.

```
BRANCH            SLUG              STATUS        SERVER  ISO      PATH
master            depositcloud      clean         —       —        ~/Projects/DepositCloud
feat/refund-flow  feat_refund_flow  dirty ↑2      :3207   own_db   ~/orca/…/refund
spike/cache       spike_cache       clean ↓1      —       —        ~/orca/…/cache
```

- BRANCH, PATH: from `git worktree list --porcelain`.
- SLUG: `slugify(basename(path))`, i.e. exactly what `ctx_init` would derive.
- STATUS: `git -C <path> status --porcelain` for dirty/clean, plus
  `git -C <path> rev-list --left-right --count <trunk>...HEAD` for ahead
  and behind counts. Two git calls per worktree; acceptable at this scale.
- SERVER, ISO: the same sources `wt ps` uses — docker labels
  (`wt.slug`, `wt.port`, `wt.isolation`) for the compose runner, `wt-state`
  pidfiles and portfiles for the host runner. Both show `—` when
  `HAS_CONFIG=0`.
- `--all` additionally lists local branches that have no worktree, so the
  picker doubles as "what could I check out?".

## 10. `wt rm` and `wt merge`

### 10.1 `wt rm [<branch>] [--keep-branch] [--force]`

Order, each step skipped with a note when it does not apply:

1. Resolve branch → path. **Refuse** if it is the primary checkout.
2. **Refuse** on uncommitted changes, or on commits not reachable from trunk,
   unless `--force`. Deliberately *not* "unpushed commits": a local-only
   branch has no upstream, so every commit would count as unpushed and `rm`
   would refuse for exactly the agent workflow this exists to serve. The
   reachability test is the same question `git branch -d` asks in step 8.
3. Print everything that will be destroyed; prompt once. `--force` skips the
   prompt.
4. Stop the server (the existing `wt down` path for this slug).
5. Drop the database — **only if `wt-state/<slug>.dbowned` exists**, i.e.
   only a database the kit itself provisioned.

   > **RESOLVED DEVIATION (implementation, 2026-08-29).** This step
   > originally gated on `.dbready`, but `.dbready` does not mean what the
   > step needs: `ensure_own_db` writes it on *both* paths — after
   > `db_bootstrap` creates a database, and after `db_check` merely finds one
   > that already existed. Gating on it would let `wt rm` drop a
   > pre-existing, possibly shared database the kit never created. A second
   > marker, `.dbowned`, is written only on the `db_bootstrap` path, and the
   > drop gates on that. `wt reset` clears both.
   >
   > Two consequences, both accepted as the safe direction: databases
   > bootstrapped before 0.2.0 have no `.dbowned` (the marker did not exist)
   > and are left in place with a notice; and a database re-adopted via
   > `db_check` after a `wt reset` is likewise never dropped.
6. Flush the Redis slot `{n}`.
7. Remove `wt-state/<slug>.pid`, `.port`, `.dbready`, and `logs/<slug>.log`.
8. `git worktree remove <path>`, then `git branch -d <branch>` unless
   `--keep-branch`. `-d`, not `-D`: an unmerged branch refuses removal.
   `--force` upgrades to `-D`.

Steps 5 and 6 require new config keys (§12). **If they are absent, `wt rm`
prints the database name and Redis slot it is leaving behind and names the
key to add.** The core never guesses a `DROP DATABASE` — it is stack-agnostic
by design (CONTEXT.md §2) and cannot tell MySQL from Postgres.

Overlays under `<git-common>/local/` are per-file and personal, not
per-worktree. `wt rm` never touches them.

### 10.2 `wt merge [<branch>] [--into <trunk>] [--no-remove] [-m <msg>] [--force]`

Trunk resolution: `--into`, else `worktrees.trunk`, else the branch behind
`refs/remotes/origin/HEAD`, else `main`, else `master`.

Happy path: squash → rebase onto trunk → fast-forward trunk → §10.1 teardown
(unless `--no-remove`).

> **RESOLVED DEVIATION (implementation, 2026-08-29).** "Full §10.1 teardown"
> is not what merge does, and §10.1 step 3 mandates a prompt that merge never
> shows. Concretely, `wt merge` runs the §10.1 *resource* reclaim (steps 4–7:
> server, database, redis slot, state files) and then removes the worktree
> with the **`--force`** variant of step 8 — `git worktree remove --force`
> plus `git branch -D` — with **no confirmation prompt at any point**.
>
> Both are deliberate. `-D` rather than `-d`: the `--ff-only` merge that just
> succeeded *proved* every commit on the branch is reachable from trunk, so
> `-d`'s own merge check is redundant and can misfire (a branch with a stale
> upstream tracking ref is merged to HEAD but not to that upstream, and `-d`
> refuses on that alone) — failing there would strand the user after trunk has
> already advanced and teardown has already run. `--force` on the worktree
> removal follows from the same call: merge already refused earlier on a dirty
> worktree, and teardown itself can leave files behind between that check and
> the removal.
>
> The user-visible cost is that `wt merge` deletes the worktree directory
> including gitignored files, without asking. That is documented in the
> README's `wt merge` section rather than softened here.

The safety rules matter more than the happy path:

- **Backup ref first.** Before anything rewrites history, write
  `refs/wt/premerge/<slug>` at the worktree's current HEAD. Every failure
  path prints the exact command to restore from it. This is what makes the
  command trustworthy.
- **Refuse** if the worktree is dirty.
- **Refuse** if the branch has no commits ahead of trunk.
- **Refuse** if the primary checkout (where trunk is checked out) is dirty.
- **Squash** with `git reset --soft $(git merge-base <trunk> HEAD)` followed
  by a commit. Default message: the first commit's subject, with the
  remaining subjects as the body. `-m` overrides. No LLM, no editor.
- **Rebase** onto trunk. On conflict: `git rebase --abort`, restore from the
  backup ref, leave the worktree exactly as found, exit nonzero with
  instructions. A half-merged state is never left behind.
- **Merge with `--ff-only`.** Having just rebased, anything other than a
  fast-forward means trunk moved underneath us — refuse rather than silently
  create a merge commit.
- **Never push.**
- If the branch has an upstream, squashing rewrites published history —
  **warn and require `--force`**.

## 11. Error handling

Driven by the bug list in CONTEXT.md §5:

- **No new function may end with `[ cond ] && cmd`.** Under `set -e` a false
  condition makes the function return nonzero and kills the caller — bug 1,
  which broke every host-runner repo. Use explicit `if`, or end with `true`.
- **A path template expanding to a path containing a space is a hard error**
  at create time, printing the offending expansion. CONTEXT.md §7 records
  that word-splitting is load-bearing in compose args and host `env` lists;
  this converts a latent corruption into an upfront message.
- Branch names keep slashes for git and are sanitized for the directory.
- Every destructive step names what it is about to destroy before doing it.

## 12. Config schema additions

```yaml
worktrees:
  path: "{parent}/{repo}-worktrees/{branch}"  # last segment becomes the slug
  trunk: master                                # optional; else origin/HEAD

isolation:
  db_drop: "mysql -hmysql -uroot -e 'DROP DATABASE IF EXISTS wt_{slug}'"
  redis_flush: "redis-cli -n {n} flushdb"
```

- `worktrees.path` resolves `local_get` → `cfg_get` → built-in default,
  matching how ports and isolation already layer. Personal layouts (Orca)
  belong in `worktree-kit.local.yml`; the committed file carries the team
  default.
- `worktrees.trunk` is optional.
- `isolation.db_drop` and `isolation.redis_flush` are optional and run through
  the configured runner with own-db isolation env, symmetric with the
  existing `db_check` and `db_bootstrap`.
- The config cache dumper flattens the whole file, so these keys need **no
  cache changes** — they are read with the existing `cfg_get` / `local_get`.
- All ten templates under `templates/{compose,host}/` gain both blocks,
  commented in the style of the existing keys.

## 13. `wt doctor` additions

1. Warn when the path template's last segment is not branch-unique.
2. Warn when the template would produce a path containing a space.
3. Report whether `fzf` is present.
4. Report whether shell integration is installed. A child process cannot
   inspect its parent shell's functions, so the check is twofold: honour
   `WT_SHELL_INTEGRATION` if the wrapper exported it, otherwise grep the
   user's rc files (`~/.zshrc`, `~/.bashrc`, `~/.bash_profile`,
   `~/.config/fish/config.fish`) for `wt shell-init`. Report "unknown"
   rather than "missing" when neither is conclusive.

## 14. Testing

The five lifecycle commands need only `git`, so they test against a scratch
repo with no docker and run in all three existing suites — macOS,
`test/linux-debian.sh`, `test/linux-alpine.sh`.

Cases:

1. `new` — asserts the created path, the branch, and that the resulting slug
   matches what `ctx_init` derives from the directory basename.
2. `new` adopting an existing branch that has no worktree.
3. `new` on a branch that already has a worktree — asserts the error.
4. `list` — column contents, including a worktree with no config.
5. `switch` — a bare path on stdout, hints on stderr, exit status.
6. `merge` — happy path, asserting the squashed commit and fast-forwarded
   trunk.
7. **`merge` with a deliberate conflict** — asserts the backup ref restores
   the pre-squash state exactly and the worktree is untouched.
8. `rm` — asserts no `wt-state` residue for the slug.
9. Path template containing a space — asserts the hard error.

Alpine coverage matters most: BusyBox ash is where bugs 1, 7, and 8 all
surfaced.

## 15. Estimated size

Roughly 450–500 lines added to `bin/wt`, taking it from 628 to about 1100.
CONTEXT.md §2 rejected `lib/*.sh` for vendoring simplicity; that decision
stands, and `install.sh` remains a single symlink.

## 16. Deferred

- `wt merge --pr` (verify an upstream PR merged via `gh`, then clean up).
  Rejected for v1 to keep merge's code and test matrix small; merge is the
  command most able to destroy work.
- Build-cache copying between worktrees (§3).
- Any resolution of the `wt` binary name collision with worktrunk.
