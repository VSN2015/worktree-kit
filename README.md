<div align="center">

# worktree-kit

**Every branch of your repo, running side by side — each git worktree with
its own server, port, Redis slot, and database.**

[![test](https://github.com/VSN2015/worktree-kit/actions/workflows/test.yml/badge.svg)](https://github.com/VSN2015/worktree-kit/actions/workflows/test.yml)
[![npm](https://img.shields.io/npm/v/worktree-kit?logo=npm&color=cb3837)](https://www.npmjs.com/package/worktree-kit)
[![homebrew](https://img.shields.io/badge/homebrew-VSN2015%2Ftap-fbb040?logo=homebrew&logoColor=white)](https://github.com/VSN2015/homebrew-tap)
[![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-5b8dbe)](#install)
[![runtime deps](https://img.shields.io/badge/runtime%20deps-none-2ea44f)](#install)
[![license](https://img.shields.io/github/license/VSN2015/worktree-kit?color=blue)](LICENSE)

[Features](#features) · [Why](#why) · [Install](#install) · [Quick start](#quick-start) · [Commands](#commands-at-a-glance) · [Setup](#per-repo-setup) · [Config](#config-reference) · [Stack guides](#stack-guide-rails-on-docker-compose) · [Caveats](#caveats)

</div>

---

`wt` turns git worktrees into complete, isolated development environments,
from one POSIX-sh file. Create a branch and its worktree in one step. Start
its server and it gets a stable port and its own database without being
asked. Run the test suite in five worktrees at once without them clobbering
each other. When the branch is done, one command squashes, merges, and
reclaims everything it used: server, database, Redis slot, worktree, and
branch.

It exists so that many branches, and many coding agents, can work on one
repo at the same time without stepping on each other. The core is
stack-agnostic and only runs commands your repo declares in a
`worktree-kit.yml`; templates for Rails, Laravel, Django, Node, and Go, on
Docker Compose or the bare host, get you there with one `wt init`.

```sh
$ wt new feat/refund-flow --server
wt: feat_refund_flow [isolated] -> http://localhost:3412  (logs: wt logs feat_refund_flow)

$ wt run --isolated bundle exec rspec spec/     # this branch, in its own test database

$ wt merge                                      # squash → rebase → fast-forward trunk → tear down
wt: backup: refs/wt/premerge/feat_refund_flow -> 9f1c2ab
wt: merged feat/refund-flow into master
wt: undo:   git -C /Users/you/code/myapp reset --hard 4e0d7c1   (branch backup: refs/wt/premerge/feat_refund_flow)
```

## Features

<table>
<tr>
<td width="50%" valign="top">

**🌳 The whole worktree lifecycle**

`wt new` creates a branch and its worktree from a path template and runs your
prepare hook. `wt switch` hops between worktrees through an `fzf` picker with
a live log-and-status preview. `wt list` shows every worktree with its git
status, running server, and isolation level. `wt rm` and `wt merge` tear one
down and reclaim everything it used.

</td>
<td width="50%" valign="top">

**🚀 A server per branch, no port juggling**

`wt server` starts this worktree's app detached and prints its URL. The port
is a stable hash of the worktree name, so every branch keeps the same URL
across restarts, and a busy port slides to the next free one. `wt up` starts
every worktree at once; `wt ps`, `wt logs`, and `wt down` run the fleet.

</td>
</tr>
<tr>
<td valign="top">

**🔒 Three isolation levels, chosen for you**

`shared` uses the primary's everything. `isolated` gives the worktree its own
Redis DB number and its own test database. `own_db` adds a private dev
database, created and loaded once on first use. Servers pick a level
automatically and escalate to `own_db` the moment a branch adds a migration
the primary lacks. A flag or a per-user pin overrides any of it.

</td>
<td valign="top">

**🧪 Test suites in parallel**

Every worktree gets its own test database at `--isolated`, so `rspec`,
`phpunit`, `pytest`, `jest`, and `go test` can run in every branch at the
same time. No more schema reloads from another branch landing mid-run.

</td>
</tr>
<tr>
<td valign="top">

**🐳 Docker Compose or bare host, same config**

The compose runner mounts the worktree over your service's checkout in a
one-off container, so `docker` finally runs the branch's code instead of the
primary's. The host runner runs plain processes with the isolation env
exported. Switch between them with one key in the config.

</td>
<td valign="top">

**🧩 Stack templates, stack-agnostic core**

`wt init` detects Rails, Laravel, Django, Node, or Go and writes a working
`worktree-kit.yml`. The core has no framework knowledge: it only runs the
hooks you declare, so Elixir, Rust, plain PHP, or a static-site build are one
copied template away.

</td>
</tr>
<tr>
<td valign="top">

**📎 Personal files follow you into every worktree**

`wt localize` snapshots your tweaked `database.yml` or `development.rb` and
mounts it read-only into every container. `wt link` symlinks gitignored
folders that live only in the primary, such as a repo-local `.claude/`, into
every worktree, and `wt new` does it for you.

</td>
<td valign="top">

**🛡️ Safe by default**

`wt rm` refuses a dirty or unmerged worktree and asks before deleting.
`wt merge` writes a backup ref before rewriting a single commit and restores
the branch on any conflict, with the undo command printed. A database is
dropped only when wt created it; anything it merely found is left alone.

</td>
</tr>
<tr>
<td valign="top">

**⚡ Zero dependencies, millisecond startup**

One POSIX `sh` file, on macOS and Linux. YAML is read by whatever is already
on your machine (`yq`, `ruby`, or `python3`) and cached as shell variables,
so everyday commands spawn no interpreter at all. CI runs the suite on Debian
and Alpine.

</td>
<td valign="top">

**🐚 Shell integration that actually changes directory**

`eval "$(wt shell-init zsh)"` (or `bash`, or `fish`) makes `new`, `switch`,
`rm`, and `merge` land you in the right worktree. `wt doctor` checks the
whole setup: config, runner, YAML backend, docker, the worktree path
template, links, overlays, `fzf`, and whether that integration is live.

</td>
</tr>
</table>

## Why

Parallel work on one repo — several branches, several coding agents, or both
— runs into the same four walls:

1. **Docker runs the wrong code.** Compose mounts only the primary checkout,
   so `docker exec` in a worktree silently runs the primary's code.
2. **Servers fight over ports.** Every branch wants `:3000`.
3. **Branches share one everything.** One database, one Redis, one job
   queue. A migration on one branch breaks every other; a spec run on one
   branch reloads the schema under another.
4. **Worktrees are a chore.** `git worktree add`, `cd`, install deps, find a
   free port, remember which database belongs to which branch, and later
   remove the worktree, delete the branch, and drop the database you forgot.

`wt` takes down all four: per-worktree containers or processes running the
right code, stable auto-assigned ports, opt-in isolation with its own Redis
DB and database, and a lifecycle that creates and reclaims all of it with
one command each.

## Install

```sh
# macOS or Linux, with Homebrew
brew install VSN2015/tap/worktree-kit

# with npm (or try it one-off: npx worktree-kit doctor)
npm install -g worktree-kit

# any Linux (or macOS) without Homebrew or npm — downloads the latest release
curl -fsSL https://raw.githubusercontent.com/VSN2015/worktree-kit/master/install.sh | sh
```

or from source:

```sh
git clone https://github.com/VSN2015/worktree-kit && cd worktree-kit && ./install.sh
```

wt is POSIX sh and runs on macOS and Linux (tested on glibc/Debian and
musl/Alpine). There are usually no dependencies to install: it reads its
YAML config with whichever of yq, ruby, or python3 + PyYAML is already on
your PATH (macOS ships ruby; `wt doctor` shows which one is in use), and
checks ports with lsof, ss, or a ruby/python bind probe — whichever exists.
The YAML reader only runs when the config changes — wt caches the parsed
config under `.git/wt-state/` and sources it, so everyday commands start
in milliseconds with no interpreter spawns. Compose repos additionally
need docker.

## Quick start

```sh
# 1. once per repo: detect the stack, write worktree-kit.yml, check the setup
cd ~/code/myapp
wt init && wt doctor

# 2. once per machine: let wt cd your shell (bash, zsh, or fish)
echo 'eval "$(wt shell-init zsh)"' >> ~/.zshrc && exec zsh

# 3. a branch, its worktree, and its server in one step
wt new feat/login --server
#    -> ~/code/myapp-worktrees/feat_login   http://localhost:3xxx   [isolated]

# 4. work on it: the suite on this branch, in this branch's own test database
wt run --isolated bin/rails db:test:prepare      # once per worktree
wt run --isolated bundle exec rspec spec/

# 5. see everything, hop around
wt list
wt switch                                        # fzf picker over every worktree

# 6. done: squash into one commit, rebase, fast-forward master, reclaim everything
wt merge
```

> [!NOTE]
> The one manual step per stack: your app has to read the env vars wt exports
> (a one-line change in `database.yml`, `settings.py`, or the like). The
> [stack guides](#stack-guide-rails-on-docker-compose) show it for each
> framework, and the template `wt init` writes names the variables.

## Commands at a glance

| command                                                                   | what it does                                              |
|---------------------------------------------------------------------------|-----------------------------------------------------------|
| [`wt new <branch> [--from <base>] [--server]`](#wt-new--create-a-branch--worktree) | create a branch + worktree, optionally start its server |
| [`wt switch [<branch>]`](#wt-switch--jump-to-a-worktree)                  | cd to a worktree; no argument opens a picker              |
| [`wt list [--all]`](#wt-list--see-every-worktree)                         | every worktree: branch, slug, status, server, isolation   |
| [`wt rm [<branch>] [--keep-branch] [--force]`](#wt-rm--tear-down-a-worktree) | tear down and remove a worktree                        |
| [`wt merge [<branch>] [--into <trunk>] [-m <msg>] [--no-remove] [--force]`](#wt-merge--squash-rebase-fast-forward-tear-down) | squash, rebase, fast-forward trunk, then tear down |
| [`wt run [flags] [--] <cmd...>`](#wt-run--one-off-commands)               | one-off command in this worktree                          |
| [`wt server [flags] [port]`](#wt-server--this-worktrees-server)           | start this worktree's server, detached                    |
| [`wt up [flags] [slug...]`](#wt-up--everything-at-once)                   | start servers for all (or the named) worktrees            |
| [`wt down [slug...]`](#wt-down--stop-servers)                             | stop servers — all of them, or the named ones             |
| [`wt ps`](#wt-ps--whats-running)                                          | list running worktree servers                             |
| [`wt logs [slug]`](#wt-logs--follow-a-server)                             | follow a server's logs                                    |
| [`wt localize <file...>`](#wt-localize--personal-overlays)                | snapshot a personal overlay (`--list` / `--remove`)       |
| [`wt link [--all \| slug...]`](#wt-link--host-visible-symlinks)           | symlink `links:` paths from the primary into worktrees    |
| [`wt reset [slug]`](#wt-reset--re-bootstrap-an-own-db-worktree)           | clear the own-db bootstrap marker                         |
| [`wt init`](#wt-init--wt-doctor--setup-and-checks)                        | write `worktree-kit.yml` from a stack template            |
| [`wt doctor`](#wt-init--wt-doctor--setup-and-checks)                      | environment + config checks                               |
| [`wt shell-init [bash\|zsh\|fish]`](#shell-integration)                   | emit the shell function that makes `switch`/`new`/`rm`/`merge` cd |

The isolation flags `--shared` / `--isolated` / `--own-db` work on `run`,
`server`, and `up`; the [isolation](#isolation) section covers what each
level exports. `wt --help` prints this summary and `wt --version` the
version; both work outside a git repo.

## Per-repo setup

```sh
cd your-repo && wt init      # detects the stack, writes worktree-kit.yml
```

`wt init` picks the stack by marker file (checked in this order) and the
runner by whether a compose file (`docker-compose.yml` / `compose.yml`, or
the `.yaml` spellings) sits at the repo root. Every stack ships in both
flavors — `templates/compose/<stack>.yml` and `templates/host/<stack>.yml`:

| marker file    | stack   |
|----------------|---------|
| `Gemfile`      | rails   |
| `artisan`      | laravel |
| `package.json` | node    |
| `manage.py`    | django  |
| `go.mod`       | go      |

(`artisan` is checked before `package.json` because Laravel repos also carry
one.) The template is a starting point: read the reference below, fix the few
values that don't match your repo, make your app config read the isolation
env vars (the one manual step — see the stack guides), then run `wt doctor`.

> [!TIP]
> Commit `worktree-kit.yml` — it holds no secrets.

The files in `templates/` are references, not the limit — `wt` is
stack-agnostic and only ever runs the commands your config declares, so any
stack (PHP without Laravel, Elixir, Rust, a static-site build, …) works:
copy the closest template to `worktree-kit.yml` at your repo root and swap in
your own commands. When `wt init` can't detect a stack, it says exactly that.
A template for a new stack is also all it takes to extend detection —
PRs welcome.

## Config reference

The compose Rails template (`templates/compose/rails.yml`), annotated. The
other templates are subsets of the same schema — host variants drop the
`compose`/`volumes`/`mounts` keys entirely. Every key has a default or can
be omitted; `wt server` needs `hooks.server`, and everything else degrades
gracefully.

```yaml
version: 1              # schema version; reserved, not read today
runner: compose         # compose | host — how commands run (default: compose)

worktrees:
  path: "{parent}/{repo}-worktrees/{branch}"   # last segment becomes the slug
  # trunk: master                              # optional; what `wt merge` targets

compose:                # read only when runner: compose
  service: app          # docker-compose.yml service whose image runs your code
  workdir: /app         # where that image expects the checkout

volumes:                # named docker volumes added to every wt container
  - name: "{project}_wt_cache"
    path: /usr/local/bundle

mounts:
  read_only: [node_modules]   # dirs mounted read-only from the primary checkout

links: [.claude]        # gitignored paths symlinked from the primary into every worktree

hooks:
  prepare: "bundle check >/dev/null 2>&1 || bundle install --jobs=4 --retry=3"
  build: "yarn build"
  server: "rm -f tmp/pids/server.pid && bundle exec rails s -b 0.0.0.0 -p {container_port}"
  container_port: 3000

isolation:
  isolated_env:               # env exported at --isolated and --own-db
    REDIS_URL: "redis://redis:6379/{n}"
    TEST_DATABASE: "wt_{slug}_test"
  own_db_env:                 # env exported only at --own-db
    DEV_DATABASE: "wt_{slug}"
  db_check: "bundle exec rails runner \"ActiveRecord::Base.connection.execute('SELECT 1 FROM schema_migrations LIMIT 1')\""
  db_bootstrap: "SKIP_TEST_DATABASE=1 bundle exec rails db:create db:schema:load"
  migration_paths: [db/migrate]
  db_drop: "SKIP_TEST_DATABASE=1 bundle exec rails db:drop"
  redis_flush: "redis-cli -h redis -n {n} flushdb"
```

### runner

- **`compose`** — every `wt run` / `wt server` is a one-off
  `docker compose run --rm` container on your existing compose project, with
  the worktree mounted over `compose.workdir` in place of the primary
  checkout. That mount is the whole trick: the container runs the worktree's
  code. Your normal `docker compose up` stack should already be running so
  services like the database and Redis are reachable; wt never touches it.
- **`host`** — plain processes on your machine, started in the worktree
  directory with the isolation env vars exported. `wt server` daemonizes with
  nohup and tracks a pidfile under `.git/wt-state/`.

### worktrees.path / worktrees.trunk

- **`path`** (default `{parent}/{repo}-worktrees/{branch}`) — where
  `wt new <branch>` creates the worktree. **The last path segment becomes
  the slug**, and the slug names the port, the Redis `{n}` slot, and the
  `wt_{slug}` database — so keep `{branch}` (or `{branch_raw}`) last.
  `{branch}` folds every character outside `[A-Za-z0-9._]` to `_`,
  **hyphens included**: `wt new feat/refund-flow` gives directory (and slug)
  `feat_refund_flow`, not `feat_refund-flow`. That is on purpose — it makes
  the directory name and the slug identical, so what you see in `wt list` is
  exactly what names your database. (`.` is the one survivor: branch
  `feat.x` gives directory `feat.x` but slug `feat_x`.) `{branch_raw}` keeps
  the branch name verbatim, slashes and all — which nests directories and
  makes only the final segment the slug, so use it in a middle segment, not
  the last one. A
  template whose last segment isn't branch-unique (a fixed literal, say)
  makes every worktree share one slug, and with it one port, one Redis DB,
  and one database; `wt doctor` warns when it detects this. The expanded
  path also can't contain a space — `wt`'s compose args and host env lists
  are built by word-splitting, so `wt new` refuses such a path and
  `wt doctor` warns about it too. `worktrees.path` is the natural key to
  override per user in `worktree-kit.local.yml` — everyone shares the
  repo's stack config but can keep worktrees under their own preferred
  directory.
- **`trunk`** (default: `origin/HEAD`, then `main`, then `master`) — the
  branch `wt merge` merges into, and the branch `wt rm` checks a branch is
  fully merged against before removing it without `--force`.

### compose.service / compose.workdir

`service` (default `app`) names the service in your `docker-compose.yml`
whose image contains your runtime. `workdir` (default `/app`) is where that
image expects the code to be mounted — copy it from the service's `volumes:`
entry in your compose file.

### volumes

Named docker volumes mounted into every wt container. Use them for state
baked into the image that a one-off container would otherwise reset — the
classic case is the Rails gem dir `/usr/local/bundle`: without a volume,
every wt container regresses to the gems baked into the image, ignoring your
branch's `Gemfile.lock`. On first use docker seeds the empty named volume
from the image's content at that path; after that the `prepare` hook keeps it
current per branch. Template variables work in `name`, so `{project}_wt_cache`
gives one shared cache per repo.

### mounts.read_only

Directories served read-only from the **primary** checkout into each
worktree's container — dependency dirs you don't want to reinstall per
worktree (e.g. `node_modules`). Read-only means `yarn build` works but
`yarn install` fails loudly instead of corrupting the shared copy; install
new deps from the primary checkout.

### links

Paths in the **primary** checkout symlinked into every worktree — for
personal folders that git ignores and that therefore exist only in the
primary, such as a repo-local `.claude/` holding Claude Code skills, rules
and hooks. `wt new` creates the links, `wt link` creates or repairs them in
existing worktrees, and `wt doctor` reports a worktree that is missing one.
Nothing already at the destination is ever removed or replaced.

A gitignore rule with a trailing slash (`.claude/`) matches directories
only, so git shows the symlink as untracked (`?? .claude`). When that
happens wt appends the anchored path (`/.claude`) to `.git/info/exclude` —
shared by every worktree of the repo — and says so; the link then shows as
ignored (`!! .claude`) everywhere.

### hooks

- **`prepare`** — runs before *every* `wt run` and `wt server`, on both
  runners. Make it an idempotent self-heal that is near-instant when there is
  nothing to do (`bundle check || bundle install`).
- **`build`** — runs once before the server starts (asset builds). Omit it if
  you have none.
- **`server`** — the long-running server command; the only required hook for
  `wt server`. With the compose runner it must bind `0.0.0.0` and listen on
  `{container_port}`; with the host runner it should listen on `{port}`.
- **`container_port`** (default 3000) — the in-container port; `wt server`
  publishes `{port}:{container_port}`. Ignored by the host runner.

### isolation

Three levels, each a superset of the last:

| level      | what wt exports                 | typical meaning                  |
|------------|---------------------------------|----------------------------------|
| `shared`   | nothing                         | primary's DB, Redis, queues      |
| `isolated` | `isolated_env`                  | own Redis DB `{n}` + own test DB |
| `own_db`   | `isolated_env` + `own_db_env`   | own dev database `wt_{slug}` too |

- **`isolated_env`** — env for anything cheap to segregate. The usual entries
  are a Redis DB number via `{n}` (a stable per-worktree hash in 1–15; db 0
  is deliberately left to your main stack) and a per-worktree **test**
  database name (`TEST_DATABASE: "wt_{slug}_test"`). The test DB lives here
  rather than at `own_db` because it needs no data bootstrap — the framework
  loads it from the schema — and it is what makes concurrent spec runs across
  worktrees safe.
- **`own_db_env`** — env that points the app at a per-worktree database,
  usually named with `{slug}`.
- **`db_bootstrap`** — creates and loads that database. It runs once per
  worktree (a marker file under `.git/wt-state/` remembers); `wt reset`
  clears the marker to force a re-bootstrap.
- **`db_check`** (optional) — a command that exits 0 when the worktree's DB
  already exists and is usable, letting wt skip the bootstrap and just write
  the marker.
- **`migration_paths`** — dirs compared file-by-file against the primary
  checkout. If the worktree has files the primary lacks (i.e. new
  migrations), `wt server` auto-escalates that worktree to `own_db`, because
  migrating the shared DB would break every other branch.
- **`db_drop`** (optional) — destroys the per-worktree database. `wt rm` and
  `wt merge` run it only when the worktree's database carries a `.dbowned`
  marker — i.e. `db_bootstrap` created it, as opposed to `db_check` merely
  finding one that already existed, and `wt reset` hasn't cleared that
  marker since. Without `db_drop` configured (or when the database was only
  adopted), wt prints the database name and leaves it in place.
  Two cases leave a database wt *did* create without that marker, and both
  are deliberate — wt errs toward keeping data:
  **(a)** databases bootstrapped **before wt 0.2.0**, when `.dbowned` did not
  exist yet. On your first `wt rm` after upgrading, those report "no
  ownership marker" and are left alone. To reclaim one, drop the database by
  hand and let the next `--own-db` run rebuild it: only the `db_bootstrap`
  path writes `.dbowned`, and it runs only when the database is missing.
  `wt reset` alone will not do it — it clears both markers, but the next
  run then finds the database still there via `db_check` and re-adopts it,
  which is case (b).
  **(b)** a database re-adopted after `wt reset`: `db_check` (which the rails
  templates configure) only ever writes `.dbready`, so the database that
  `db_check` finds on the next run is never re-marked as owned.
- **`redis_flush`** (optional) — empties this worktree's Redis DB `{n}` on
  `wt rm` / `wt merge`. Without it, the DB is left as-is.

> [!IMPORTANT]
> **wt only exports env vars — your app config must read them.** Nothing
> happens for a var your framework ignores; see the stack guides below for
> the one-line config change each stack needs.

How a level is chosen: CLI flag (`--shared` / `--isolated` / `--own-db`)
beats a `worktree-kit.local.yml` pin, which beats the automatic choice.
`wt server` auto-chooses at least `isolated` (escalating per
`migration_paths`); `wt run` defaults to `shared` — fine for one-off
commands, but a *shared* spec run uses the primary's test database, so
running suites in several worktrees at once will clobber each other (schema
reloads across branches, committed test data). Run concurrent suites at
`--isolated`, where each worktree gets its own test DB.

### Template variables

Usable in every hook command and env value:

| variable           | value                                                  |
|--------------------|--------------------------------------------------------|
| `{slug}`           | worktree dir name, lowercased, ≤ 40 chars (`phase02`)  |
| `{n}`              | stable per-slug number 1–15 (Redis DB slot)            |
| `{port}`           | the host port (set for `wt server`; empty in `wt run`) |
| `{container_port}` | `hooks.container_port`                                 |
| `{project}`        | primary checkout dir name, lowercased                  |

Values containing spaces are not supported (the shell glue word-splits);
keep hooks with complex quoting in a script file and call that instead.

### Ports and per-user pins: worktree-kit.local.yml

Ports are auto-assigned: a stable hash of the slug in 3000–3899, bumped
upward until free — so each worktree keeps a predictable URL across restarts.
To pin a port or an isolation level for yourself, drop a
`worktree-kit.local.yml` next to the main config (gitignore it):

```yaml
servers:
  my-task: { port: 3005, isolation: own-db }
```

A pinned port is checked but never auto-bumped: `wt server` refuses to start
if it is busy.

## Stack guide: Rails on docker compose

1. `wt init` (a `Gemfile` plus a compose file select `compose/rails.yml`).
2. Set `compose.service` and `compose.workdir` to match your
   `docker-compose.yml`.
3. Make `config/database.yml` read the own-db var, with your normal dev DB as
   the fallback:
   ```yaml
   development:
     database: <%= ENV.fetch('DEV_DATABASE', 'myapp_development') %>
   ```
4. Same for the test section, so concurrent rspec runs across worktrees don't
   share one test DB (rspec's `maintain_test_schema!` reloads the schema per
   branch — on a shared DB that clobbers whoever else is mid-run):
   ```yaml
   test:
     database: <%= ENV.fetch('TEST_DATABASE', 'myapp_test') %>
   ```
   Create it once per worktree (`wt run --isolated bin/rails db:test:prepare`),
   then run suites with `wt run --isolated bundle exec rspec ...`.
5. Check the Redis var name: the template exports `REDIS_URL`; if your app
   configures Redis/Resque/Sidekiq some other way, export whatever it
   actually reads in `isolated_env`.
6. Keep `SKIP_TEST_DATABASE=1` in `db_bootstrap`: in Rails 6.x a bare
   `db:schema:load` in development **also force-reloads the test database**
   — without the guard, bootstrapping a worktree DB can drop tables out of
   the shared test DB. Prefer per-database tasks (`db:schema:load:primary`)
   if you have multiple databases.
7. Keep the gem-cache volume and the `prepare` self-heal — gems bake into the
   image at `/usr/local/bundle`, and this pair is what lets each branch's
   `Gemfile.lock` work in one-off containers.
8. Smoke-test: `wt doctor`, then `wt run bin/rails runner 'puts Rails.env'`,
   then `wt server` and open the printed URL.

Background jobs: a worker only polls the Redis DB it was started against, so
an isolated worktree needs its own worker started with the same flag —
`wt run --isolated bundle exec rake environment resque:work`.

## Stack notes: Laravel, Django, Node, Go

- **Laravel** — exported env beats `.env`, so `REDIS_DB` / `REDIS_CACHE_DB` /
  `DB_DATABASE` work out of the box. One trap: `php artisan config:cache`
  freezes config and the exported env is silently ignored — don't cache
  config in development. Adjust `db_bootstrap`'s `mysql -uroot ...` line for
  your engine (postgres: `createdb wt_{slug}`). Tests: `phpunit.xml` pins one
  shared `DB_DATABASE` for every worktree — make `config/database.php` prefer
  the exported `TEST_DB_DATABASE` when `APP_ENV=testing` (snippet in the
  template), create the DB once, and run suites with
  `wt run --isolated php artisan test`.
- **Django** — `settings.py` must read the vars:
  `NAME: os.environ.get("DATABASE_NAME", "myapp")`, same idea for the Redis
  URL used by your cache/queue. Tests: point the `TEST` name at the exported
  var — `"TEST": {"NAME": os.environ.get("TEST_DATABASE_NAME", "test_myapp")}`
  — and run `wt run --isolated python manage.py test`; Django creates and
  destroys the DB itself.
- **Node** — the template exports `DATABASE_URL` / `REDIS_URL` and assumes
  prisma for `db_bootstrap`; swap in your ORM's migrate command and make
  sure your config reads those URLs rather than hardcoding. Tests: point
  your test setup at the exported `TEST_DATABASE_URL` and have it create and
  migrate the DB, then `wt run --isolated npm test`.
- **Go** — same idea: read `DATABASE_URL` / `REDIS_URL` from the environment,
  and point `db_bootstrap` at your migration tool. Tests: read the exported
  `TEST_DATABASE_URL` in your test helper and
  `wt run --isolated go test ./...`.

Every stack ships both runner variants under `templates/compose/` and
`templates/host/` — if `wt init` picks the wrong one (say, a compose file
that isn't your dev stack), copy the other variant over `worktree-kit.yml`.

## Workflow: with `wt new`, or plain `git worktree add`

`wt` takes its context from git, not from the worktree: it resolves the
primary checkout through the git common dir and reads `worktree-kit.yml`
from there. A worktree therefore needs zero setup, whether `wt new` made it
or you ran `git worktree add` yourself.

The `wt` way, start to finish:

```sh
wt new feat/login --from origin/main       # branch + worktree at worktrees.path, prepare hook run
wt server                                  # own port, auto isolation
wt run --isolated bundle exec rspec spec/  # own test DB
wt merge                                   # squash, rebase, fast-forward trunk, reclaim everything
```

Plain git works just as well; `wt` joins in whenever you call it:

```sh
cd ~/code/myapp                                  # primary checkout (has worktree-kit.yml)
git worktree add ../myapp-fix-login fix-login    # plain git — wt is not involved yet
cd ../myapp-fix-login
wt run --isolated bundle exec rspec spec/        # specs on this branch, own test DB
wt server                                        # own port + auto isolation for this branch
wt rm                                            # done: server, DB, Redis slot, worktree, branch
```

`wt rm` stops the server, drops the `wt_<slug>` database when wt created it
(and `db_drop` is configured), flushes the Redis slot when `redis_flush` is,
then removes the worktree and its branch; `--keep-branch` keeps the branch.
The manual equivalent is `wt down <slug>`, `git worktree remove`, and
`wt reset <slug>`. A database wt merely adopted rather than created is yours
to drop, and wt says so instead of touching it.

Two consequences of how slugs work:

- The worktree **directory name becomes the slug** (lowercased,
  non-alphanumeric → `_`), and the slug drives the port hash and the Redis
  `{n}` slot — so name worktree dirs distinctly (`../myapp-phase02`, not
  `../wt2`). `wt new` does this for you through `worktrees.path`. Names
  longer than 40 chars are cut to a prefix plus a checksum of the full name,
  so `wt_{slug}_test`-style database names always fit inside the 63/64-char
  identifier limits of postgres/mysql.
- The worktree itself carries no config; running `wt` from the primary
  checkout also works and is always treated as `shared`.

## Shell integration

`wt switch`, `wt new`, `wt rm`, and `wt merge` can all change which worktree
you're standing in — but a subprocess can never `cd` its parent shell, so wt
prints the target path on stdout (the "cd channel") and leaves the actual
`cd` to your shell. Wire that up once:

```sh
eval "$(wt shell-init zsh)"      # or: bash, fish
```

Add that line to `~/.zshrc` (or `~/.bashrc`, or fish's `config.fish`) and
open a new shell. It defines a `wt` shell function that intercepts `switch`,
`new`, `rm`, and `merge` — running the real binary with
`WT_SHELL_INTEGRATION=1` set (so `wt doctor` can report it as active) and
`cd`-ing to whatever path it printed. Every other subcommand passes straight
through to the real `wt`.

Without it, those four commands still do everything else they normally do —
they just print the path instead of changing directory:

```sh
$ wt switch feat/login
/Users/you/code/myapp-worktrees/feat_login
wt: not cd'd — install shell integration: eval "$(wt shell-init zsh)"
```

so `cd "$(wt switch feat/login)"` works too, if you'd rather not install the
function.

## Command reference

Every command takes its context from the directory you run it in: `wt`
resolves the primary checkout through git, reads `worktree-kit.yml` from
there, and derives this worktree's **slug** from its directory name
(lowercased, non-alphanumeric → `_`, so `../myapp-fix-login` becomes
`myapp_fix_login`). Commands that name a worktree (`up`, `down`, `logs`,
`reset`, `link`) take that slug, not a path — `wt ps` shows the slugs of
everything running. The lifecycle commands (`new`, `switch`, `rm`, `merge`)
take a **branch name** instead, since that is what you think in.

The [table above](#commands-at-a-glance) lists every command; the sections
below give the details.

### wt run — one-off commands

```sh
wt run [--shared|--isolated|--own-db] [--] <command...>
```

Runs one command in this worktree and exits. The `prepare` hook runs first
(both runners), then the command — in a fresh `docker compose run --rm`
container with the worktree mounted over `compose.workdir` (compose runner),
or as a plain process in the worktree directory (host runner). When attached
to a terminal the compose runner allocates a TTY, so interactive commands
like a Rails console work.

The default level is `--shared` (nothing exported) — fine for one-offs, but
concurrent test suites need `--isolated` (see [Caveats](#caveats)).
`--own-db` bootstraps this worktree's database on first use. Flags come
before the command — parsing stops at the first word that isn't an isolation
flag (or at a literal `--`, for the rare command that itself starts with one).

```sh
wt run bundle exec rspec spec/models/foo_spec.rb   # shared: hits the primary's test DB
wt run --isolated bundle exec rspec spec/          # own test DB — safe in many worktrees at once
wt run --own-db bin/rails db:migrate               # against this worktree's own dev DB
wt run bin/rails console                           # interactive — the TTY passes through
wt run --isolated bundle exec rake resque:work     # a worker polling this worktree's Redis DB
```

### wt server — this worktree's server

```sh
wt server [--shared|--isolated|--own-db] [port]
```

Starts the `hooks.server` command detached (after `prepare` and `build`) and
prints the URL. Without a flag the level is chosen automatically: a
`worktree-kit.local.yml` pin wins; the primary checkout is always `shared`;
a worktree whose `migration_paths` contain files the primary lacks escalates
to `own_db`; everything else runs `isolated`.

The port likewise: an explicit positional port beats a `local.yml` pin,
which beats the stable slug hash in 3000–3899 (bumped upward until free).
Explicit and pinned ports are checked but never bumped — `wt server` refuses
to start if one is busy. It also refuses if this slug already has a running
server (`wt down <slug>` first).

Compose runner: a detached container named `wt-<project>-<slug>` publishing
`<port>:<container_port>`. Host runner: a nohup'd process with a pidfile
under `.git/wt-state/`, logging to `.git/wt-state/logs/<slug>.log`.

```sh
wt server              # auto port + auto isolation
wt server 3050         # this exact port (refuses if busy)
wt server --own-db     # force own dev database (bootstraps on first use)
```

### wt up — everything at once

```sh
wt up [--shared|--isolated|--own-db] [slug...]
```

Runs `wt server` in every worktree of the repo (the primary checkout is
skipped), each with its own auto-assigned port and auto-detected isolation.
Pass slugs to start only those; an isolation flag applies to every worktree
being started (it's passed through to each `wt server`, so it beats
`worktree-kit.local.yml` pins, like any CLI flag). One worktree failing to
start doesn't stop the others — a note is printed and `wt up` moves on.
Works from anywhere in the repo, primary or worktree.

```sh
wt up                                  # a server for every worktree, auto isolation
wt up myapp_phase02                    # just this one
wt up myapp_phase02 myapp_fix_login    # these two
wt up --own-db                         # every worktree on its own dev database
wt up --own-db myapp_phase02           # just this one, forced to own-db
```

Without a flag `wt up` uses the automatic choices, and per-worktree pins in
`worktree-kit.local.yml` apply. Ports can't be set from `wt up` — pin one in
`local.yml`, or `cd` into that worktree and run `wt server <port>`.

### wt down — stop servers

```sh
wt down [slug...]
```

With no arguments stops **every** running worktree server of this repo; with
slugs, just those. Compose containers are removed on stop (they run with
`--rm`); host processes are killed and their pidfiles cleaned up.

```sh
wt down                 # stop them all
wt down myapp_phase02   # stop one
```

### wt ps — what's running

Lists this repo's running worktree servers: slug, isolation level, URL, and
status. On the compose runner this reads container labels; on the host
runner it reads the pidfiles and reports `running` or `dead`.

```
myapp_phase02   isolated   http://localhost:3247   Up 2 hours
myapp_fix_login own_db     http://localhost:3105   Up 20 minutes
```

### wt logs — follow a server

```sh
wt logs [slug]
```

Follows a server's output (like `tail -f`); Ctrl-C stops following, not the
server. The slug defaults to the current worktree, so a bare `wt logs`
inside a worktree does the right thing. One runner difference: compose logs
live with the container, so they're gone once that server is stopped; host
logs persist in `.git/wt-state/logs/<slug>.log`.

### wt localize — personal overlays

```sh
wt localize config/database.yml               # snapshot (re-run after editing the source)
wt localize --list                            # what's overlaid
wt localize --remove config/database.yml      # drop an overlay
```

Snapshots a tracked file into `.git/local/` to be mounted read-only over the
container's copy — details in [Overlays](#overlays-wt-localize) below.

### wt link — host-visible symlinks

```sh
wt link              # link this worktree (run inside it)
wt link --all        # every worktree except the primary
wt link feat_x       # only the named slugs
```

Symlinks each [`links:`](#links) path from the primary checkout into the
worktree, so gitignored personal folders like `.claude/` exist there too.
`localize` snapshots a file for containers; `link` symlinks a path for the
host and auto-runs on `wt new`. An existing file or directory at the
destination is reported and left alone, and a second run just reports `ok`.

### wt reset — re-bootstrap an own-db worktree

```sh
wt reset [slug]      # defaults to the current worktree
```

Clears the marker that records "this worktree's database was bootstrapped",
so the next `--own-db` run bootstraps again. It only clears the marker — the
`wt_<slug>` database itself is never dropped; that's yours.

### wt new — create a branch + worktree

```sh
wt new <branch> [--from <base>] [--server]
```

Creates the branch (or adopts an existing one of the same name) and a
`git worktree add` at `worktrees.path`, runs `hooks.prepare` once, and prints
the new worktree's path on the cd channel (see
[Shell integration](#shell-integration)). `--from <base>` branches off
`<base>` instead of `HEAD`; `--server` starts the server immediately instead
(it runs `prepare` itself, so plain `wt new` doesn't also run it, to avoid
running the hook twice).

```sh
wt new feat/login                    # new branch + worktree off HEAD
wt new feat/login --from origin/main # off a specific base
wt new feat/login --server           # + start its server right away
```

### wt switch — jump to a worktree

```sh
wt switch [<branch>]
```

Prints the worktree path for `<branch>` on the cd channel — or, with no
argument, opens an interactive picker (`fzf` if installed, else a numbered
menu) over every worktree, with a preview pane showing recent log and
status. Needs [shell integration](#shell-integration) to actually `cd`;
without it, `wt switch` just prints the path.

### wt rm — tear down a worktree

```sh
wt rm [<branch>] [--keep-branch] [--force]
```

Stops the worktree's server, drops its database via `isolation.db_drop` —
but only when the database carries a `.dbowned` marker, meaning wt itself
bootstrapped it rather than merely adopting one `db_check` found already
there (`wt reset` clears that marker, so an adopted-after-reset database is
left in place with a notice instead) — flushes its Redis slot if
`isolation.redis_flush` is configured, then removes the git worktree and
deletes the branch. Defaults to the branch checked out in the current
worktree. Prompts for confirmation, and refuses when the worktree is dirty
or has commits not yet in the [trunk](#worktreespath--worktreestrunk);
`--force` waives both the safety checks and the confirmation prompt.
`--keep-branch` removes the worktree but leaves the branch.

> [!WARNING]
> `git worktree remove` deletes the **entire worktree directory**, not just
> git's registration of it — including files git never tracked: `.env`, local
> SQLite databases, uploads, `tmp/`, everything `.gitignore` covers. The
> dirty-worktree refusal does not protect these; it only looks at tracked and
> untracked files, and ignored files are invisible to it. Copy anything you
> want to keep out first.

### wt merge — squash, rebase, fast-forward, tear down

```sh
wt merge [<branch>] [--into <trunk>] [-m <msg>] [--no-remove] [--force]
```

Squashes every commit on `<branch>` since it diverged from the
[trunk](#worktreespath--worktreestrunk) into one commit, rebases that commit
onto the trunk, fast-forwards the trunk to it in the primary checkout, then
tears the worktree down like **`wt rm --force`** does — `git worktree remove
--force` plus `git branch -D`, and **without prompting**. That deletes the
whole worktree directory, gitignored files included (`.env`, local databases,
uploads, `tmp/`), with no confirmation step in between. A backup ref
(`refs/wt/premerge/<slug>`) captures the branch's pre-squash HEAD before
anything is rewritten; a squash failure, a rebase conflict, or a
non-fast-forward trunk all restore the branch to that commit and leave the
worktree in place, with the recovery command printed. `--into <trunk>`
overrides `worktrees.trunk` for this run; `-m <msg>` sets the squash commit
message (default: the first commit's subject, remaining subjects as the
body); `--no-remove` merges without tearing down.

> [!IMPORTANT]
> `wt merge` never prompts — there is nothing for `--force` to skip there.
> Its `--force` only waives the one guard that exists: refusing to squash a
> branch that has an upstream (squashing would rewrite already-published
> history). This is different from `wt rm --force`, which waives both the
> safety refusals *and* the confirmation prompt. Note that the teardown is
> the forceful kind either way — passing `--force` does not make it any more
> destructive, and omitting it does not make it any less. Use `--no-remove`
> if you want the worktree directory kept.

### wt list — see every worktree

```sh
wt list [--all]
```

A table of every worktree: branch, slug, git status (`clean`/`dirty`),
running server (if any), isolation level, and path. `--all` also lists
branches that have no worktree.

### wt init / wt doctor — setup and checks

`wt init` detects the stack and writes `worktree-kit.yml` (see
[Per-repo setup](#per-repo-setup)). `wt doctor` prints the version, primary
and worktree paths with slug and `{n}`, the config and runner in use, the
resolved `worktrees.path` template (warning if its last segment isn't
branch-unique, or if it expands to a path containing a space), which YAML
backend was auto-detected, whether docker is up (compose repos), whether
`fzf` is installed, whether shell integration is active, and flags stale
overlays. Run it after any config change.

## Overlays (`wt localize`)

Personal versions of tracked files (a tweaked `database.yml`, a local
`development.rb`) live under `<repo>/.git/local/` — git can never commit
anything under `.git/`, and they survive branch switches — and are mounted
read-only over the container's copy in every compose run. Two things to know:

- Overlays are **snapshots**: re-run `wt localize <file>` after editing the
  source; `wt doctor` flags stale ones. A stale overlay referencing removed
  code can crash boots.
- Overlays apply to the **compose runner only** — the host runner runs
  against the worktree's files as-is.

## Caveats

> [!WARNING]
> `wt run` defaults to `shared`, where every worktree's suite hits the
> primary's test database — concurrent runs clobber each other. The templates
> export a per-worktree test DB name at `--isolated` (`TEST_DATABASE` /
> `TEST_DB_DATABASE` / `TEST_DATABASE_NAME` / `TEST_DATABASE_URL`); wire your
> test config to it and run concurrent suites with `wt run --isolated`.

- Jobs enqueued under `--isolated` need a worker started with the same flag;
  the main stack's worker only sees its own Redis DB.
- `{n}` has 15 slots, so two worktrees can land on the same Redis DB — both
  print their `n` at start; pin one in `worktree-kit.local.yml` if they meet.
- Rails ≤ 7: a bare `db:schema:load` in development also reloads the TEST
  database — keep `SKIP_TEST_DATABASE=1` in `db_bootstrap` (templates do).

## Testing

- `./test/lifecycle.sh` runs the lifecycle suite against throwaway repos:
  `wt new`, `wt switch`, `wt list`, `wt rm`, `wt merge`, `wt link`,
  `wt doctor`, and the `shell-init` wrappers. Git only — no docker, no YAML
  backend needed — so it runs anywhere in seconds.
- `./test/linux.sh [debian|alpine]` runs the Linux suite in containers
  (requires docker): install (clone symlink on Debian, `curl | sh` remote
  mode on Alpine), `wt init` stack detection, the ruby and python3 + PyYAML
  YAML backends, isolation env export, the server lifecycle including
  busy-port detection via bind probe and `ss`, and then the lifecycle suite
  above. GitHub Actions runs both distros on every push.

---

<div align="center">

MIT © [Nguyen Van Sang](https://github.com/VSN2015) — issues and
[template PRs for new stacks](#per-repo-setup) welcome.

</div>
