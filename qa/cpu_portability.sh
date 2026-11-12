#!/bin/sh
# CPU-portability gate for packaged binaries: reject a release artifact whose
# machine code needs instruction-set extensions above the architecture baseline.
#
# Why this exists: the published v0.6.0 AppImage was a native-CPU Zig build on
# a CI runner with AVX-512. It trapped with SIGILL (exit 132) on an AMD Zen3
# host (`vmovups %zmm0` in start.main). qa/appimage_smoke.sh only executed the
# artifact on its build host, so it passed. Executing a binary cannot prove it
# is portable; the release lane has to inspect the machine code instead.
#
# Checks:
#   * ELF machine from `readelf -h`, else `objdump -f`, else `file`.
#   * x86_64: disassemble with `objdump -d --no-show-raw-insn` and reject every
#     VEX/EVEX-encoded instruction (mnemonic starting with `v`, except the
#     legacy `verr`/`verw`): those need AVX or newer, while the shipped
#     baseline is x86-64 (SSE2), so a portable binary must contain none.
#   * aarch64: reject SVE/SVE2 code (zNN vector or pNN predicate registers, and
#     SVE-only mnemonics): the shipped baseline is ARMv8-A without SVE.
#   * Any other ELF machine: SKIP with the reason (not a release architecture).
#
# Tool policy mirrors qa/xvfb_smoke.sh: machine-code inspection needs binutils.
# Without --require-tools / XSPROF_REQUIRE_TOOLS=1 a missing tool downgrades
# the gate to SKIP (exit 0) so a developer host can still run the other gates.
# The release lane sets XSPROF_REQUIRE_TOOLS=1, so a missing inspection tool is
# a hard failure and this gate can never silently skip in a release.
#
# Usage: sh qa/cpu_portability.sh --binary FILE [--require-tools]
# Exit:  0 PASS or SKIP, 1 FAIL, 2 usage error.
# Writes only inside a private temporary directory.
set -eu

REQUIRE_TOOLS=0
case "${XSPROF_REQUIRE_TOOLS:-0}" in
    1 | true | TRUE | yes | YES) REQUIRE_TOOLS=1 ;;
esac
BIN=

usage() {
    cat <<'EOF'
Usage: sh qa/cpu_portability.sh --binary FILE [--require-tools]

Reject a packaged binary that needs CPU extensions above the release baseline:
x86_64 must contain no VEX/EVEX (AVX or newer) instructions, and aarch64 must
contain no SVE/SVE2 code. Other ELF machines are skipped with the reason.

Options:
  --binary FILE     ELF binary to inspect (required)
  --require-tools   fail closed when readelf/objdump are unavailable
                    (XSPROF_REQUIRE_TOOLS=1 has the same effect)
  -h, --help        show this help

Exit: 0 PASS or SKIP, 1 FAIL, 2 usage error.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --binary)
            [ "$#" -ge 2 ] || {
                echo "cpu_portability: --binary requires FILE" >&2
                usage >&2
                exit 2
            }
            BIN=$2
            shift 2
            ;;
        --require-tools) REQUIRE_TOOLS=1; shift ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "cpu_portability: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done
[ -n "$BIN" ] || {
    echo "cpu_portability: --binary is required" >&2
    usage >&2
    exit 2
}
[ -f "$BIN" ] || {
    echo "cpu_portability: missing binary: $BIN" >&2
    exit 2
}
case "$BIN" in
    /*) ;;
    *) BIN=$(CDPATH= cd -- "$(dirname -- "$BIN")" && pwd)/$(basename -- "$BIN") ;;
esac

READELF=$(command -v readelf 2>/dev/null || true)
OBJDUMP=$(command -v objdump 2>/dev/null || true)
FILE_BIN=$(command -v file 2>/dev/null || true)

unavailable() { # reason
    if [ "$REQUIRE_TOOLS" = 1 ]; then
        echo "cpu_portability: FAIL ($1)" >&2
        exit 1
    fi
    echo "cpu_portability: SKIP ($1)"
    exit 0
}

normalize_machine() { # raw machine description
    case "$1" in
        *X86-64* | *x86-64* | *x86_64*) printf 'x86_64' ;;
        *AArch64* | *aarch64*) printf 'aarch64' ;;
        *) printf 'other' ;;
    esac
}

MACHINE=
MACHINE_DESC=
detect_machine() {
    if [ -n "$READELF" ]; then
        raw=$("$READELF" -h "$BIN" 2>/dev/null |
            sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' | head -n 1)
        if [ -n "$raw" ]; then
            MACHINE=$(normalize_machine "$raw")
            MACHINE_DESC="readelf -h: $raw"
            return 0
        fi
    fi
    if [ -n "$OBJDUMP" ]; then
        raw=$("$OBJDUMP" -f "$BIN" 2>/dev/null |
            sed -n 's/^architecture:[[:space:]]*//p' | head -n 1)
        if [ -n "$raw" ]; then
            MACHINE=$(normalize_machine "$raw")
            MACHINE_DESC="objdump -f: $raw"
            return 0
        fi
    fi
    if [ -n "$FILE_BIN" ]; then
        raw=$("$FILE_BIN" -b "$BIN" 2>/dev/null || true)
        case "$raw" in
            *ELF*)
                MACHINE=$(normalize_machine "$raw")
                MACHINE_DESC="file: $raw"
                return 0
                ;;
        esac
    fi
    return 1
}

if ! detect_machine; then
    if [ -z "$READELF" ] && [ -z "$OBJDUMP" ] && [ -z "$FILE_BIN" ]; then
        unavailable "required tools unavailable: readelf, objdump, and file (cannot determine the ELF machine)"
    fi
    echo "cpu_portability: FAIL (cannot determine the ELF machine of $BIN)" >&2
    exit 1
fi

# Shared disassembly helper: only runs once the machine is a gated arch.
require_objdump() {
    [ -n "$OBJDUMP" ] || unavailable "required tool unavailable: objdump (needed to inspect $MACHINE machine code)"
}

disassemble() { # OUTPUT_FILE ERROR_FILE
    require_objdump
    if ! "$OBJDUMP" -d --no-show-raw-insn "$BIN" >"$1" 2>"$2"; then
        detail=$(head -n 1 "$2" 2>/dev/null || true)
        echo "cpu_portability: FAIL (objdump -d failed for $BIN: ${detail:-unknown error})" >&2
        exit 1
    fi
}

read_summary() { # SUMMARY_FILE -> TOTAL BAD
    TOTAL=0
    BAD=0
    if [ -s "$1" ]; then
        read -r TOTAL BAD <"$1"
    fi
    [ "$TOTAL" -gt 0 ] || {
        echo "cpu_portability: FAIL (no instructions disassembled from $BIN; cannot prove baseline portability)" >&2
        exit 1
    }
}

print_offending() { # SORTED_FILE LABEL
    label=$1
    sorted=$2
    echo "cpu_portability: $label instructions in $BIN:" >&2
    head -n 10 "$sorted" | while read -r count mnemonic; do
        printf '  %8s %s\n' "$count" "$mnemonic" >&2
    done
}

top_offending() { # SORTED_FILE
    head -n 5 "$1" | awk '{ printf "%s%s=%s", (NR > 1 ? " " : ""), $2, $1 }'
}

check_x86_64() {
    require_objdump
    TMP=$(mktemp -d) || {
        echo "cpu_portability: FAIL (cannot create a temporary directory)" >&2
        exit 1
    }
    trap 'rm -rf "$TMP"' EXIT HUP INT TERM
    disassemble "$TMP/disasm" "$TMP/objdump.err"
    # VEX/EVEX instructions are the only x86 mnemonics starting with `v`, apart
    # from the legacy verr/verw. Prefix tokens (`lock`, `rep`, segment/operand
    # size overrides, `bnd`, `notrack`) are skipped before the mnemonic column.
    awk -v bad_out="$TMP/bad" -v sum_out="$TMP/summary" '
        BEGIN {
            n = split("lock rep repe repz repne repnz cs ds es fs gs ss data16 data32 addr16 addr32 bnd notrack", prefixes, " ")
            for (i = 1; i <= n; i++) prefix[prefixes[i]] = 1
        }
        /^[[:space:]]*[0-9a-fA-F]+:/ {
            i = 2
            while (i <= NF && ($i in prefix)) i++
            if (i > NF) next
            mnemonic = $i
            total++
            if (mnemonic ~ /^v/ && mnemonic != "verr" && mnemonic != "verw") {
                bad[mnemonic]++
                bad_total++
            }
        }
        END {
            for (m in bad) printf "%d %s\n", bad[m], m > bad_out
            printf "%d %d\n", total, bad_total > sum_out
        }
    ' "$TMP/disasm"
    read_summary "$TMP/summary"
    if [ "$BAD" -gt 0 ]; then
        sort -rn "$TMP/bad" >"$TMP/bad-sorted"
        print_offending "x86_64 VEX/EVEX-encoded" "$TMP/bad-sorted"
        top=$(top_offending "$TMP/bad-sorted")
        echo "cpu_portability: FAIL (x86_64: $BAD of $TOTAL instructions are VEX/EVEX-encoded (top: $top); they need AVX/AVX-512, so build with -Dcpu=baseline)" >&2
        exit 1
    fi
    echo "cpu_portability: PASS (x86_64; $TOTAL instructions scanned; 0 VEX/EVEX mnemonics; $MACHINE_DESC)"
}

check_aarch64() {
    require_objdump
    TMP=$(mktemp -d) || {
        echo "cpu_portability: FAIL (cannot create a temporary directory)" >&2
        exit 1
    }
    trap 'rm -rf "$TMP"' EXIT HUP INT TERM
    disassemble "$TMP/disasm" "$TMP/objdump.err"
    # SVE/SVE2 is identified two ways: an SVE-only mnemonic, or a zNN/pNN
    # register (the shared mnemonics such as fadd/fmla/ldr are only SVE when
    # they name SVE registers). Base ARMv8-A register names (v/q/d/s/h/b/w/x)
    # never match. NEON-only mnemonics are deliberately absent from the list.
    awk -v bad_out="$TMP/bad" -v sum_out="$TMP/summary" '
        BEGIN {
            n = split("ptrue pfalse ptest ptests pfirst pnext psel setffr rdfr wrffr whilelo whilelt whilerw whilewr rdvl addvl addpl incb incw inch incd decb decw dech decd cntb cntw cnth cntd movprfx compact splice lasta lastb clasta clastb ctermeq ctermne sunpkhi sunpklo uunpkhi uunpklo insr prfb prfh prfw prfd", sve_mnemonics, " ")
            for (i = 1; i <= n; i++) sve[sve_mnemonics[i]] = 1
        }
        /^[[:space:]]*[0-9a-fA-F]+:/ {
            mnemonic = $2
            total++
            operands = ""
            for (j = 3; j <= NF; j++) operands = operands " " $j
            hit = 0
            if (mnemonic in sve) hit = 1
            else if (operands ~ /(^|[^A-Za-z0-9_.])[zp][0-9]+([^A-Za-z0-9_]|$)/) hit = 1
            if (hit) {
                bad[mnemonic]++
                bad_total++
            }
        }
        END {
            for (m in bad) printf "%d %s\n", bad[m], m > bad_out
            printf "%d %d\n", total, bad_total > sum_out
        }
    ' "$TMP/disasm"
    read_summary "$TMP/summary"
    if [ "$BAD" -gt 0 ]; then
        sort -rn "$TMP/bad" >"$TMP/bad-sorted"
        print_offending "aarch64 SVE/SVE2" "$TMP/bad-sorted"
        top=$(top_offending "$TMP/bad-sorted")
        echo "cpu_portability: FAIL (aarch64: $BAD of $TOTAL instructions use SVE/SVE2 registers or mnemonics (top: $top); they need ARMv8-A+SVE, so build with -Dcpu=baseline)" >&2
        exit 1
    fi
    echo "cpu_portability: PASS (aarch64; $TOTAL instructions scanned; 0 SVE/SVE2 registers or mnemonics; $MACHINE_DESC)"
}

case "$MACHINE" in
    x86_64) check_x86_64 ;;
    aarch64) check_aarch64 ;;
    *)
        echo "cpu_portability: SKIP ($MACHINE_DESC; only x86_64 and aarch64 release binaries are gated for baseline CPU portability)"
        exit 0
        ;;
esac
