#!/bin/sh
# Offline syntax gate for every tracked shell script.
#
# Nothing is executed and nothing is written outside a temporary file: each
# candidate is only parsed with `bash -n` or `sh -n`. Enumerated inputs are:
#   * every tracked `*.sh` file (from `git ls-files`), and
#   * tracked extensionless files whose first line is a shell shebang, such as
#     `tools/zig`.
# A `find` walk is used only when git is missing or the checkout is not a work
# tree. Vendored, archived, generated, and design-only trees are skipped:
# docs/vendor/, design/, .git/, .cache/, .zig-cache/, zig-out/, .tools/.
#
# The interpreter is chosen from the shebang, never from the extension alone:
#   bash / env bash / env -S bash   -> bash -n
#   sh | dash / env sh | env dash   -> sh -n
#   any other shebang               -> SKIP line (not a shell script)
#   missing shebang on a *.sh file  -> sh -n (POSIX default)
# Syntax errors are fail-closed (exit 1). A missing interpreter downgrades the
# gate to SKIP with the reason: this gate never reports a PASS it did not earn.
#
# Usage: sh qa/script_syntax.sh [--self-test]
# Exit:  0 PASS or SKIP, 1 syntax failure / self-test failure / usage error.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ENUM_MODE="auto" # auto | git | find; --self-test pins find
CHECKED=0
SKIPPED_UNKNOWN=0
SKIPPED_MISSING=0
FAILED=0
MISSING_BASH=0
MISSING_SH=0
SH_BIN=$(command -v sh 2>/dev/null || true)
BASH_BIN=$(command -v bash 2>/dev/null || true)
GIT_BIN=$(command -v git 2>/dev/null || true)

err() { printf '%s\n' "$*" >&2; }
say() { printf '%s\n' "$*"; }

usage() {
    cat <<'EOF'
Usage: sh qa/script_syntax.sh [--self-test]

Syntax-check every tracked shell script without executing it.

Options:
  --self-test   build a throwaway tree with valid and deliberately broken
                scripts and assert the checker accepts the first and rejects
                the second (proves the gate is not a silent no-op)
  -h, --help    show this help

Exit: 0 PASS or SKIP, 1 syntax failure / self-test failure / usage error.
EOF
}

first_line() { head -n 1 "$1" 2>/dev/null || true; }

# shell_from_shebang LINE prints bash, sh, or nothing for an unrecognised
# interpreter. Always call it in a command substitution: it uses `set -f` and
# the positional parameters of that subshell to split the shebang line.
shell_from_shebang() {
    line=$1
    case "$line" in
        '#!'*) ;;
        *) printf 'sh'; return 0 ;;
    esac
    body=${line#\#!}
    set -f
    # Deliberate word splitting on the shebang; globbing is disabled above.
    # shellcheck disable=SC2086
    set -- $body
    [ "$#" -gt 0 ] || { printf ''; return 0; }
    interp=$1
    base=${interp##*/}
    if [ "$base" = env ]; then
        shift
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -*) shift ;;
                *=*) shift ;;
                *) interp=$1; break ;;
            esac
        done
        base=${interp##*/}
    fi
    case "$base" in
        bash) printf 'bash' ;;
        sh | dash) printf 'sh' ;;
        *) printf '' ;;
    esac
}

reset_counts() {
    CHECKED=0
    SKIPPED_UNKNOWN=0
    SKIPPED_MISSING=0
    FAILED=0
    MISSING_BASH=0
    MISSING_SH=0
}

# check_script REL checks one candidate under $ROOT and updates the counters.
check_script() {
    rel=$1
    path=$ROOT/$rel
    line=$(first_line "$path")
    case "$(shell_from_shebang "$line")" in
        bash)
            if [ -z "$BASH_BIN" ]; then
                say "script_syntax: SKIP $rel (bash not available)"
                SKIPPED_MISSING=$((SKIPPED_MISSING + 1))
                MISSING_BASH=1
                return 0
            fi
            if ! "$BASH_BIN" -n "$path"; then
                err "script_syntax: FAIL $rel (bash -n rejected it)"
                FAILED=$((FAILED + 1))
                return 0
            fi
            CHECKED=$((CHECKED + 1))
            ;;
        sh)
            if [ -z "$SH_BIN" ]; then
                say "script_syntax: SKIP $rel (sh not available)"
                SKIPPED_MISSING=$((SKIPPED_MISSING + 1))
                MISSING_SH=1
                return 0
            fi
            if ! "$SH_BIN" -n "$path"; then
                err "script_syntax: FAIL $rel (sh -n rejected it)"
                FAILED=$((FAILED + 1))
                return 0
            fi
            CHECKED=$((CHECKED + 1))
            ;;
        *)
            say "script_syntax: SKIP $rel (not a shell shebang: ${line:-<none>})"
            SKIPPED_UNKNOWN=$((SKIPPED_UNKNOWN + 1))
            ;;
    esac
    return 0
}

enumerate_into() { # DEST
    dest=$1
    case "$ENUM_MODE" in
        git)
            "$GIT_BIN" -C "$ROOT" ls-files >"$dest"
            ;;
        find)
            (
                cd "$ROOT"
                find . \
                    \( -name .git -o -name .cache -o -name .zig-cache \
                    -o -name zig-out -o -name .tools -o -name .devenv \
                    -o -name .direnv \) -prune -o -type f -print
            ) | sed 's|^\./||' >"$dest"
            ;;
        *)
            err "script_syntax: unknown enumeration mode: $ENUM_MODE"
            return 1
            ;;
    esac
}

resolve_enum_mode() {
    case "$ENUM_MODE" in
        git | find) return 0 ;;
        auto)
            if [ -n "$GIT_BIN" ] &&
                "$GIT_BIN" -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
                ENUM_MODE="git"
            else
                ENUM_MODE="find"
            fi
            return 0
            ;;
    esac
    err "script_syntax: invalid enumeration mode: $ENUM_MODE"
    return 1
}

scan() {
    list=$(mktemp "${TMPDIR:-/tmp}/xsprof-script-syntax.XXXXXX") || {
        err "script_syntax: cannot create a temporary file"
        return 1
    }
    if ! enumerate_into "$list"; then
        rm -f "$list"
        return 1
    fi
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        case "$rel" in
            docs/vendor/* | design/* | .git/* | .cache/* | .zig-cache/* | \
                zig-out/* | .tools/* | .devenv/* | .direnv/*)
                continue
                ;;
        esac
        path=$ROOT/$rel
        [ -f "$path" ] || continue
        case "$rel" in
            *.sh)
                check_script "$rel"
                ;;
            *)
                base=${rel##*/}
                case "$base" in
                    *.*) continue ;;
                esac
                line=$(first_line "$path")
                case "$line" in
                    '#!'*) ;;
                    *) continue ;;
                esac
                case "$(shell_from_shebang "$line")" in
                    bash | sh) check_script "$rel" ;;
                esac
                ;;
        esac
    done <"$list"
    rm -f "$list"
    return 0
}

report() {
    if [ "$FAILED" -gt 0 ]; then
        err "script_syntax: FAIL ($FAILED of $((CHECKED + FAILED)) checked scripts)"
        return 1
    fi
    if [ "$SKIPPED_MISSING" -gt 0 ]; then
        reasons=
        if [ "$MISSING_BASH" -eq 1 ]; then reasons="bash"; fi
        if [ "$MISSING_SH" -eq 1 ]; then
            if [ -n "$reasons" ]; then reasons="$reasons, sh"; else reasons="sh"; fi
        fi
        say "script_syntax: SKIP (missing interpreter: $reasons)"
        return 0
    fi
    if [ "$CHECKED" -eq 0 ]; then
        say "script_syntax: SKIP (no checkable shell scripts)"
        return 0
    fi
    if [ "$SKIPPED_UNKNOWN" -gt 0 ]; then
        say "script_syntax: PASS ($CHECKED scripts; $SKIPPED_UNKNOWN skipped: not shell)"
    else
        say "script_syntax: PASS ($CHECKED scripts)"
    fi
    return 0
}

# self_test feeds the same checker a broken snippet and asserts it is rejected,
# then a valid tree and asserts it is accepted, without touching the checkout.
self_test() {
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/xsprof-script-syntax-self.XXXXXX") || {
        err "script_syntax: self-test: cannot create a temporary directory"
        return 1
    }
    saved_root=$ROOT
    saved_mode=$ENUM_MODE
    ROOT=$tmp
    ENUM_MODE="find"
    status=0

    mkdir -p "$tmp/tools"
    printf '#!/bin/sh\necho valid\n' >"$tmp/good.sh"
    printf '#!/bin/sh\necho extensionless\n' >"$tmp/tools/zig"
    printf '#!/usr/bin/env python3\nprint("not shell")\n' >"$tmp/renamed.sh"
    printf 'plain text, not a shell script\n' >"$tmp/notes.txt"

    reset_counts
    if ! scan >/dev/null 2>&1; then
        err "script_syntax: self-test FAIL (scan of the valid tree errored)"
        status=1
    elif ! report >/dev/null 2>&1; then
        err "script_syntax: self-test FAIL (valid tree was rejected)"
        status=1
    elif [ "$CHECKED" -ne 2 ]; then
        err "script_syntax: self-test FAIL (expected 2 checked scripts, got $CHECKED)"
        status=1
    elif [ "$SKIPPED_UNKNOWN" -ne 1 ]; then
        err "script_syntax: self-test FAIL (non-shell shebang was not skipped)"
        status=1
    fi

    # Missing `fi`: must be rejected by the sh interpreter, never skipped.
    printf '#!/bin/sh\nif [ 1 -eq 1 ]; then\n    echo broken\n' >"$tmp/broken.sh"
    reset_counts
    if ! scan >/dev/null 2>&1; then
        err "script_syntax: self-test FAIL (scan of the broken tree errored)"
        status=1
    elif report >/dev/null 2>&1; then
        err "script_syntax: self-test FAIL (broken snippet was accepted)"
        status=1
    elif [ "$FAILED" -ne 1 ]; then
        err "script_syntax: self-test FAIL (expected 1 failed script, got $FAILED)"
        status=1
    fi

    ROOT=$saved_root
    ENUM_MODE=$saved_mode
    rm -rf "$tmp"
    if [ "$status" -ne 0 ]; then
        return 1
    fi
    say "script_syntax: self-test PASS (valid script accepted, broken script rejected)"
    return 0
}

main() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --self-test)
                shift
                self_test
                return $?
                ;;
            -h | --help)
                usage
                return 0
                ;;
            *)
                err "script_syntax: unknown argument: $1"
                usage >&2
                return 2
                ;;
        esac
    done
    resolve_enum_mode || return 1
    reset_counts
    scan || return 1
    report
}

main "$@"
