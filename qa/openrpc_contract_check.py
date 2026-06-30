#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/openrpc_contract_check.py --self-test
# python3 qa/openrpc_contract_check.py --contract docs/control/daemon-openrpc.json --daemon src/daemon_main.zig --docs docs/control
from __future__ import annotations

import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from qa.openrpc_contract_model import OpenRpcContractError, load_contract, parse_args
from qa.openrpc_contract_selftest import run_self_test
from qa.openrpc_contract_validate import validate_contract


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        run_self_test()
        return 0
    validate_contract(load_contract(args.contract), args.docs, args.daemon)
    print(f"PASS OpenRPC daemon contract: contract={args.contract} daemon={args.daemon} docs={args.docs}")
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except (OSError, UnicodeError, OpenRpcContractError) as exc:
        print(f"FAIL openrpc contract: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
