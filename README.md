# worktree-kit

`wt` runs commands and app servers for git worktrees, so many branches of one
repo can run side by side without collisions. It is stack-agnostic: the core
executes only commands that each repo declares in a `worktree-kit.yml`.

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
brew install VSN2015/tap/worktree-kit   # installs yq too
```

or from source:

```sh
git clone https://github.com/VSN2015/worktree-kit && cd worktree-kit && ./install.sh
brew install yq        # the one dependency (plus docker for compose repos)
```

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
Commit `worktree-kit.yml`; it holds no secrets.

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

compose:                # read only when runner: compose
  service: app          # docker-compose.yml service whose image runs your code
  workdir: /app         # where that image expects the checkout

volumes:                # named docker volumes added to every wt container
  - name: "{project}_wt_cache"
    path: /usr/local/bundle

mounts:
  read_only: [node_modules]   # dirs mounted read-only from the primary checkout

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

**wt only exports env vars — your app config must read them.** Nothing
happens for a var your framework ignores; see the stack guides below for the
one-line config change each stack needs.

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
| `{slug}`           | worktree dir name, lowercased (`phase02`)              |
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

## Workflow: branch → worktree → server

`wt` has no worktree-creation command on purpose — worktrees are plain
`git worktree add`, and `wt` picks up context from wherever you run it: it
resolves the primary checkout via the git common dir and reads
`worktree-kit.yml` from there, so a fresh worktree needs zero setup.

Checkout an existing branch into a worktree:

```sh
cd ~/code/myapp                                  # primary checkout (has worktree-kit.yml)
git worktree add ../myapp-fix-login fix-login    # plain git — wt is not involved yet
cd ../myapp-fix-login
wt run --isolated bundle exec rspec spec/        # specs on this branch, own test DB
wt server                                        # own port + auto isolation for this branch
```

Or create a new branch as a worktree in one step:

```sh
git worktree add -b phase02 ../myapp-phase02 master
cd ../myapp-phase02
wt server        # -> "myapp_phase02 [isolated] -> http://localhost:3xxx"
```

Tear down when the branch is done:

```sh
wt down myapp_fix_login                # stop its server
git worktree remove ../myapp-fix-login
wt reset myapp_fix_login               # clear the db-bootstrap marker if it used own-db
```

If the worktree ran at `own_db`, its `wt_<slug>` database is yours to drop —
`wt` never deletes data.

Two consequences of how slugs work:

- The worktree **directory name becomes the slug** (lowercased,
  non-alphanumeric → `_`), and the slug drives the port hash and the Redis
  `{n}` slot — so name worktree dirs distinctly (`../myapp-phase02`, not
  `../wt2`).
- The worktree itself carries no config; running `wt` from the primary
  checkout also works and is always treated as `shared`.

## Daily use

```sh
wt run bundle exec rspec spec/models/foo_spec.rb   # one-off in this worktree (shared test DB)
wt run --isolated bundle exec rspec spec/          # own test DB — safe to run in many worktrees at once
wt server            # this worktree's server: auto port + auto isolation
wt up                # servers for every worktree
wt ps / wt logs / wt down
wt localize config/database.yml   # personal overlay (see below)
wt doctor            # checks, including stale overlays
```

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

- `wt run` defaults to `shared`, where every worktree's suite hits the
  primary's test database — concurrent runs clobber each other. The templates
  export a per-worktree test DB name at `--isolated` (`TEST_DATABASE` /
  `TEST_DB_DATABASE` / `TEST_DATABASE_NAME` / `TEST_DATABASE_URL`); wire your
  test config to it and run concurrent suites with `wt run --isolated`.
- Jobs enqueued under `--isolated` need a worker started with the same flag;
  the main stack's worker only sees its own Redis DB.
- `{n}` has 15 slots, so two worktrees can land on the same Redis DB — both
  print their `n` at start; pin one in `worktree-kit.local.yml` if they meet.
- Rails ≤ 7: a bare `db:schema:load` in development also reloads the TEST
  database — keep `SKIP_TEST_DATABASE=1` in `db_bootstrap` (templates do).
