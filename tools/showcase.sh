#!/bin/sh
# Headless native showcase renderer + media encoder.
#
# Renders deterministic CPU snapshots with `xsprof snapshot` (the same draw
# list the native macOS/Linux window consumes), holds/animated frames into a
# numbered sequence, and encodes H.264 MP4 + palette GIF with ffmpeg. It never
# opens, activates, or captures a real window and has no display-server or
# screen-grab path: all pixels come from the CPU rasterizer. Provenance JSON
# records inputs, scene flags, frame hashes, and outputs so the media stays
# auditable.
#
# Usage:
#   tools/showcase.sh                 # render design/media native showcase + live replay
#   tools/showcase.sh --smoke         # tiny deterministic pipeline check output
#   tools/showcase.sh --check         # verify committed media + provenance, no render
#   tools/showcase.sh --frames-only   # render frames, skip ffmpeg
#   tools/showcase.sh --out DIR       # destination directory
#   tools/showcase.sh --no-captions   # skip ffmpeg drawtext captions
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN="$ROOT/zig-out/bin/xsprof"
if [ -n "$XSPROF_BIN" ]; then BIN=$XSPROF_BIN; fi
FFMPEG=ffmpeg
if [ -n "$FFMPEG_BIN" ]; then FFMPEG=$FFMPEG_BIN; fi
FFPROBE=ffprobe
if [ -n "$FFPROBE_BIN" ]; then FFPROBE=$FFPROBE_BIN; fi
FONT="$ROOT/lib/xsui/assets/fonts/JetBrainsMono-Regular.ttf"
OUT_DIR="$ROOT/design/media"
MODE=full
CAPTIONS=1
KEEP=0

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit "$1"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --smoke) MODE=smoke ;;
        --check) MODE=check ;;
        --frames-only) MODE=frames ;;
        --out)
            shift
            if [ $# -eq 0 ]; then usage 2; fi
            OUT_DIR=$1
            ;;
        --no-captions) CAPTIONS=0 ;;
        --keep) KEEP=1 ;;
        -h|--help) usage 0 ;;
        *) echo "showcase: unknown option $1" >&2; usage 2 ;;
    esac
    shift
done

fail() { echo "showcase: FAIL: $*" >&2; exit 1; }
note() { echo "showcase: $*"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }

run_check() {
    need_cmd sha256sum
    need_cmd python3
    [ -d "$OUT_DIR" ] || fail "media directory missing: $OUT_DIR"
    python3 - "$ROOT" "$OUT_DIR" <<'PY'
import hashlib, json, os, sys
root, out_dir = sys.argv[1], sys.argv[2]
required = {"schema", "host_mutation", "renderer", "frame", "scenes", "inputs", "outputs"}
failures = []
provenance = sorted(
    os.path.join(out_dir, name)
    for name in os.listdir(out_dir)
    if name.endswith(".provenance.json")
)
if not provenance:
    failures.append("no *.provenance.json files in " + out_dir)
for path in provenance:
    with open(path, "rb") as handle:
        raw = handle.read()
    try:
        data = json.loads(raw)
    except Exception as exc:
        failures.append(path + ": invalid JSON (" + str(exc) + ")")
        continue
    canonical = (json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n").encode()
    if raw != canonical:
        failures.append(path + ": provenance is not canonical JSON")
    missing = required - set(data)
    if missing:
        failures.append(path + ": missing keys " + repr(sorted(missing)))
        continue
    if data.get("schema") != "xsprof/media-provenance/v1":
        failures.append(path + ": bad schema")
    if data.get("host_mutation") is not False:
        failures.append(path + ": host_mutation must be false")
    if data.get("no_display_capture") is not True:
        failures.append(path + ": no_display_capture must be true")
    frame = data.get("frame", {})
    if not isinstance(frame.get("count"), int) or frame.get("count", 0) <= 0:
        failures.append(path + ": frame.count must be positive")
    for entry in data.get("inputs", []):
        rel = entry.get("path")
        if not rel:
            failures.append(path + ": input without path")
            continue
        full = os.path.join(root, rel)
        if not os.path.isfile(full):
            failures.append(path + ": input missing: " + rel)
            continue
        digest = hashlib.sha256(open(full, "rb").read()).hexdigest()
        if digest != entry.get("sha256"):
            failures.append(path + ": input sha256 mismatch: " + rel)
    for entry in data.get("outputs", []):
        rel = entry.get("path")
        if not rel:
            failures.append(path + ": output without path")
            continue
        full = os.path.join(root, rel)
        if not os.path.isfile(full):
            failures.append(path + ": output missing: " + rel)
            continue
        blob = open(full, "rb").read()
        if hashlib.sha256(blob).hexdigest() != entry.get("sha256"):
            failures.append(path + ": output sha256 mismatch: " + rel)
        if len(blob) != entry.get("bytes"):
            failures.append(path + ": output size mismatch: " + rel)
    if not failures:
        outputs = ", ".join(os.path.basename(item.get("path", "?")) for item in data.get("outputs", []))
        print("showcase: provenance OK: " + os.path.basename(path) + " (" + outputs + ", frames=" + str(frame.get("count")) + ")")
if failures:
    for failure in failures:
        print("showcase: " + failure, file=sys.stderr)
    sys.exit(1)
PY
    for script in "$ROOT/tools/showcase.sh" "$ROOT/tools/record_native_showcase.sh"; do
        [ -f "$script" ] || fail "missing $script"
    done
    note "check PASS (committed media + provenance verified)"
}

if [ "$MODE" = check ]; then
    run_check
    exit 0
fi

[ -x "$BIN" ] || fail "binary missing: $BIN (run ./tools/zig build)"
need_cmd python3
need_cmd sha256sum
need_cmd awk
if [ "$MODE" != frames ]; then
    need_cmd "$FFMPEG"
    need_cmd "$FFPROBE"
fi

TMP=$(mktemp -d)
cleanup() {
    if [ "$KEEP" = 1 ]; then
        echo "showcase: kept frames in $TMP" >&2
    else
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT HUP INT TERM

DEMO="$ROOT/fixtures/ui/design/demo.json"
HEALTHY="$ROOT/fixtures/ui/healthy.ndjson"
REAL="$ROOT/fixtures/real/macos-vm-sched.ndjson"
RECORDER_DIR="$ROOT/fixtures/ui/design/recorder"
[ -f "$DEMO" ] || fail "missing $DEMO"
[ -f "$HEALTHY" ] || fail "missing $HEALTHY"
[ -f "$REAL" ] || fail "missing $REAL"

mkdir -p "$OUT_DIR"
IDX=0
SCENES="$TMP/scenes.tsv"
: >"$SCENES"

record_scene() {
    printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >>"$SCENES"
}

frame_path() { printf '%s/%05d.png' "$FRAMES" "$1"; }

emit() {
    out=$(printf '%s/emit-%05d.png' "$TMP" "$IDX")
    "$BIN" snapshot "$@" --width "$W" --height "$H" --out "$out" >/dev/null
    mv "$out" "$(frame_path "$IDX")"
    IDX=$((IDX + 1))
}

scene_still() {
    scene_id=$1
    scene_caption=$2
    scene_frames=$3
    shift 3
    start=$IDX
    emit "$@"
    i=1
    while [ "$i" -lt "$scene_frames" ]; do
        ln "$(frame_path "$start")" "$(frame_path "$IDX")" 2>/dev/null || \
            cp "$(frame_path "$start")" "$(frame_path "$IDX")"
        IDX=$((IDX + 1))
        i=$((i + 1))
    done
    record_scene "$scene_id" "$start" "$scene_frames" "$scene_caption"
}

scene_onboarding() {
    scene_id=$1
    scene_caption=$2
    hold=$3
    demo=$4
    start=$IDX
    step=0
    while [ "$step" -lt 4 ]; do
        emit --demo-model "$demo" --view home --overlay onboarding --onboarding-step "$step"
        i=1
        while [ "$i" -lt "$hold" ]; do
            ln "$(frame_path "$((IDX - 1))")" "$(frame_path "$IDX")" 2>/dev/null || \
                cp "$(frame_path "$((IDX - 1))")" "$(frame_path "$IDX")"
            IDX=$((IDX + 1))
            i=$((i + 1))
        done
        step=$((step + 1))
    done
    record_scene "$scene_id" "$start" "$((IDX - start))" "$scene_caption"
}

scene_timeline_anim() {
    scene_id=$1
    scene_caption=$2
    scene_frames=$3
    replay=$4
    t0=$5
    t1=$6
    start=$IDX
    i=0
    while [ "$i" -lt "$scene_frames" ]; do
        playhead=$(awk "BEGIN { printf \"%.6f\", $t0 + ($t1 - $t0) * $i / ($scene_frames - 1) }")
        emit --replay "$replay" --view timeline --playhead "$playhead"
        i=$((i + 1))
    done
    record_scene "$scene_id" "$start" "$scene_frames" "$scene_caption"
}

render_showcase_frames() {
    scene_still home "Home - one capture, every view" 30 --demo-model "$DEMO" --view home
    scene_onboarding onboarding "First-run onboarding - read-only contract" 18 "$DEMO"
    scene_still picker "GPU picker - real bounded directory listing" 30 --demo-model "$DEMO" --view home --overlay picker --picker-dir "$ROOT/fixtures/ui/design"
    scene_still overview "Scheduler capture - REPLAY - host_mutation=false" 30 --replay "$HEALTHY" --view overview
    scene_timeline_anim timeline "Timeline - replay transport, no host reads" 45 "$HEALTHY" 0.5 12.0
    scene_still advisor "Advisor - suggestions only, never applied" 22 --replay "$HEALTHY" --view advisor
    scene_still events "Events ledger - sanitized scheduler events" 22 --replay "$HEALTHY" --view events
    scene_still recorder "Recorder - read-only status and retention" 30 --replay "$HEALTHY" --recorder-dir "$RECORDER_DIR" --view capture
    scene_still audit "Audit - local action log, no telemetry" 22 --replay "$HEALTHY" --view audit
    scene_still settings "Settings - appearance, capture, accessibility" 30 --demo-model "$DEMO" --view settings
    scene_still a11y "Accessibility - labels, roles, focus order" 30 --demo-model "$DEMO" --view settings --focus 3412
    scene_still export "Export - journal, trace, report, incident" 30 --demo-model "$DEMO" --view home --palette-query export
    scene_still real "Real VM perf capture - REPLAY - host_mutation=false" 38 --replay "$REAL" --view overview
}

render_live_replay_frames() {
    EXCERPT="$TMP/real-excerpt.ndjson"
    EXCERPT_LINES=12000
    head -n "$EXCERPT_LINES" "$REAL" >"$EXCERPT"
    SPAN=$(python3 - "$EXCERPT" <<'PY'
import json, sys
lo, hi = None, None
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except Exception:
            continue
        ts = entry.get("ts_ns")
        if not isinstance(ts, int):
            continue
        lo = ts if lo is None else min(lo, ts)
        hi = ts if hi is None else max(hi, ts)
print(f"{(hi - lo) / 1e9:.6f}" if lo is not None and hi is not None else "0.100")
PY
)
    scene_still lr_overview "REAL VM CAPTURE - REPLAY - host_mutation=false" 38 --replay "$REAL" --view overview
    scene_timeline_anim lr_timeline "Timeline - real vCPU scheduler capture" 60 "$EXCERPT" 0.002 "$(awk "BEGIN { printf \"%.6f\", $SPAN * 0.85 }")"
    scene_still lr_events "Real perf events - REPLAY, sanitized" 30 --replay "$EXCERPT" --view events
    scene_still lr_audit "Local audit - no telemetry, no mutation" 30 --replay "$EXCERPT" --view audit
}

render_smoke_frames() {
    scene_still s_home "smoke - home" 6 --demo-model "$DEMO" --view home
    scene_timeline_anim s_timeline "smoke - timeline" 6 "$HEALTHY" 0.5 3.0
}

write_provenance() {
    name=$1
    mp4=$2
    gif=$3
    provenance=$4
    inputs_json=$5
    # Hash frame *contents* only. sha256sum includes the (random) temp path, so
    # folding raw output would make provenance differ between runs.
    frames_hash=$(for frame in "$FRAMES"/*.png; do sha256sum "$frame" | awk '{print $1}'; done | sha256sum | awk '{print $1}')
    ffmpeg_version=$("$FFMPEG" -hide_banner -version 2>/dev/null | head -1)
    python3 - "$ROOT" "$name" "$mp4" "$gif" "$provenance" "$SCENES" "$frames_hash" "$W" "$H" "$FPS" "$IDX" "$ffmpeg_version" "$inputs_json" "$FFPROBE" "$CAPTIONS" <<'PY'
import hashlib, json, os, subprocess, sys
(root, name, mp4, gif, provenance, scenes_tsv, frames_hash,
 width, height, fps, frame_count, ffmpeg_version, inputs_json,
 ffprobe_bin, captions) = sys.argv[1:]
def rel(path):
    return os.path.relpath(os.path.abspath(path), root)
def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()
scenes = []
with open(scenes_tsv, "r", encoding="utf-8") as handle:
    for line in handle:
        parts = line.rstrip("\n").split("|")
        if len(parts) != 4:
            continue
        scenes.append({
            "id": parts[0],
            "start_frame": int(parts[1]),
            "frames": int(parts[2]),
            "caption": parts[3],
        })
def probe(path):
    out = subprocess.run(
        [ffprobe_bin, "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=codec_name,width,height:format=duration",
         "-of", "json", path],
        check=True, capture_output=True, text=True,
    ).stdout
    data = json.loads(out)
    stream = data["streams"][0]
    return (stream.get("codec_name", ""), int(stream.get("width", 0)),
            int(stream.get("height", 0)), float(data["format"].get("duration", 0.0)))
outputs = []
for path in (mp4, gif):
    if not path or not os.path.isfile(path):
        continue
    codec, w, h, duration = probe(path)
    outputs.append({
        "path": rel(path),
        "bytes": os.path.getsize(path),
        "sha256": digest(path),
        "codec": codec,
        "width": w,
        "height": h,
        "duration_s": round(duration, 3),
    })
inputs = json.loads(inputs_json)
for entry in inputs:
    full = os.path.join(root, entry["path"])
    entry["sha256"] = digest(full) if os.path.isfile(full) else ""
data = {
    "schema": "xsprof/media-provenance/v1",
    "host_mutation": False,
    "name": name,
    "renderer": {
        "binary": "zig-out/bin/xsprof snapshot",
        "backend": "cpu",
        "offscreen": True,
        "window": False,
    },
    "no_display_capture": True,
    "frame": {
        "width": int(width),
        "height": int(height),
        "fps": int(fps),
        "count": int(frame_count),
        "sha256": frames_hash,
    },
    "captions": bool(int(captions)),
    "ffmpeg": ffmpeg_version,
    "scenes": scenes,
    "inputs": inputs,
    "outputs": outputs,
    "notes": "Deterministic CPU snapshots; no window, display-server capture, or network.",
}
with open(provenance, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n")
print("showcase: provenance written: " + os.path.basename(provenance))
PY
}

caption_filter() {
    python3 - "$SCENES" "$FPS" "$FONT" "$CAPTIONS" <<'PY'
import sys
scenes_tsv, fps, font, captions = sys.argv[1:]
fps = int(fps)
parts = []
if int(captions) == 1:
    with open(scenes_tsv, "r", encoding="utf-8") as handle:
        for line in handle:
            fields = line.rstrip("\n").split("|")
            if len(fields) != 4:
                continue
            start = int(fields[1]) / fps
            end = (int(fields[1]) + int(fields[2])) / fps
            window = "gte(t," + format(start, ".3f") + ")*lt(t," + format(end, ".3f") + ")"
            text = fields[3].replace("'", "").replace(":", " -").replace(",", "")
            # Lower-third band above the app keybar, then the caption text.
            parts.append(
                "drawbox=x=0:y=ih-102:w=iw:h=58:color=black@0.96:t=fill:enable='" + window + "'"
            )
            parts.append(
                "drawtext=fontfile=" + font +
                ":text='" + text + "'" +
                ":x=24:y=h-91:fontsize=17:fontcolor=white@0.95" +
                ":enable='" + window + "'"
            )
    parts.append(
        "drawtext=fontfile=" + font +
        ":text='NATIVE - OFFSCREEN CPU RENDER':x=w-tw-24:y=h-91:fontsize=13" +
        ":fontcolor=white@0.55"
    )
parts.append("format=yuv420p")
print(",".join(parts))
PY
}

encode_pair() {
    name=$1
    mp4=$2
    gif=$3
    if [ "$MODE" = frames ]; then
        note "frames rendered for $name (ffmpeg skipped)"
        return 0
    fi
    vf=$(caption_filter)
    note "encoding $name ($IDX frames @ $FPS fps)"
    "$FFMPEG" -hide_banner -loglevel error -y -framerate "$FPS" -i "$FRAMES/%05d.png" \
        -vf "$vf" -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p \
        -fflags +bitexact -flags:v +bitexact -map_metadata -1 -movflags +faststart "$mp4"
    "$FFMPEG" -hide_banner -loglevel error -y -i "$mp4" \
        -vf "fps=10,scale=640:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=160[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3" \
        -loop 0 "$gif"
}

# --- mode setup ------------------------------------------------------------
if [ "$MODE" = smoke ]; then
    W=480
    H=270
    FPS=10
    FRAMES="$TMP/frames"
    mkdir -p "$FRAMES"
    render_smoke_frames
    mkdir -p "$OUT_DIR"
    encode_pair showcase-smoke "$OUT_DIR/showcase-smoke.mp4" "$OUT_DIR/showcase-smoke.gif"
    write_provenance "native-showcase-smoke" "$OUT_DIR/showcase-smoke.mp4" "$OUT_DIR/showcase-smoke.gif" \
        "$OUT_DIR/showcase-smoke.provenance.json" \
        '[{"path":"fixtures/ui/design/demo.json","kind":"design demo model"},{"path":"fixtures/ui/healthy.ndjson","kind":"real scheduler capture"}]'
    note "smoke PASS: $OUT_DIR/showcase-smoke.mp4 + .gif + provenance"
    exit 0
fi

if [ "$MODE" = frames ]; then
    FRAMES="$OUT_DIR/frames"
    rm -rf "$FRAMES"
    mkdir -p "$FRAMES"
else
    FRAMES="$TMP/frames"
    mkdir -p "$FRAMES"
fi
W=1280
H=720
FPS=15

render_showcase_frames
showcase_mp4="$OUT_DIR/xsprof-native-showcase.mp4"
showcase_gif="$OUT_DIR/xsprof-native-showcase.gif"
encode_pair "native-showcase" "$showcase_mp4" "$showcase_gif"
write_provenance "native-showcase" "$showcase_mp4" "$showcase_gif" \
    "$OUT_DIR/xsprof-native-showcase.provenance.json" \
    '[{"path":"fixtures/ui/design/demo.json","kind":"design demo model"},{"path":"fixtures/ui/healthy.ndjson","kind":"real scheduler capture"},{"path":"fixtures/real/macos-vm-sched.ndjson","kind":"real VM perf capture"},{"path":"fixtures/ui/design/recorder/manifest.json","kind":"recorder manifest fixture"}]'
showcase_frames=$IDX

IDX=0
: >"$SCENES"
FRAMES="$TMP/frames-live"
mkdir -p "$FRAMES"
render_live_replay_frames
live_mp4="$OUT_DIR/xsprof-native-live-replay.mp4"
live_gif="$OUT_DIR/xsprof-native-live-replay.gif"
encode_pair "native-live-replay" "$live_mp4" "$live_gif"
write_provenance "native-live-replay" "$live_mp4" "$live_gif" \
    "$OUT_DIR/xsprof-native-live-replay.provenance.json" \
    '[{"path":"fixtures/real/macos-vm-sched.ndjson","kind":"real VM perf capture"},{"path":"fixtures/ui/healthy.ndjson","kind":"real scheduler capture"}]'

if [ "$MODE" != frames ]; then
    note "full PASS: $OUT_DIR (showcase $showcase_frames frames, live replay $IDX frames)"
fi
