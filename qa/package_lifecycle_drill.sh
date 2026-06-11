#!/usr/bin/env bash
set -euo pipefail
root=""
manifest="zig-out/package/manifest.json"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
usage() { printf 'usage: %s --root <tmp-root> --manifest zig-out/package/manifest.json\n' "$0" >&2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) [ "$#" -ge 2 ] || fail '--root requires value'; root="$2"; shift 2 ;;
    --manifest) [ "$#" -ge 2 ] || fail '--manifest requires value'; manifest="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[ -n "$root" ] || fail '--root is required'
case "$root$manifest" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
case "$root" in /|/etc|/usr|/var|/run|/sys|/proc|/boot|/home|/root) fail 'refusing host root path' ;; esac
[ -d "$root" ] || fail 'root must be an existing temp directory'
[ -f "$manifest" ] || fail 'manifest missing'
python3 - <<'PY' "$root" "$manifest"
import hashlib, json, shutil, sys
from pathlib import Path
root = Path(sys.argv[1]).resolve()
manifest = Path(sys.argv[2])
data = json.loads(manifest.read_text())
install_root = Path(str(data['install_root']))
files = [str(item['path']) for item in data['files']]
if not str(root).startswith('/tmp/'):
    raise SystemExit('staging root must be under /tmp')
if data.get('no_auto_start') is not True or data.get('services_not_enabled') is not True:
    raise SystemExit('manifest is not no-auto-start')

def copy_file(rel: str, preserve_config: bool) -> None:
    src = install_root / rel
    dst = root / rel
    if preserve_config and rel.startswith('etc/zig-scheduler/') and dst.exists():
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)

def install(preserve_config: bool) -> None:
    for rel in files:
        copy_file(rel, preserve_config)
    wants = root / 'etc/systemd/system/multi-user.target.wants'
    if wants.exists() and any(wants.iterdir()):
        raise SystemExit('service was enabled')
    mutation = root / 'usr/lib/systemd/system/zig-scheduler-lab-mutation.service'
    if 'WantedBy=' in mutation.read_text():
        raise SystemExit('mutation unit install-enables')

install(preserve_config=False)
config = root / 'etc/zig-scheduler/default.toml'
config.write_text(config.read_text() + '\n# local-admin-change: preserve across upgrade\n')
evidence_archive = root / 'var/lib/zig-scheduler/evidence/archive'
evidence_archive.mkdir(parents=True, exist_ok=True)
archive = evidence_archive / 'package-manifest.sha256'
archive.write_text(hashlib.sha256(manifest.read_bytes()).hexdigest() + '\n')
version = root / 'var/lib/zig-scheduler/package-version'
version.parent.mkdir(parents=True, exist_ok=True)
version.write_text('install=1\n')
install(preserve_config=True)
version.write_text('upgrade=2\n')
if 'local-admin-change' not in config.read_text():
    raise SystemExit('config was not preserved on upgrade')
for rel in files:
    if rel.startswith('etc/zig-scheduler/'):
        continue
    target = root / rel
    if target.exists():
        target.unlink()
for directory in ['usr/bin', 'usr/lib/systemd/system', 'usr/share/doc/zig-scheduler']:
    path = root / directory
    if path.exists() and any(path.iterdir()):
        raise SystemExit('uninstall left non-config files in ' + directory)
if not config.exists() or 'local-admin-change' not in config.read_text():
    raise SystemExit('uninstall removed preserved config')
if not archive.exists():
    raise SystemExit('uninstall removed evidence archive')
summary = {
    'schema': 'zig-scheduler/package-lifecycle-drill/v1',
    'status': 'PASS',
    'root': str(root),
    'installed_files': len(files),
    'upgrade_preserved_config': True,
    'uninstall_preserved_config': True,
    'evidence_archive_preserved': True,
    'host_mutation': False,
    'service_enabled': False,
}
summary_path = root / 'var/lib/zig-scheduler/package-lifecycle-summary.json'
summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
print('PASS package lifecycle drill: install upgrade uninstall staged only')
print('summary=' + str(summary_path))
PY
