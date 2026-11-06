#!/bin/sh
# Human-run regeneration of the committed native showcase media.
#
# This is the human entry point; it is not part of automated CI. It is still
# HEADLESS: tools/showcase.sh renders deterministic CPU snapshots and ffmpeg
# encodes them. No real window is opened, activated, or captured, and there is
# no display-server capture path. Refuses to run in CI unless FORCE=1.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if [ -n "$CI" ] && [ "$FORCE" != 1 ]; then
    echo "record_native_showcase: refusing to render media in CI (FORCE=1 to override)" >&2
    exit 0
fi

echo "record_native_showcase: headless renderer (no window, no display capture)"
echo "  outputs: design/media/xsprof-native-showcase.{mp4,gif}"
echo "           design/media/xsprof-native-live-replay.{mp4,gif}"
echo "           design/media/*.provenance.json"

if [ "$YES" != 1 ] && [ -t 0 ]; then
    printf "Regenerate the committed media now? [y/N] "
    read answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) echo "record_native_showcase: aborted"; exit 0 ;;
    esac
fi

exec "$ROOT/tools/showcase.sh" "$@"
