#!/bin/sh
# Run the Linux test suite in containers (requires docker).
# Usage: ./test/linux.sh [debian|alpine]   (default: both)
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"

run_one() {
  echo "=== $1 ($2)"
  docker run --rm -v "$repo:/src:ro" "$2" sh "/src/test/linux-$1.sh"
}

case "${1:-all}" in
  debian) run_one debian debian:stable-slim ;;
  alpine) run_one alpine alpine:latest ;;
  all)    run_one debian debian:stable-slim; run_one alpine alpine:latest ;;
  *)      echo "usage: $0 [debian|alpine]" >&2; exit 1 ;;
esac
echo "ALL LINUX TESTS PASSED"
