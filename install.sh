#!/bin/sh
# Symlink bin/wt onto the PATH. Usage: ./install.sh [target-dir]
set -eu
KIT="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-$HOME/.local/bin}"
mkdir -p "$TARGET"
ln -sf "$KIT/bin/wt" "$TARGET/wt"
echo "installed: $TARGET/wt -> $KIT/bin/wt"
case ":$PATH:" in
  *":$TARGET:"*) ;;
  *) echo "NOTE: $TARGET is not on your PATH — add it to your shell profile." ;;
esac
command -v yq >/dev/null 2>&1 || echo "NOTE: wt needs yq (brew install yq)."
