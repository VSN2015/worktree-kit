#!/bin/sh
# Linux test, musl/busybox + python3 YAML backend. Run via test/linux.sh, or:
#   docker run --rm -v "$PWD:/src:ro" alpine:latest sh /src/test/linux-alpine.sh
set -eux
apk add -q git curl python3 py3-yaml ca-certificates
git config --global user.email t@t.t && git config --global user.name t
git config --global init.defaultBranch main

# remote-mode install: pipe install.sh with no clone around (cwd /);
# downloads the latest published release from GitHub
cd /
cat /src/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
wt --version
ls "$HOME/.local/share/worktree-kit/templates/host" | grep -q rails.yml

# from here on, test the checked-out wt (local-mode install wins the symlink)
sh /src/install.sh
wt --version

mkdir /tmp/app && cd /tmp/app && git init -q && echo '{}' > package.json
wt init
cat > worktree-kit.yml <<'EOF'
runner: host
hooks:
  # compound on purpose: forces an sh -c wrapper layer, so this suite
  # catches the orphaned-server bug (down must kill the process group)
  server: "true && python3 -m http.server {port}"
isolation:
  isolated_env:
    REDIS_URL: "redis://localhost:6379/{n}"
    TEST_DATABASE: "wt_{slug}_test"
EOF

wt doctor | grep 'yaml:.*python3'   # this first read also builds the config cache
wt doctor | grep -q 'cache: hit'
echo '# edited' >> worktree-kit.yml
wt doctor | grep -q 'cache: rebuilt'
wt run --isolated -- env | grep -E '^(REDIS_URL|TEST_DATABASE)=' | sort

# server lifecycle: python bind probe for the port check (no real lsof/ss/ruby;
# BusyBox's fake lsof applet must be skipped)
wt server 4321
sleep 2
wt ps | grep -E '4321.*running'
curl -fsS http://localhost:4321/ >/dev/null && echo "server responds"

mkdir /tmp/app2 && cd /tmp/app2 && git init -q && cp /tmp/app/worktree-kit.yml .
wt server 4321 2>&1 | grep -q 'port 4321 is busy' && echo "python probe: busy detected"

cd /tmp/app && wt down
wt ps | grep -q running && exit 1 || true
# down must kill the real server, not just the sh -c wrapper
curl -fsS -m 2 http://localhost:4321/ >/dev/null 2>&1 && exit 1 || echo "port freed — no orphan"

# lifecycle commands: git only, no docker, no YAML backend
sh /src/test/lifecycle.sh
echo "ALPINE PASS"
