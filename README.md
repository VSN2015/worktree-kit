# worktree-kit

`wt` runs commands and app servers for git worktrees, so many branches of one
repo can run side by side without collisions. It is stack-agnostic: the core
executes only commands that each repo declares in a `worktrees.yml`.

## Why

Parallel agent/branch work with git worktrees hits three walls:

1. Docker compose mounts only the primary checkout, so `docker exec` runs the
   wrong code for a worktree.
2. Servers fight over ports.
3. Branches share one database, one Redis, one job queue.

`wt` fixes all three: per-worktree containers (or host processes), stable
auto-assigned ports, and opt-in isolation (own Redis DB number, own database).

## Install

```sh
git clone <this repo> && cd worktree-kit && ./install.sh
brew install yq        # the one dependency (plus docker for compose repos)
```

## Per-repo setup

```sh
cd your-repo && wt init      # detects the stack, writes worktrees.yml
```

Edit `worktrees.yml` (committed; no secrets) — see `templates/` for the schema.
Optional per-user pins go in `worktrees.local.yml` (gitignore it):

```yaml
servers:
  my-task: { port: 3005, isolation: own-db }
```

## Daily use

```sh
wt run bundle exec rspec spec/models/foo_spec.rb   # one-off in this worktree
wt server            # this worktree's server: auto port + auto isolation
wt up                # servers for every worktree
wt ps / wt logs / wt down
wt localize config/database.yml   # personal overlay (see below)
wt doctor            # checks, including stale overlays
```

## Concepts

- **Auto everything**: worktrees come from `git worktree list`; the port is a
  stable hash of the worktree name bumped to a free one; isolation escalates
  to `own-db` automatically when the worktree has migration files the primary
  lacks (`isolation.migration_paths`). CLI flags > `worktrees.local.yml` > auto.
- **Isolation levels**: `shared` (nothing), `isolated` (applies
  `isolation.isolated_env`, e.g. a per-worktree Redis DB `{n}`), `own_db`
  (adds `own_db_env`, e.g. `DEV_DATABASE=wt_{slug}`, and runs `db_bootstrap`
  once; `wt reset` re-arms it). Your app config must honor those env vars.
- **Overlays**: personal versions of tracked files live under
  `<repo>/.git/local/` (git can never commit them) and mount read-only over
  the container's copy. Overlays are snapshots — re-run `wt localize` after
  editing the source file; `wt doctor` flags stale ones.
- **Template variables** usable in hooks and env values: `{slug}` (worktree
  name), `{n}` (stable 1–15), `{port}`, `{container_port}`, `{project}`.
- **Runners**: `compose` (one-off containers on your existing compose stack)
  or `host` (plain processes with the env vars exported).

## Caveats

- A shared test database stays shared — run one suite at a time, or point
  test config at a per-worktree name the same way as `own_db_env`.
- With `runner: compose`, jobs enqueued under `--isolated` need a worker
  started with the same flag; the main stack's worker only sees its own Redis.
- Rails ≤ 7: a bare `db:schema:load` in development also reloads the TEST
  database — keep `SKIP_TEST_DATABASE=1` in `db_bootstrap` (templates do).
