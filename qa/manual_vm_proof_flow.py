#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/manual_vm_proof_ci_check.py --self-test
"""AST checks for the embedded runner-substrate proof writer."""
from __future__ import annotations

import ast
import re
import textwrap
from dataclasses import dataclass
from typing import Final

RUNNER_PROOF_PATH: Final = "evidence/lab/manual-vm-proof/runner-substrate-proof.json"
PROOF_ERROR: Final = "workflow embedded proof must capture complete qemu before proof emission without post-capture qemu/proof mutation"


class ManualVmProofFlowError(Exception):
    pass


@dataclass(frozen=True, slots=True)
class ProofWrite:
    script: ast.Module
    index: int
    call: ast.Call


@dataclass(frozen=True, slots=True)
class ProofCapture:
    index: int
    status: ast.expr | None


def is_name(node: ast.AST, name: str) -> bool:
    return isinstance(node, ast.Name) and node.id == name


def is_qemu_version_nonempty(node: ast.AST) -> bool:
    return isinstance(node, ast.Compare) and is_name(node.left, "qemu_version") and len(node.ops) == 1 and isinstance(node.ops[0], ast.NotEq) and len(node.comparators) == 1 and isinstance(node.comparators[0], ast.Constant) and node.comparators[0].value == ""


def is_qemu_usable_expr(node: ast.AST) -> bool:
    return isinstance(node, ast.BoolOp) and isinstance(node.op, ast.And) and len(node.values) == 2 and is_name(node.values[0], "qemu_available") and is_qemu_version_nonempty(node.values[1])


def dict_value(node: ast.Dict, key_name: str) -> ast.expr | None:
    for key, value in zip(node.keys, node.values, strict=True):
        if isinstance(key, ast.Constant) and key.value == key_name:
            return value
    return None


def constant_string(node: ast.expr) -> str | None:
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left = constant_string(node.left)
        right = constant_string(node.right)
        if left is not None and right is not None:
            return left + right
    return None


def is_keyword(node: ast.keyword, name: str, value: int | bool) -> bool:
    return node.arg == name and isinstance(node.value, ast.Constant) and node.value.value == value


def is_proof_json_dump(node: ast.AST) -> bool:
    return (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and isinstance(node.func.value, ast.Name)
        and node.func.value.id == "json"
        and node.func.attr == "dumps"
        and len(node.args) == 1
        and is_name(node.args[0], "proof")
        and len(node.keywords) == 2
        and is_keyword(node.keywords[0], "indent", 2)
        and is_keyword(node.keywords[1], "sort_keys", True)
    )


def is_canonical_write_arg(node: ast.AST) -> bool:
    return (
        isinstance(node, ast.BinOp)
        and isinstance(node.op, ast.Add)
        and is_proof_json_dump(node.left)
        and isinstance(node.right, ast.Constant)
        and node.right.value == "\n"
    )


def path_literal(node: ast.AST) -> str | None:
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "Path" and len(node.args) == 1:
        return path_literal(node.args[0])
    return None


def write_path(node: ast.Call, paths: dict[str, str]) -> str | None:
    if not isinstance(node.func, ast.Attribute) or node.func.attr != "write_text":
        return None
    receiver = node.func.value
    if isinstance(receiver, ast.Name):
        return paths.get(receiver.id)
    return path_literal(receiver)


def qemu_status_from(value: ast.expr, qemu_dicts: dict[str, ast.Dict]) -> ast.expr | None:
    if isinstance(value, ast.Dict):
        status = dict_value(value, "status")
        if status is not None:
            return status
        qemu = dict_value(value, "qemu")
        if isinstance(qemu, ast.Dict):
            return dict_value(qemu, "status")
        if isinstance(qemu, ast.Name) and qemu.id in qemu_dicts:
            return dict_value(qemu_dicts[qemu.id], "status")
    if isinstance(value, ast.Name) and value.id in qemu_dicts:
        return dict_value(qemu_dicts[value.id], "status")
    return None



def embedded_python(text: str) -> tuple[ast.Module, ...]:
    scripts: list[ast.Module] = []
    matches = re.finditer(r"python3 - <<'PY'\n(?P<script>.*?)\n\s*PY", text, re.DOTALL)
    for match in matches:
        script = textwrap.dedent(match.group("script"))
        try:
            scripts.append(ast.parse(script))
        except SyntaxError as exc:
            raise ManualVmProofFlowError(f"workflow embedded Python is not parseable: {exc.msg}") from exc
    return tuple(scripts)


def canonical_writes(text: str) -> tuple[ProofWrite, ...]:
    writes: list[ProofWrite] = []
    for script in embedded_python(text):
        paths: dict[str, str] = {}
        for index, statement in enumerate(script.body):
            if isinstance(statement, ast.Assign):
                for target in statement.targets:
                    if isinstance(target, ast.Name):
                        path = path_literal(statement.value)
                        if path is not None:
                            paths[target.id] = path
            if not isinstance(statement, ast.Expr) or not isinstance(statement.value, ast.Call):
                continue
            call = statement.value
            if len(call.args) == 1 and not call.keywords and is_canonical_write_arg(call.args[0]) and write_path(call, paths) == RUNNER_PROOF_PATH:
                writes.append(ProofWrite(script, index, call))
    return tuple(writes)


def has_forbidden_capture_node(node: ast.expr) -> bool:
    forbidden = (
        ast.Call,
        ast.NamedExpr,
        ast.Starred,
        ast.DictComp,
        ast.ListComp,
        ast.SetComp,
        ast.GeneratorExp,
        ast.Lambda,
        ast.Await,
        ast.Yield,
        ast.YieldFrom,
    )
    return any(isinstance(child, forbidden) for child in ast.walk(node))


def has_literal_dict_keys(node: ast.expr) -> bool:
    for child in ast.walk(node):
        if not isinstance(child, ast.Dict):
            continue
        for key in child.keys:
            if not isinstance(key, ast.Constant) or not isinstance(key.value, str):
                return False
    return True


def is_side_effect_free_capture_value(node: ast.expr) -> bool:
    return not has_forbidden_capture_node(node) and has_literal_dict_keys(node)


def proof_capture_status(value: ast.expr, qemu_dicts: dict[str, ast.Dict]) -> ast.expr | None:
    if not isinstance(value, ast.Dict):
        return None
    status: ast.expr | None = None
    for key, item in zip(value.keys, value.values, strict=True):
        if not isinstance(key, ast.Constant) or not isinstance(key.value, str):
            return None
        if key.value == "qemu":
            if not is_name(item, "qemu") or "qemu" not in qemu_dicts:
                return None
            status = qemu_status_from(item, qemu_dicts)
        elif not is_side_effect_free_capture_value(item):
            return None
    return status


def proof_capture(script: ast.Module) -> tuple[ProofCapture, bool]:
    qemu_dicts: dict[str, ast.Dict] = {}
    has_usable_assignment = False
    capture: ProofCapture | None = None
    for index, statement in enumerate(script.body):
        if not isinstance(statement, ast.Assign):
            continue
        if is_name_list_target(statement, "qemu_usable") and is_qemu_usable_expr(statement.value):
            has_usable_assignment = True
        for target in statement.targets:
            if isinstance(target, ast.Name) and isinstance(statement.value, ast.Dict):
                qemu_dicts[target.id] = statement.value
            if isinstance(target, ast.Name) and target.id == "proof":
                status = proof_capture_status(statement.value, qemu_dicts)
                if status is not None:
                    capture = ProofCapture(index, status)
    if capture is None:
        raise ManualVmProofFlowError(PROOF_ERROR)
    return capture, has_usable_assignment


def is_name_list_target(node: ast.Assign, name: str) -> bool:
    return any(is_name(target, name) for target in node.targets)


def validate_qemu_proof_semantics(text: str) -> None:
    writes = canonical_writes(text)
    if len(writes) != 1:
        raise ManualVmProofFlowError("workflow must contain exactly one canonical runner-substrate-proof.json proof writer")
    proof_write = writes[0]
    capture, has_usable_assignment = proof_capture(proof_write.script)
    if not (has_usable_assignment and isinstance(capture.status, ast.IfExp) and is_name(capture.status.test, "qemu_usable")):
        raise ManualVmProofFlowError(PROOF_ERROR)
    if proof_write.index != capture.index + 1 or proof_write.index != len(proof_write.script.body) - 1:
        raise ManualVmProofFlowError(PROOF_ERROR)
