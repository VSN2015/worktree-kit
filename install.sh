#!/bin/sh
# Install wt. Two modes:
#   from a clone:  ./install.sh [target-dir]     (symlinks bin/wt onto PATH)
#   without one:   curl -fsSL https://raw.githubusercontent.com/VSN2015/worktree-kit/master/install.sh | sh
#                  (downloads the latest release to ~/.local/share/worktree-kit)
set -eu
REPO="VSN2015/worktree-kit"
TARGET="${1:-$HOME/.local/bin}"

KIT="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo "")"
if [ -z "$KIT" ] || [ ! -f "$KIT/bin/wt" ]; then
  # no local checkout (curl | sh): fetch the latest release tarball.
  # GITHUB_TOKEN (if set) authenticates the API call — shared CI runner IPs
  # exhaust the unauthenticated rate limit.
  fetch() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" "$1"
    else curl -fsSL "$1"; fi
  }
  KIT="${WT_HOME:-$HOME/.local/share/worktree-kit}"
  tag="$(fetch "https://api.github.com/repos/$REPO/releases/latest" |
    sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$tag" ] || { echo "install.sh: could not determine the latest release of $REPO" >&2; exit 1; }
  rm -rf "$KIT" && mkdir -p "$KIT"
  fetch "https://github.com/$REPO/archive/refs/tags/$tag.tar.gz" | tar xz -C "$KIT" --strip-components=1
  echo "downloaded: worktree-kit $tag -> $KIT"
fi

mkdir -p "$TARGET"
ln -sf "$KIT/bin/wt" "$TARGET/wt"
echo "installed: $TARGET/wt -> $KIT/bin/wt"
case ":$PATH:" in
  *":$TARGET:"*) ;;
  *) echo "NOTE: $TARGET is not on your PATH — add it to your shell profile." ;;
esac
command -v yq >/dev/null 2>&1 || command -v ruby >/dev/null 2>&1 || \
  { command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; } || \
  echo "NOTE: wt needs a YAML reader: yq, ruby, or python3 with PyYAML."
