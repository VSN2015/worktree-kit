#!/bin/sh
# Linux test, glibc + ruby YAML backend. Run via test/linux.sh, or directly:
#   docker run --rm -v "$PWD:/src:ro" debian:stable-slim sh /src/test/linux-debian.sh
set -eux
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends git ruby ca-certificates curl >/dev/null
git config --global user.email t@t.t && git config --global user.name t
git config --global init.defaultBranch main

# local-mode install (symlink from clone)
sh /src/install.sh /usr/local/bin
command -v lsof && exit 1 || true   # must be absent so the fallback chain is exercised
command -v ss && exit 1 || true

wt --version
wt --help >/dev/null

# init: stack detect + template lookup through the symlink
mkdir /tmp/app && cd /tmp/app && git init -q && touch go.mod
wt init
grep -q 'runner:' worktree-kit.yml

# toolchain-free config for runtime tests
cat > worktree-kit.yml <<'EOF'
runner: host
hooks:
  server: "ruby /tmp/app/server.rb {port}"
isolation:
  isolated_env:
    REDIS_URL: "redis://localhost:6379/{n}"
    TEST_DATABASE: "wt_{slug}_test"
EOF
cat > server.rb <<'EOF'
require "socket"
s = TCPServer.new(ARGV[0].to_i)
loop do
  c = s.accept
  c.write "HTTP/1.0 200 OK\r\n\r\nok\n"
  c.close
end
EOF

wt doctor | grep 'yaml:.*ruby'
wt run --isolated -- env | grep -E '^(REDIS_URL|TEST_DATABASE)=' | sort

# server lifecycle on the ruby bind-probe port check
wt server 4321
sleep 2
wt ps | grep -E '4321.*running'
curl -fsS http://localhost:4321/ | grep -q ok && echo "server responds"

# busy-port detection via ruby bind probe (second repo, same port)
mkdir /tmp/app2 && cd /tmp/app2 && git init -q
cp /tmp/app/worktree-kit.yml .
wt server 4321 2>&1 | grep -q 'port 4321 is busy' && echo "ruby probe: busy detected"

# busy-port detection via ss once iproute2 appears
apt-get install -y -qq --no-install-recommends iproute2 >/dev/null
wt server 4321 2>&1 | grep -q 'port 4321 is busy' && echo "ss: busy detected"

cd /tmp/app && wt down
wt ps | grep -q running && exit 1 || true
echo "DEBIAN PASS"
