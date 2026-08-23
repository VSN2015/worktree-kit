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
  server: "python3 -m http.server {port}"
isolation:
  isolated_env:
    REDIS_URL: "redis://localhost:6379/{n}"
    TEST_DATABASE: "wt_{slug}_test"
EOF

wt doctor | grep 'yaml:.*python3'
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
echo "ALPINE PASS"
