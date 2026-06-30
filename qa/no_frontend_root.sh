#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$repo_root"
skip_build_help=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
usage: qa/no_frontend_root.sh [--root <path>] [--skip-build-help]

Checks the root scheduler package for forbidden frontend/UI surfaces while
intentionally excluding simulator/ historical artifacts.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || fail '--root requires value'
      root="$2"
      shift 2
      ;;
    --skip-build-help)
      skip_build_help=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[ -d "$root" ] || fail "root does not exist: $root"
root="$(cd "$root" && pwd)"

is_guarded_frontend_line() {
  local lower="$1"
  case "$lower" in
    *simulator/*|*"simulator-only"*|*"simulator only"*|*"historical"*|*"archived"*|*"former deterministic simulator"*) return 0 ;;
    *"must not"*|*"do not"*|*"forbidden"*|*"out of scope"*|*"non-goal"*|*"non goal"*|*"removed"*|*"no frontend"*|*"frontend-free"*|*"without explicit"*|*"not add"*|*"not restore"*|*"disallowed"*|*"blocked"*) return 0 ;;
    *) return 1 ;;
  esac
}


context_guarded_frontend_match() {
  local match="$1"
  local file line_no context_start context lower_context
  file="${match%%:*}"
  local rest="${match#*:}"
  line_no="${rest%%:*}"
  case "$line_no" in
    ''|*[!0-9]*) return 1 ;;
  esac
  context_start=$(( line_no > 6 ? line_no - 6 : 1 ))
  context="$(sed -n "${context_start},$((line_no + 3))p" "$file" 2>/dev/null || true)"
  lower_context="$(printf '%s' "$context" | tr '[:upper:]' '[:lower:]')"
  case "$lower_context" in
    *simulator/*|*"simulator-only"*|*"simulator only"*|*"former deterministic simulator"*|*"historical"*|*"archived"*) return 0 ;;
    *) return 1 ;;
  esac
}

is_out_of_scope_denylist_line() {
  local match="$1" rel text
  rel="$(relative "${match%%:*}")"
  text="${match#*:}"
  text="${text#*:}"
  case "$rel:$text" in
    packaging/build_package.sh:*out_of_scope_terms*frontend*tui*webview*browser-ui*) return 0 ;;
    *) return 1 ;;
  esac
}

is_strict_frontend_path() {
  local file="$1" rel
  rel="$(relative "$file")"
  case "$rel" in
    build.zig|build.zig.zon|src/*|packaging/*) return 0 ;;
    *) return 1 ;;
  esac
}

is_neutral_backend_contract_fixture_line() {
  local match="$1" text lower neutral
  text="${match#*:}"
  text="${text#*:}"
  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *fixtures/frontend-contract/*) ;;
    *) return 1 ;;
  esac
  neutral="${lower//fixtures\/frontend-contract\//fixture-path/}"
  neutral="${neutral//frontend-contract/fixture-pack/}"
  if printf '%s\n' "$neutral" | grep -Eq '(^|[^[:alnum:]_-])((front-?end([[:space:]_-]+(code|implementation|supports?|supported|exists|client|app|is[[:space:]]+available))?)|ui|tui|webview|browser|desktop|http|sse|client[[:space:]_-]+app)([^[:alnum:]_-]|$)'; then
    return 1
  fi
  return 0
}

is_backend_contract_exception() {
  local match="$1" file rel
  file="${match%%:*}"
  rel="$(relative "$file")"
  case "$rel:$match" in
	    docs/control/frontend-api-pack.md:*) return 0 ;;
	    packaging/build_package.sh:*)
	      is_out_of_scope_denylist_line "$match"
	      return $?
	      ;;
	    docs/control/stream-semantics.md:*)
	      is_neutral_backend_contract_fixture_line "$match"
	      return $?
      ;;
    build.zig:*qa/no_frontend_root.sh*) return 0 ;;
    build.zig:*qa/frontend_contract_pack_check.py*) return 0 ;;
    build.zig:*fixtures/frontend-contract*) return 0 ;;
    *) return 1 ;;
  esac
}

relative() {
  local path="$1"
  case "$path" in
    "$root") printf '.' ;;
    "$root"/*) printf '%s' "${path#"$root"/}" ;;
    *) printf '%s' "$path" ;;
  esac
}

forbidden_dirs=(
  "src/tui"
  "src/desktop"
  "src/webview"
  "src/browser-ui"
  "web"
  "desktop"
  "browser-ui"
  "frontend"
  "packaging/tui"
  "packaging/desktop"
  "packaging/webview"
  "packaging/browser-ui"
  "packaging/frontend"
)

for dir in "${forbidden_dirs[@]}"; do
  [ ! -e "$root/$dir" ] || fail "root frontend artifact exists: $dir"
done

scan_paths=()
for path in build.zig build.zig.zon src packaging docs README.md; do
  [ -e "$root/$path" ] && scan_paths+=("$root/$path")
done
[ "${#scan_paths[@]}" -gt 0 ] || fail 'no root paths available to scan'

printf 'root=%s\n' "$root"
printf 'checked_paths='
first=1
for path in "${scan_paths[@]}"; do
  if [ "$first" -eq 0 ]; then printf ','; fi
  printf '%s' "$(relative "$path")"
  first=0
done
printf '\n'

pattern='tui|tui-live-vm|webview|desktop|browser[- ]ui|browser ui|frontend|front-end'
while IFS= read -r match; do
  [ -n "$match" ] || continue
  lower="$(printf '%s' "$match" | tr '[:upper:]' '[:lower:]')"
  file="${match%%:*}"
  rel_file="$(relative "$file")"
  case "$rel_file" in
    docs/vendor/*) continue ;;
  esac
  if is_backend_contract_exception "$match"; then
    continue
  fi
  if is_strict_frontend_path "$file"; then
    fail "forbidden root frontend/UI token in build/source/package path: $match"
  fi
  if ! is_guarded_frontend_line "$lower" && ! context_guarded_frontend_match "$match"; then
    fail "unguarded root frontend/UI scope: $match"
  fi
done < <(grep -RHInEi --exclude-dir=.git --exclude-dir=.omx --exclude-dir=.omo --exclude-dir=.zig-cache --exclude-dir=zig-out -- "$pattern" "${scan_paths[@]}" 2>/dev/null || true)

strict_scan_paths=()
for path in build.zig build.zig.zon src packaging; do
  [ -e "$root/$path" ] && strict_scan_paths+=("$root/$path")
done

if [ "${#strict_scan_paths[@]}" -gt 0 ]; then
  while IFS= read -r match; do
    [ -n "$match" ] || continue
    if is_backend_contract_exception "$match"; then
      continue
    fi
    fail "obfuscated root frontend/UI token in build/source/package path: $match"
  done < <(python3 - "$root" "${strict_scan_paths[@]}" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
paths = [Path(item) for item in sys.argv[2:]]
hidden_terms = ("frontend", "front-end", "webview", "browser-ui", "browserui", "desktop")
literal_re = re.compile(r"tui|webview|desktop|browser[- ]ui|browser ui|frontend|front-end", re.IGNORECASE)
tui_concat_re = re.compile(r"['\"]t['\"]\s*\+\s*['\"]ui['\"]|['\"]tu['\"]\s*\+\s*['\"]i['\"]", re.IGNORECASE)


def relative(path: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return path.as_posix()


def normalized(line: str) -> str:
    return re.sub(r"['\"`+_\s:-]+", "", line.lower())


def scan_file(path: Path) -> None:
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return
    except OSError as exc:
        print(f"{relative(path)}:0:unreadable: {exc}")
        return
    for line_no, line in enumerate(text.splitlines(), 1):
        if literal_re.search(line):
            continue
        compact = normalized(line)
        if tui_concat_re.search(line) or any(term.replace("-", "") in compact for term in hidden_terms):
            print(f"{relative(path)}:{line_no}:{line}")


for candidate in paths:
    if candidate.is_dir():
        for child in sorted(candidate.rglob("*")):
            if child.is_file() and ".git" not in child.parts and ".zig-cache" not in child.parts and "zig-out" not in child.parts:
                scan_file(child)
    elif candidate.is_file():
        scan_file(candidate)
PY
  )
fi

for path in "${scan_paths[@]}"; do
  [ -d "$path" ] || continue
  while IFS= read -r artifact; do
    [ -n "$artifact" ] || continue
    rel="$(relative "$artifact")"
    case "$rel" in
      docs/control/frontend-api-pack.md) continue ;;
    esac
    fail "root frontend package/source artifact exists: $rel"
  done < <(find "$path" \
    \( -path "$root/.git" -o -path "$root/.omx" -o -path "$root/.omo" -o -path "$root/.zig-cache" -o -path "$root/zig-out" -o -path "$root/docs/vendor" \) -prune \
    -o \( -iname '*webview*' -o -iname '*browser-ui*' -o -iname '*desktop*' -o -iname '*tui*' -o -iname '*frontend*' \) -print)
done

if [ "$skip_build_help" -eq 0 ]; then
  if [ "$root" = "$repo_root" ]; then
    build_help="$(cd "$root" && zig build --help)"
    if printf '%s\n' "$build_help" | grep -Ei '(^|[[:space:]])(tui|webview|desktop|browser-ui)' >/dev/null; then
      printf '%s\n' "$build_help" >&2
      fail 'root build graph advertises frontend/UI target'
    fi
    printf 'build_help=checked\n'
  else
    printf 'build_help=skipped_non_repo_root\n'
  fi
else
  printf 'build_help=skipped_by_arg\n'
fi

printf 'PASS: root no-frontend check\n'
