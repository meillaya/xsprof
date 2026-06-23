#!/usr/bin/env bash
# Shell adapter for microVM serial parsing/evidence emission.

microvm_emit_timeout_report() {
  local out_dir="$1" git_sha="$2" git_dirty="$3" started_at="$4" kernel_image="$5" qemu_bin="$6" qemu_scan_before="$7" qemu_scan_after="$8" qemu_rc="$9"
  OUT_DIR="$out_dir" GIT_SHA="$git_sha" GIT_DIRTY="$git_dirty" STARTED_AT="$started_at" KERNEL_IMAGE="$kernel_image" QEMU_BIN="$qemu_bin" QEMU_SCAN_BEFORE="$qemu_scan_before" QEMU_SCAN_AFTER="$qemu_scan_after" QEMU_RC="$qemu_rc" python3 qa/vm/microvm_report_emit.py timeout
}

microvm_parse_and_emit_report() {
  local serial="$1" out_dir="$2" object_sha="$3" object_file="$4" meta_file="$5" git_sha="$6"
  local git_dirty="$7" started_at="$8" kernel_image="$9" qemu_bin="${10}" qemu_scan_before="${11}" qemu_scan_after="${12}" qemu_rc="${13}"
  SERIAL="$serial" OUT_DIR="$out_dir" OBJECT_SHA="$object_sha" OBJECT_FILE="$object_file" META_FILE="$meta_file" GIT_SHA="$git_sha" GIT_DIRTY="$git_dirty" STARTED_AT="$started_at" KERNEL_IMAGE="$kernel_image" QEMU_BIN="$qemu_bin" QEMU_SCAN_BEFORE="$qemu_scan_before" QEMU_SCAN_AFTER="$qemu_scan_after" QEMU_RC="$qemu_rc" python3 qa/vm/microvm_report_emit.py parse
  python3 qa/partial_attach_check.py --evidence "$out_dir/partial-attach/partial-attach-evidence.json"
  python3 qa/lab_summary_observe.py --summary "$out_dir/observe-partial/summary.json"
  python3 qa/runtime_sample_check.py --input "$out_dir/observe-partial/runtime-samples.jsonl"
}
