#!/bin/sh
# Native showcase media gate: verifies the committed design/media artifacts
# and provenance, then renders a tiny deterministic smoke pass twice and
# compares frame hashes. Rendering is headless CPU snapshots only: no window,
# no display capture, no x11grab. Requires ffmpeg/ffprobe/python3; SKIPs with a
# reason when the media toolchain is unavailable.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${XSPROF_BIN:-"$ROOT/zig-out/bin/xsprof"}
MEDIA="$ROOT/design/media"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail=0

skip() { echo "showcase_smoke: SKIP ($*)"; exit 0; }
check() {
    if [ "$1" -ne 0 ]; then
        echo "showcase_smoke: FAIL ($2)" >&2
        fail=1
    else
        echo "showcase_smoke: PASS ($2)"
    fi
}

command -v ffmpeg >/dev/null 2>&1 || skip "ffmpeg unavailable"
command -v ffprobe >/dev/null 2>&1 || skip "ffprobe unavailable"
command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
command -v sha256sum >/dev/null 2>&1 || skip "sha256sum unavailable"
[ -x "$BIN" ] || skip "binary missing: $BIN (run ./tools/zig build)"

# 1) committed artifacts + canonical provenance (no rendering).
if [ -f "$MEDIA/xsprof-native-showcase.provenance.json" ] && \
   [ -f "$MEDIA/xsprof-native-live-replay.provenance.json" ]; then
    if sh "$ROOT/tools/showcase.sh" --check >"$TMP/check.log" 2>&1; then
        check 0 "committed media + provenance verified"
    else
        check 1 "committed media + provenance verified"
        cat "$TMP/check.log" >&2
    fi
    sed -n '1,4p' "$TMP/check.log"
else
    echo "showcase_smoke: FAIL (committed native showcase media missing)" >&2
    fail=1
fi

# 2) deterministic smoke render, twice, into isolated temp dirs.
rm -rf "$TMP/a" "$TMP/b"
if ! sh "$ROOT/tools/showcase.sh" --smoke --out "$TMP/a" >"$TMP/a.log" 2>&1; then
    check 1 "smoke render a"
    cat "$TMP/a.log" >&2
fi
if ! sh "$ROOT/tools/showcase.sh" --smoke --out "$TMP/b" >"$TMP/b.log" 2>&1; then
    check 1 "smoke render b"
    cat "$TMP/b.log" >&2
fi
if [ -s "$TMP/a/showcase-smoke.mp4" ] && [ -s "$TMP/a/showcase-smoke.gif" ]; then
    check 0 "smoke mp4 + gif produced"
else
    check 1 "smoke mp4 + gif produced"
fi
python3 - "$TMP/a" "$TMP/b" <<'PY' || fail=1
import json, os, subprocess, sys
a, b = sys.argv[1], sys.argv[2]
def provenance(root):
    with open(os.path.join(root, "showcase-smoke.provenance.json"), "r", encoding="utf-8") as handle:
        return json.load(handle)
first, second = provenance(a), provenance(b)
problems = []
if first.get("schema") != "xsprof/media-provenance/v1":
    problems.append("bad schema")
if first.get("host_mutation") is not False:
    problems.append("host_mutation must be false")
if first.get("no_display_capture") is not True:
    problems.append("no_display_capture must be true")
if first["frame"]["sha256"] != second["frame"]["sha256"]:
    problems.append("frame hash is not deterministic across runs")
if first["frame"]["count"] != second["frame"]["count"]:
    problems.append("frame count differs across runs")
for entry in first.get("outputs", []):
    full = os.path.join(a, os.path.basename(entry["path"]))
    if not os.path.isfile(full):
        problems.append("smoke output missing: " + entry["path"])
probe = subprocess.run(
    ["ffprobe", "-v", "error", "-select_streams", "v:0",
     "-show_entries", "stream=codec_name,width,height", "-of", "json",
     os.path.join(a, "showcase-smoke.mp4")],
    capture_output=True, text=True, check=False,
)
if probe.returncode != 0:
    problems.append("ffprobe rejected the smoke mp4")
else:
    stream = json.loads(probe.stdout)["streams"][0]
    if stream.get("codec_name") != "h264":
        problems.append("smoke mp4 is not h264")
if problems:
    for problem in problems:
        print("showcase_smoke: " + problem, file=sys.stderr)
    sys.exit(1)
print("showcase_smoke: PASS (smoke frames deterministic: " + first["frame"]["sha256"][:16] + "...)")
PY

# 3) no display capture path may exist in the media tooling.
for script in "$ROOT/tools/showcase.sh" "$ROOT/tools/record_native_showcase.sh"; do
    if grep -Eq 'x11grab|screencast|xdotool|import -window|wf-recorder' "$script"; then
        check 1 "no display capture in $script"
    else
        check 0 "no display capture in $(basename "$script")"
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "showcase_smoke: FAIL" >&2
    exit 1
fi
echo "showcase_smoke: PASS"
