#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
out_dir="zig-out/package"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
usage() { printf 'usage: %s [--out zig-out/package]\n' "$0" >&2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) [ "$#" -ge 2 ] || fail '--out requires value'; out_dir="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
case "$out_dir" in zig-out/package|zig-out/package/*) ;; *) fail '--out must remain under zig-out/package' ;; esac
case "$out_dir" in *$'\n'*|*$'\r'*|*'/../'*|../*|*/..|*/./*|./*|*/.|*'//'*) fail 'unsafe output path' ;; esac
if [ -L zig-out ]; then fail 'zig-out must not be a symlink'; fi
mkdir -p zig-out
IFS='/' read -r -a out_components <<< "$out_dir"
component_path=""
for component in "${out_components[@]}"; do
  [ -n "$component" ] || continue
  component_path="${component_path:+$component_path/}$component"
  if [ -L "$component_path" ]; then fail "package output contains symlink component: $component_path"; fi
done
out_parent="$(dirname "$out_dir")"
mkdir -p "$out_parent"
zig_out_real="$(realpath zig-out)"
out_parent_real="$(realpath "$out_parent")"
case "$out_parent_real" in "$zig_out_real"|"$zig_out_real"/*) ;; *) fail 'package output parent escapes zig-out' ;; esac
if [ -e "$out_dir" ] && [ -L "$out_dir" ]; then fail 'package output path must not be a symlink'; fi
if [ ! -x zig-out/bin/zig-scheduler ] || [ ! -x zig-out/bin/zig-scheduler-linux-preflight ] || [ ! -x zig-out/bin/zig-scheduler-daemon ]; then
  zig build install --summary all >/dev/null
fi

rm -rf "$out_dir"
staging="$out_dir/root"
mkdir -p "$staging/usr/bin" "$staging/etc/zig-scheduler" "$staging/usr/lib/systemd/system" "$staging/usr/share/doc/zig-scheduler"

install_file() {
  local src="$1" dst="$2"
  [ -f "$src" ] || fail "missing package source: $src"
  mkdir -p "$(dirname "$staging/$dst")"
  cp "$src" "$staging/$dst"
}

install_file zig-out/bin/zig-scheduler usr/bin/zig-scheduler
install_file zig-out/bin/zig-scheduler-linux-preflight usr/bin/zig-scheduler-linux-preflight
install_file zig-out/bin/zig-scheduler-daemon usr/bin/zig-scheduler-daemon
install_file packaging/config/default.toml etc/zig-scheduler/default.toml
install_file packaging/systemd/zig-scheduler-preflight.service usr/lib/systemd/system/zig-scheduler-preflight.service
install_file packaging/systemd/zig-scheduler-daemon.service usr/lib/systemd/system/zig-scheduler-daemon.service
install_file packaging/systemd/zig-scheduler-lab-mutation.service usr/lib/systemd/system/zig-scheduler-lab-mutation.service
install_file packaging/README.md usr/share/doc/zig-scheduler/README.md

git_sha="$(git rev-parse HEAD 2>/dev/null || printf unknown)"
python3 - <<'PY' "$out_dir" "$staging" "$git_sha"
import hashlib, json, sys
from pathlib import Path
out = Path(sys.argv[1])
staging = Path(sys.argv[2])
git_sha = sys.argv[3]
files = []
for path in sorted(p for p in staging.rglob('*') if p.is_file()):
    rel = path.relative_to(staging).as_posix()
    files.append({
        'path': rel,
        'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
        'mode': oct(path.stat().st_mode & 0o777),
    })
mutation_unit = staging / 'usr/lib/systemd/system/zig-scheduler-lab-mutation.service'
mutation_text = mutation_unit.read_text()
out_of_scope_terms = ['frontend', 'tui', 'webview', 'browser-ui']
manifest = {
    'schema': 'zig-scheduler/package-manifest/v1',
    'git_sha': git_sha,
    'milestone': 'vm_lab_backend_readiness',
    'production_ready': False,
    'arbitrary_host_safe': False,
    'out_of_scope_artifacts_included': any(any(term in item['path'].lower() for term in out_of_scope_terms) for item in files),
    'simulator_artifacts_included': any(item['path'].startswith('simulator/') for item in files),
    'install_root': staging.as_posix(),
    'no_auto_start': True,
    'services_not_enabled': True,
    'mutation_service_gated': all(token in mutation_text for token in [
        'ConditionPathExists=/run/zig-scheduler-vm-lab.marker',
        'ConditionPathExists=/etc/zig-scheduler/enable-lab-mutation',
        'ConditionPathExists=/var/lib/zig-scheduler/evidence/current/approval.json',
    ]),
    'mutation_service_has_wanted_by': any(line.startswith('WantedBy=') for line in mutation_text.splitlines()),
    'files': files,
    'systemd_units': [
        'usr/lib/systemd/system/zig-scheduler-preflight.service',
        'usr/lib/systemd/system/zig-scheduler-daemon.service',
        'usr/lib/systemd/system/zig-scheduler-lab-mutation.service',
    ],
}
(out / 'manifest.json.tmp').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
(out / 'manifest.json.tmp').replace(out / 'manifest.json')
PY

printf 'manifest=%s\n' "$out_dir/manifest.json"
printf 'PASS: package artifact staged without install/enable\n'
