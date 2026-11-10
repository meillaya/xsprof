#!/bin/sh
# Deterministic light/dark native screenshot evidence renderer + verifier.
#
# Renders the eight console routes in both core themes as offscreen CPU
# snapshots with `xsprof snapshot` (the same draw list the native macOS/Linux
# window consumes), compresses them with ImageMagick, and records canonical
# provenance. It never opens, activates, or captures a real window, never needs
# a display server, and never synthesizes input or mutates host policy.
#
# Committed layout (each PNG is 1280x720):
#   design/screenshots/native/dark/{home,overview,timeline,advisor,events,recorder,audit,settings}.png
#   design/screenshots/native/light/{home,overview,timeline,advisor,events,recorder,audit,settings}.png
#   design/screenshots/native/provenance.json
#
# Usage:
#   tools/screenshots.sh              # render both themes, rewrite provenance
#   tools/screenshots.sh --check      # verify committed PNGs + provenance (no magick, no render)
#   tools/screenshots.sh --out DIR    # render into DIR instead (provenance is written there too)
#   tools/screenshots.sh --keep       # keep raw snapshots from this run (debugging)
#   tools/screenshots.sh --help
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${XSPROF_BIN:-"$ROOT/zig-out/bin/xsprof"}
MAGICK=${MAGICK_BIN:-magick}
PYTHON=${PYTHON_BIN:-python3}
OUT_DIR="$ROOT/design/screenshots/native"
MODE=render
KEEP=0

W=1280
H=720
# Scene flags stay repo-relative so provenance is portable; existence checks use
# the absolute variants below. The real VM capture
# (fixtures/real/macos-vm-sched.ndjson) is not an input here: it drives the
# design/media live-replay videos, not these stills.
DEMO_REL=fixtures/ui/design/demo.json
HEALTHY_REL=fixtures/ui/healthy.ndjson
RECORDER_DIR_REL=fixtures/ui/design/recorder
DEMO="$ROOT/$DEMO_REL"
HEALTHY="$ROOT/$HEALTHY_REL"
RECORDER_DIR="$ROOT/$RECORDER_DIR_REL"
INPUTS="design demo model|$DEMO_REL
scheduler replay fixture|$HEALTHY_REL
recorder manifest fixture|$RECORDER_DIR_REL/manifest.json"

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit "$1"
}

fail() { echo "screenshots: FAIL: $*" >&2; exit 1; }
note() { echo "screenshots: $*"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE=check ;;
        --keep) KEEP=1 ;;
        --out)
            shift
            if [ $# -eq 0 ]; then usage 2; fi
            case "$1" in
                /*) OUT_DIR=$1 ;;
                *) OUT_DIR="$PWD/$1" ;;
            esac
            ;;
        -h|--help) usage 0 ;;
        *) echo "screenshots: unknown option $1" >&2; usage 2 ;;
    esac
    shift
done

# Verify the committed set against provenance. Reads only PNG bytes/headers and
# JSON: no renderer binary, no ImageMagick, no display server.
run_check() {
    need_cmd "$PYTHON"
    [ -f "$OUT_DIR/provenance.json" ] || fail "provenance missing: $OUT_DIR/provenance.json"
    "$PYTHON" - "$ROOT" "$OUT_DIR" <<'PY'
import hashlib, json, os, struct, sys

root, out_dir = sys.argv[1], sys.argv[2]
prov_path = os.path.join(out_dir, "provenance.json")
failures = []


def fail(message):
    failures.append(message)


def digest(blob):
    return hashlib.sha256(blob).hexdigest()


def png_size(blob):
    if blob[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    if blob[12:16] != b"IHDR":
        return None
    width = int.from_bytes(blob[16:20], "big")
    height = int.from_bytes(blob[20:24], "big")
    return (width, height)


def png_chunks(blob):
    chunks = []
    offset = 8
    while offset + 12 <= len(blob):
        length = int.from_bytes(blob[offset:offset + 4], "big")
        chunk_type = blob[offset + 4:offset + 8].decode("ascii", "replace")
        chunks.append(chunk_type)
        offset += 12 + length
        if chunk_type == "IEND":
            break
    return chunks


with open(prov_path, "rb") as handle:
    raw = handle.read()
try:
    data = json.loads(raw)
except Exception as exc:
    print("screenshots: provenance is not valid JSON: " + str(exc), file=sys.stderr)
    sys.exit(1)

canonical = (json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n").encode()
if raw != canonical:
    fail("provenance is not canonical JSON (sorted keys, compact separators, trailing newline)")

required = {"schema", "host_mutation", "renderer", "convert", "themes", "inputs", "files"}
missing = required - set(data)
if missing:
    fail("provenance missing keys: " + repr(sorted(missing)))
if data.get("schema") != "xsprof/screenshot-provenance/v1":
    fail("bad schema: " + repr(data.get("schema")))
if data.get("host_mutation") is not False:
    fail("host_mutation must be false")

renderer = data.get("renderer", {})
if renderer.get("backend") != "cpu":
    fail("renderer.backend must be cpu")
if renderer.get("window") is not False:
    fail("renderer.window must be false")
if renderer.get("display_capture") is not False:
    fail("renderer.display_capture must be false")
if renderer.get("offscreen") is not True:
    fail("renderer.offscreen must be true")
if renderer.get("width") != 1280 or renderer.get("height") != 720:
    fail("renderer dimensions must be 1280x720")
for key in ("command", "version"):
    if not isinstance(renderer.get(key), str) or not renderer.get(key):
        fail("renderer." + key + " must be a non-empty string")

convert = data.get("convert", {})
for key in ("command", "version"):
    if not isinstance(convert.get(key), str) or not convert.get(key):
        fail("convert." + key + " must be a non-empty string")
if "png:compression-level=9" not in str(convert.get("command", "")):
    fail("convert.command must record the png:compression-level=9 compression")

expected_scene_views = {"home": "home", "overview": "overview", "timeline": "timeline",
                        "advisor": "advisor", "events": "events", "recorder": "capture",
                        "audit": "audit", "settings": "settings"}
expected_scenes = list(expected_scene_views)
expected_themes = {"dark": "dark", "light": "paper"}
ok_lines = []
themes = data.get("themes", [])
seen_themes = {}
for entry in themes:
    theme_dir = entry.get("dir")
    if theme_dir not in expected_themes:
        fail("unexpected theme dir in provenance: " + repr(theme_dir))
        continue
    if entry.get("id") != expected_themes[theme_dir]:
        fail("theme " + theme_dir + " id must be " + expected_themes[theme_dir])
    if entry.get("kind") != ("dark" if theme_dir == "dark" else "light"):
        fail("theme " + theme_dir + " has the wrong kind")
    if not isinstance(entry.get("name"), str) or not entry.get("name"):
        fail("theme " + theme_dir + " must record a display name")
    seen_themes[theme_dir] = entry
if set(seen_themes) != {"dark", "light"} or len(themes) != 2:
    fail("provenance must describe exactly the dark and light themes")

inputs = data.get("inputs", [])
if not isinstance(inputs, list) or not inputs:
    fail("provenance must record at least one input fixture")
input_paths = set()
for entry in inputs:
    rel = entry.get("path")
    if not isinstance(rel, str) or not rel:
        fail("input without a path")
        continue
    input_paths.add(rel)
    full = os.path.join(root, rel)
    if not os.path.isfile(full):
        fail("input missing: " + rel)
        continue
    with open(full, "rb") as handle:
        if digest(handle.read()) != entry.get("sha256"):
            fail("input sha256 mismatch: " + rel)
for rel in ("fixtures/ui/design/demo.json", "fixtures/ui/healthy.ndjson",
            "fixtures/ui/design/recorder/manifest.json"):
    if rel not in input_paths:
        fail("input fixture not recorded: " + rel)

files = data.get("files", [])
if not isinstance(files, list):
    fail("provenance.files must be a list")
    files = []
if len(files) != len(expected_themes) * len(expected_scenes):
    fail("provenance must describe 16 files, found " + str(len(files)))
seen = set()
for entry in files:
    for key in ("path", "sha256", "bytes", "width", "height", "theme", "view", "flags"):
        if key not in entry:
            fail("file entry missing " + key + ": " + repr(entry.get("path")))
    theme = entry.get("theme")
    scene = entry.get("scene")
    view = entry.get("view")
    theme_dir = None
    for candidate, theme_id in expected_themes.items():
        if theme == theme_id:
            theme_dir = candidate
    if theme_dir is None:
        fail("file entry has unknown theme: " + repr(theme))
        continue
    if scene not in expected_scene_views:
        fail("file entry has unknown scene: " + repr(scene))
        continue
    if view != expected_scene_views[scene]:
        fail("file entry view does not match its scene: " + str(scene) + " -> " + repr(view))
    if (theme_dir, scene) in seen:
        fail("duplicate file entry: " + theme_dir + "/" + str(scene))
    seen.add((theme_dir, scene))
    rel = entry.get("path")
    if not isinstance(rel, str) or not rel:
        fail("file entry without a path")
        continue
    full = os.path.join(root, rel)
    expected_path = os.path.join(out_dir, theme_dir, str(scene) + ".png")
    if os.path.realpath(full) != os.path.realpath(expected_path):
        fail("file path does not match layout: " + rel + " (expected " + expected_path + ")")
    if not os.path.isfile(full):
        fail("committed screenshot missing: " + rel)
        continue
    with open(full, "rb") as handle:
        blob = handle.read()
    if digest(blob) != entry.get("sha256"):
        fail("sha256 mismatch: " + rel)
    if len(blob) != entry.get("bytes"):
        fail("byte size mismatch: " + rel + " (" + str(len(blob)) + " != " + str(entry.get("bytes")) + ")")
    size = png_size(blob)
    if size is None:
        fail("not a PNG with a readable IHDR: " + rel)
    else:
        if size != (entry.get("width"), entry.get("height")):
            fail("dimension mismatch: " + rel + " " + repr(size))
        if size != (1280, 720):
            fail("screenshot must be 1280x720: " + rel)
    chunks = png_chunks(blob)
    if any(chunk in ("tEXt", "zTXt", "iTXt", "tIME", "eXIf") for chunk in chunks):
        fail("screenshot carries metadata chunks (strip failed): " + rel)
    flags = entry.get("flags")
    if not isinstance(flags, list) or not flags:
        fail("file entry must record scene flags: " + rel)
    elif "--view" not in flags or str(view) not in flags:
        fail("scene flags do not select the recorded view: " + rel)
    ok_lines.append("screenshots: ok " + theme_dir + "/" + str(scene) + ".png " +
                    str(entry.get("width")) + "x" + str(entry.get("height")) + " " +
                    str(entry.get("bytes")) + " B sha256=" + str(entry.get("sha256"))[:16] + "...")
missing_scenes = [(theme_dir, scene) for theme_dir in expected_themes for scene in expected_scenes
                  if (theme_dir, scene) not in seen]
for theme_dir, scene in missing_scenes:
    fail("provenance does not describe " + theme_dir + "/" + scene + ".png")

for theme_dir in expected_themes:
    directory = os.path.join(out_dir, theme_dir)
    if not os.path.isdir(directory):
        fail("committed theme directory missing: " + directory)
        continue
    expected_names = {scene + ".png" for scene in expected_scenes}
    actual_names = set(os.listdir(directory))
    for name in sorted(expected_names - actual_names):
        fail("missing committed screenshot: " + theme_dir + "/" + name)
    for name in sorted(actual_names - expected_names):
        fail("unexpected file in committed theme directory: " + theme_dir + "/" + name)

if failures:
    for failure in failures:
        print("screenshots: " + failure, file=sys.stderr)
    sys.exit(1)
for line in ok_lines:
    print(line)
print("screenshots: check PASS (16 files, 2 themes, 8 routes; sha256, byte size, "
      "1280x720 dimensions and canonical provenance verified)")
PY
}

if [ "$MODE" = check ]; then
    run_check
    exit 0
fi

[ -x "$BIN" ] || fail "binary missing: $BIN (run ./tools/zig build)"
[ -f "$DEMO" ] || fail "missing fixture: $DEMO"
[ -f "$HEALTHY" ] || fail "missing fixture: $HEALTHY"
[ -f "$RECORDER_DIR/manifest.json" ] || fail "missing fixture: $RECORDER_DIR/manifest.json"
need_cmd "$PYTHON"
need_cmd "$MAGICK"

cd "$ROOT"
TMP=$(mktemp -d)
cleanup() {
    if [ "$KEEP" = 1 ]; then
        echo "screenshots: kept raw snapshots in $TMP" >&2
    else
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT HUP INT TERM
FILES_TSV="$TMP/files.tsv"
: >"$FILES_TSV"
mkdir -p "$OUT_DIR"

render_shot() {
    theme_dir=$1
    theme_id=$2
    scene=$3
    view=$4
    shift 4
    raw="$TMP/$theme_dir-$scene-raw.png"
    "$BIN" snapshot "$@" --theme "$theme_id" --width "$W" --height "$H" --out "$raw" >/dev/null \
        || fail "snapshot failed: theme=$theme_dir ($theme_id) scene=$scene"
    mkdir -p "$OUT_DIR/$theme_dir"
    "$MAGICK" "$raw" -strip -define png:compression-level=9 "$OUT_DIR/$theme_dir/$scene.png" \
        || fail "compression failed: $theme_dir/$scene (ImageMagick)"
    printf '%s\t%s\t%s\t%s\n' "$theme_dir" "$scene" "$view" "$*" >>"$FILES_TSV"
    note "rendered $theme_dir/$scene.png"
}

render_theme() {
    theme_dir=$1
    case "$theme_dir" in
        dark) theme_id=dark ;;
        light) theme_id=paper ;;
        *) fail "unknown theme directory $theme_dir" ;;
    esac
    # Scene flags mirror tools/showcase.sh render_showcase_frames(); snapshots
    # stay offscreen and never read user settings or host state.
    render_shot "$theme_dir" "$theme_id" home home \
        --demo-model "$DEMO_REL" --view home
    render_shot "$theme_dir" "$theme_id" overview overview \
        --replay "$HEALTHY_REL" --view overview
    render_shot "$theme_dir" "$theme_id" timeline timeline \
        --replay "$HEALTHY_REL" --view timeline --playhead 6.0
    render_shot "$theme_dir" "$theme_id" advisor advisor \
        --replay "$HEALTHY_REL" --view advisor
    render_shot "$theme_dir" "$theme_id" events events \
        --replay "$HEALTHY_REL" --view events
    render_shot "$theme_dir" "$theme_id" recorder capture \
        --replay "$HEALTHY_REL" --recorder-dir "$RECORDER_DIR_REL" --view capture
    render_shot "$theme_dir" "$theme_id" audit audit \
        --replay "$HEALTHY_REL" --view audit
    render_shot "$theme_dir" "$theme_id" settings settings \
        --demo-model "$DEMO_REL" --view settings
}

render_theme dark
render_theme light

BIN_VERSION=$("$BIN" version 2>/dev/null | head -1) || fail "cannot read xsprof version"
MAGICK_VERSION=$("$MAGICK" -version 2>/dev/null | head -1) || fail "cannot read ImageMagick version"
[ -n "$BIN_VERSION" ] || fail "empty xsprof version"
[ -n "$MAGICK_VERSION" ] || fail "empty ImageMagick version"

"$PYTHON" - "$ROOT" "$OUT_DIR" "$FILES_TSV" "$W" "$H" "$BIN_VERSION" "$MAGICK_VERSION" "$INPUTS" <<'PY'
import hashlib, json, os, sys

(root, out_dir, files_tsv, width, height, bin_version, magick_version, inputs_blob) = sys.argv[1:]
width, height = int(width), int(height)


def rel(path):
    return os.path.relpath(os.path.abspath(path), root)


def digest(path):
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def png_size(path):
    with open(path, "rb") as handle:
        header = handle.read(24)
    if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise SystemExit("screenshots: not a PNG: " + path)
    return (int.from_bytes(header[16:20], "big"), int.from_bytes(header[20:24], "big"))


inputs = []
for line in inputs_blob.splitlines():
    kind, path = line.split("|", 1)
    full = os.path.join(root, path)
    if not os.path.isfile(full):
        raise SystemExit("screenshots: missing input fixture: " + path)
    inputs.append({"kind": kind, "path": rel(full), "sha256": digest(full)})

theme_meta = {
    "dark": {"dir": "dark", "id": "dark", "kind": "dark", "name": "Graphite"},
    "light": {"dir": "light", "id": "paper", "kind": "light", "name": "Paper"},
}
files = []
with open(files_tsv, "r", encoding="utf-8") as handle:
    for line in handle:
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 4:
            raise SystemExit("screenshots: bad scene record: " + repr(line))
        theme_dir, scene, view, flag_text = parts
        if theme_dir not in theme_meta:
            raise SystemExit("screenshots: unknown theme dir in scene record: " + theme_dir)
        path = os.path.join(out_dir, theme_dir, scene + ".png")
        if not os.path.isfile(path):
            raise SystemExit("screenshots: missing rendered file: " + path)
        actual = png_size(path)
        if actual != (width, height):
            raise SystemExit("screenshots: unexpected dimensions for " + path + ": " + repr(actual))
        meta = theme_meta[theme_dir]
        files.append({
            "bytes": os.path.getsize(path),
            "flags": flag_text.split(" "),
            "height": height,
            "path": rel(path),
            "scene": scene,
            "sha256": digest(path),
            "theme": meta["id"],
            "view": view,
            "width": width,
        })

files.sort(key=lambda entry: entry["path"])
themes = [theme_meta["dark"], theme_meta["light"]]
data = {
    "convert": {
        "command": "magick FILE -strip -define png:compression-level=9 OUT",
        "tool": "magick",
        "version": magick_version,
    },
    "files": files,
    "host_mutation": False,
    "inputs": inputs,
    "note": "Offscreen CPU rasterizer snapshots. No window opened/activated/captured, "
            "no display server or synthetic input, no host policy read or written.",
    "renderer": {
        "backend": "cpu",
        "command": "zig-out/bin/xsprof snapshot <scene flags> --theme <dark|paper> "
                   "--width 1280 --height 720 --out <file>",
        "display_capture": False,
        "height": height,
        "offscreen": True,
        "version": bin_version,
        "width": width,
        "window": False,
    },
    "schema": "xsprof/screenshot-provenance/v1",
    "themes": themes,
}
canonical = json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n"
provenance_path = os.path.join(out_dir, "provenance.json")
with open(provenance_path, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(canonical)
print("screenshots: wrote " + rel(provenance_path) + " (" + str(len(files)) + " files, " +
      str(len(themes)) + " themes)")
PY

note "render PASS (16 files, 2 themes, 8 views; provenance rewritten)"
