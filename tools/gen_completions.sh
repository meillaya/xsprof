#!/bin/sh
# Generate static shell completions from a built xsprof binary.
# Usage: sh tools/gen_completions.sh <path-to-xsprof> <share-prefix>
# The destination uses the standard prefix layout:
#   bash-completion/completions/xsprof
#   zsh/site-functions/_xsprof
#   fish/vendor_completions.d/xsprof.fish
set -eu
BIN=${1:-}
DEST=${2:-}
if [ -z "$BIN" ] || [ -z "$DEST" ]; then
    echo "usage: sh tools/gen_completions.sh <xsprof-binary> <share-prefix>" >&2
    exit 2
fi
[ -x "$BIN" ] || { echo "gen_completions: not executable: $BIN" >&2; exit 2; }
mkdir -p "$DEST/bash-completion/completions" "$DEST/zsh/site-functions" "$DEST/fish/vendor_completions.d"
"$BIN" completions bash > "$DEST/bash-completion/completions/xsprof"
"$BIN" completions zsh > "$DEST/zsh/site-functions/_xsprof"
"$BIN" completions fish > "$DEST/fish/vendor_completions.d/xsprof.fish"
chmod 644 "$DEST/bash-completion/completions/xsprof" "$DEST/zsh/site-functions/_xsprof" "$DEST/fish/vendor_completions.d/xsprof.fish"
echo "gen_completions: wrote bash/zsh/fish completions under $DEST"
