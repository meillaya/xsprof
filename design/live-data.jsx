// live-data.jsx — live microVM lab run engine.
// Models src/tui/daemon_model.zig + fixtures/lab/run-all-vm-live-summary.json:
// a disposable microVM boots, the daemon attaches a `zigsched_minimal` sched_ext scheduler,
// and streams runtime samples under a fail-closed contract (host_mutation = false, always).
// Nothing here claims fidelity or performance — telemetry is observed/descriptive only.

const EVENT_SCHEMA = 'zig-scheduler/daemon-event/v1';
const LIVE_ACTION = 'run_lab_microvm_live';

// ── VM attach targets (the picker) ──────────────────────────────────────────
const TARGETS = [
  { id: 'sched-ext-lab', release: '6.12.0-sched-ext-lab', arch: 'x86_64', btf: true,  qemu: true,  kvm: true,  nix: true,  note: 'disposable microVM · BTF present · approved tuple' },
  { id: 'mainline-6.11', release: '6.11.0-rc6-zigsched', arch: 'x86_64', btf: true,  qemu: true,  kvm: true,  nix: true,  note: 'mainline rc · sched_ext capable' },
  { id: 'aarch64-lab',   release: '6.12.0-sched-ext-lab', arch: 'aarch64', btf: true, qemu: true,  kvm: false, nix: true,  note: 'no kvm on host → fail-closed SKIP' },
];

// Refusal scenarios — every refusal keeps host_mutation=false (README fail-closed outcomes).
const REFUSALS = {
  none:            null,
  qemu_not_found:  { kind: 'SKIP',   reason: 'qemu_unavailable',        msg: 'SKIP: qemu unavailable' },
  kvm_unavailable: { kind: 'SKIP',   reason: 'kvm_unavailable',         msg: 'SKIP: kvm unavailable' },
  nix_busybox:     { kind: 'REFUSE', reason: 'nix_busybox_unavailable', msg: 'REFUSE: nix_busybox_unavailable' },
  config_invalid:  { kind: 'REFUSE', reason: 'VM_CONFIG_INVALID',       msg: 'REFUSE: VM_CONFIG_INVALID' },
  verifier_reject: { kind: 'REFUSE', reason: 'verifier_reject',         msg: 'REFUSE: verifier reject' },
  lost_stream:     { kind: 'INCIDENT', reason: 'lost_stream',           msg: 'INCIDENT: lost stream' },
  timeout:         { kind: 'INCIDENT', reason: 'stream_timeout',        msg: 'INCIDENT: timeout' },
  rollback_failed: { kind: 'INCIDENT', reason: 'rollback_failure',      msg: 'INCIDENT: rollback failure' },
  cleanup_residue: { kind: 'INCIDENT', reason: 'cleanup_residue',       msg: 'INCIDENT: cleanup residue' },
  stale_id:        { kind: 'REFUSE', reason: 'stale_or_unknown_target_action_id', msg: 'REFUSE: stale/unknown id' },
  duplicate_id:    { kind: 'REFUSE', reason: 'duplicate_action_id',     msg: 'REFUSE: duplicate id' },
};

const INCIDENT_COPY = {
  qemu_unavailable: { mode: 'SKIP', title: 'QEMU unavailable', stage: 'preflight', operator: 'Install qemu-system for a capable lab host; host remains unchanged.' },
  qemu_not_found: { mode: 'SKIP', title: 'QEMU unavailable', stage: 'preflight', operator: 'Install qemu-system for a capable lab host; host remains unchanged.' },
  verifier_reject: { mode: 'REFUSE', title: 'Verifier reject', stage: 'verifier', operator: 'Treat verifier output as authoritative; do not attach.' },
  lost_stream: { mode: 'INCIDENT', title: 'Lost daemon stream', stage: 'stream', operator: 'Unsafe to assume progress; preserve journal and require cleanup scan.' },
  lost_stream_non_json: { mode: 'INCIDENT', title: 'Malformed/lost stream', stage: 'stream', operator: 'Non-JSON daemon output was quarantined and redacted from success state.' },
  lost_stream_empty: { mode: 'INCIDENT', title: 'Empty daemon stream', stage: 'stream', operator: 'No daemon evidence arrived; run is unsafe to assume successful.' },
  stream_timeout: { mode: 'INCIDENT', title: 'Stream timeout', stage: 'timeout', operator: 'The child was terminated and the run requires cleanup proof.' },
  rollback_failure: { mode: 'INCIDENT', title: 'Rollback failure', stage: 'rollback', operator: 'Rollback did not prove restored state; keep release gate closed.' },
  cleanup_residue: { mode: 'INCIDENT', title: 'Cleanup residue', stage: 'cleanup', operator: 'Process or scratch residue remains; run cleanup scan before retry.' },
  duplicate_action_id: { mode: 'REFUSE', title: 'Duplicate action id', stage: 'bridge', operator: 'Controller refused replayed action id before daemon progress.' },
  stale_or_unknown_target_action_id: { mode: 'REFUSE', title: 'Stale target id', stage: 'bridge', operator: 'Controller refused stale rollback/cleanup target id.' },
  host_mutation_not_false: { mode: 'REFUSE', title: 'Host mutation injection', stage: 'bridge', operator: 'Any host_mutation:true event is rewritten as visible refusal.' },
};

function incidentCopy(reason, fallbackStatus) {
  const key = String(reason || '').trim();
  const copy = INCIDENT_COPY[key] || {
    mode: /SKIP/i.test(String(fallbackStatus || '')) ? 'SKIP' : /REFUSE|refused/i.test(String(fallbackStatus || '')) ? 'REFUSE' : 'INCIDENT',
    title: key || 'Daemon incident',
    stage: 'daemon',
    operator: 'Fail closed; inspect event stream and preserve evidence.',
  };
  return copy;
}

// ── Lifecycle stages (canonical 7 from the run-all-lab/v1 bundle) ────────────
const STAGES = [
  { key: 'verifier_only',    label: 'verifier',      reason: 'VM-live replay verifier log accepted' },
  { key: 'partial_attach',   label: 'partial attach',reason: 'partial attach observed ops=zigsched_minimal' },
  { key: 'observe_partial',  label: 'observe',       reason: 'runtime samples linked to audit ledger' },
  { key: 'dsq_policy_smoke', label: 'dsq smoke',     reason: 'DSQ smoke observed no rejected tasks' },
  { key: 'stress_chaos',     label: 'stress',        reason: 'bounded stress replay completed' },
  { key: 'rollback_drill',   label: 'rollback',      reason: 'rollback drill completed and state restored' },
  { key: 'release_gate',     label: 'release gate',  reason: 'signed live proof gate intentionally withheld', skip: true },
];

// Pipeline shown to the operator (boot/attach framing from screens.zig vm-lab lanes).
const PIPELINE = [
  { key: 'preflight', label: 'preflight' },
  { key: 'build',     label: 'build' },
  { key: 'boot',      label: 'boot' },
  { key: 'marker',    label: 'marker' },
  { key: 'verifier',  label: 'verifier' },
  { key: 'attach',    label: 'attach' },
  { key: 'observe',   label: 'observe' },
  { key: 'rollback',  label: 'rollback' },
  { key: 'audit',     label: 'audit' },
  { key: 'cleanup',   label: 'cleanup' },
  { key: 'validate',  label: 'validate' },
];

// ── Guest workload observed inside the microVM (sched_switch comms) ──────────
// Guest-side tids/comms; NOT simulator task ids. zigsched_minimal is a minimal global-DSQ sched_ext.
const GUEST_TASKS = [
  { tid: 41,  comm: 'init',        cls: 'sys' },
  { tid: 188, comm: 'kworker/u8',  cls: 'sys' },
  { tid: 207, comm: 'sshd',        cls: 'svc' },
  { tid: 311, comm: 'stress-ng',   cls: 'load' },
  { tid: 312, comm: 'stress-ng',   cls: 'load' },
  { tid: 344, comm: 'bpftool',     cls: 'obs' },
  { tid: 402, comm: 'zigsched-rt', cls: 'rt'  },
  { tid: 455, comm: 'busybox',     cls: 'svc' },
];

const HIST_BUCKETS = [
  { lo: 0,   hi: 20,   label: '<20µs' },
  { lo: 20,  hi: 50,   label: '20-50' },
  { lo: 50,  hi: 100,  label: '50-100' },
  { lo: 100, hi: 200,  label: '100-200' },
  { lo: 200, hi: 500,  label: '200-500' },
  { lo: 500, hi: 1e9,  label: '500µs+' },
];

// small seeded RNG so a given run is repeatable-ish but lively
function mulberry32(a) {
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function freshRun(cfg) {
  const vcpus = cfg.vcpus || 4;
  const laneCols = cfg.laneCols || 64;
  const lanes = Array.from({ length: vcpus }, (_, c) => ({
    id: c,
    cells: Array(laneCols).fill('·'),           // task index or '·' idle
    util: Array(40).fill(0),                     // rolling util sparkline buffer
    last: null,
    onCpuUs: 0,
  }));
  return {
    phase: 'idle',                 // idle | booting | observing | rolling_back | stopping | done | stopped | refused
    armed: false,
    elapsedMs: 0,
    runId: null,
    actionId: null,
    auditId: null,
    rollbackId: null,
    bundlePath: 'none',
    target: cfg.target || TARGETS[0],
    refusal: null,
    // pipeline progress map: key -> 'pending'|'active'|'pass'|'skip'|'fail'
    pipeline: Object.fromEntries(PIPELINE.map(s => [s.key, 'pending'])),
    stages: STAGES.map(s => ({ ...s, status: 'pending' })),
    events: [],                    // firehose
    lanes,
    samples: [],                   // runtime samples (latency etc.)
    hist: HIST_BUCKETS.map(b => ({ ...b, n: 0 })),
    counters: { samples: 0, nr_rejected: 0, nr_switches: 0, nr_wakeups: 0, migrations: 0, dropped: 0 },
    latP50: 0, latP99: 0, dsqDepth: 0,
    incident: 'none',
    vmMarker: 'pending',
    cleanup: 'not-started',
    releaseEligible: false,
    labGate: 'pending',
    rollbackStatus: 'rollback required',
    confirm: null,                 // 'rollback' | 'stop' pending second press
    notice: null,                  // transient status line (header right)
    rng: mulberry32((cfg.seed || 7) >>> 0),
    _evSeq: 0,
    _sampleAcc: 0,
    _laneAcc: 0,
    _bootIdx: 0,
  };
}

function ev(run, kind, status, extra = {}) {
  run._evSeq = (run._evSeq || 0) + 1;
  const e = {
    seq: run._evSeq,
    tMs: run.elapsedMs,
    schema: EVENT_SCHEMA,
    action: LIVE_ACTION,
    event: kind,
    status,
    host_mutation: false,
    ...extra,
  };
  run.events.push(e);
  if (run.events.length > 220) run.events.splice(0, run.events.length - 220);
  return e;
}

// Boot/attach choreography keyed off run elapsed seconds (scaled by speed in the hook).
const BOOT_SEQ = [
  { at: 0.05, pkey: 'preflight', do: (r) => { r.pipeline.preflight = 'pass'; ev(r, 'stage_started', 'queued', { state: 'vm_only_pending', reason: 'microvm_live_runner_start' }); } },
  { at: 0.55, pkey: 'build',     do: (r) => { r.pipeline.build = 'pass'; ev(r, 'build', 'PASS', { state: 'image_built', reason: 'busybox guest image assembled' }); } },
  { at: 1.25, pkey: 'boot',      do: (r) => { r.pipeline.boot = 'pass'; ev(r, 'microvm_boot', 'PASS', { state: 'vm_live', reason: 'guest kernel booted' }); } },
  { at: 1.75, pkey: 'marker',    do: (r) => { r.pipeline.marker = 'pass'; r.vmMarker = '/run/zig-scheduler-vm-lab.marker'; ev(r, 'vm_marker', 'PASS', { state: 'vm_live', reason: 'vm marker present' }); } },
  { at: 2.45, pkey: 'verifier',  do: (r) => { r.pipeline.verifier = 'pass'; r.stages[0].status = 'pass'; ev(r, 'verifier', 'PASS', { state: 'verifier_ready', reason: 'verifier log accepted', artifact: 'verifier-only/verifier-log.txt' }); } },
  { at: 3.35, pkey: 'attach',    do: (r) => {
      r.pipeline.attach = 'active'; r.stages[1].status = 'pass';
      ev(r, 'bpf_register', 'PASS', { state: 'zigsched_minimal', reason: 'runtime ops observed', artifact: 'partial-attach/partial-attach-evidence.json' });
    } },
  { at: 3.9,  pkey: 'observe',   do: (r) => {
      r.pipeline.attach = 'pass'; r.pipeline.observe = 'active'; r.stages[2].status = 'active';
      r.phase = 'observing'; r.rollbackStatus = 'rollback ready'; r.labGate = 'observing';
      ev(r, 'attach', 'active', { state: 'observing', reason: 'live attach · streaming runtime samples' });
    } },
];

// advance the run by dt seconds of *run-time* (already speed-scaled)
function step(run, dtSec, cfg) {
  if (run.phase === 'idle' || run.phase === 'refused' || run.phase === 'done' || run.phase === 'stopped') return run;
  run.elapsedMs += dtSec * 1000;
  const sec = run.elapsedMs / 1000;

  // boot/attach choreography
  if (run.phase === 'booting' || run.phase === 'observing') {
    while (run._bootIdx < BOOT_SEQ.length && sec >= BOOT_SEQ[run._bootIdx].at) {
      BOOT_SEQ[run._bootIdx].do(run);
      run._bootIdx++;
    }
  }

  // smoke + stress stages light up while observing (auto, no host effect)
  if (run.phase === 'observing') {
    if (sec > 6.0 && run.stages[3].status === 'pending') { run.stages[3].status = 'pass'; ev(run, 'dsq_policy_smoke', 'PASS', { state: 'dsq_clean', reason: 'no rejected tasks' }); }
    if (sec > 9.0 && run.stages[4].status === 'pending') { run.stages[4].status = 'pass'; ev(run, 'stress_chaos', 'PASS', { state: 'stress_done', reason: 'bounded stress replay completed' }); }
  }

  const streaming = run.phase === 'observing' || run.phase === 'rolling_back' || run.phase === 'stopping';

  // ── per-vCPU lane scroll + util (scrolls only once guest is live) ──────────
  if (sec > 1.4 && streaming) {
    run._laneAcc += dtSec;
    const laneEvery = 0.11; // seconds per cell
    while (run._laneAcc >= laneEvery) {
      run._laneAcc -= laneEvery;
      const rampDown = run.phase !== 'observing'; // winding down during rollback/stop
      for (const lane of run.lanes) {
        let pick;
        const r = run.rng();
        const idleP = rampDown ? 0.5 : (lane.id === 0 ? 0.10 : 0.18);
        if (r < idleP) pick = '·';
        else {
          // weight toward load + rt tasks; occasional migration
          const pool = GUEST_TASKS.length;
          let ti = Math.floor(run.rng() * pool);
          if (run.rng() < 0.34) ti = [3,4,6][Math.floor(run.rng()*3)]; // stress-ng / zigsched-rt
          pick = ti;
        }
        if (pick !== '·' && pick !== lane.last && lane.last !== null && run.rng() < 0.4) run.counters.migrations++;
        lane.last = pick;
        lane.cells.push(pick);
        if (lane.cells.length > (cfg.laneCols || 64)) lane.cells.shift();
        const busy = pick !== '·';
        if (busy) { lane.onCpuUs += laneEvery * 1e6; run.counters.nr_switches++; }
        lane.util.push(busy ? 0.55 + run.rng() * 0.45 : run.rng() * 0.2);
        if (lane.util.length > 40) lane.util.shift();
      }
      if (run.rng() < 0.5) run.counters.nr_wakeups++;
    }
  }

  // ── runtime samples (latency observations) ────────────────────────────────
  if (run.phase === 'observing') {
    run._sampleAcc += dtSec;
    const sampleEvery = 1.4;
    while (run._sampleAcc >= sampleEvery) {
      run._sampleAcc -= sampleEvery;
      // runqueue-wait latency µs — mostly low, occasional tail
      const base = 8 + run.rng() * 26;
      const tail = run.rng() < 0.18 ? 60 + run.rng() * 380 : 0;
      const rqUs = Math.round(base + tail);
      const wakeUs = Math.round(4 + run.rng() * 22 + (run.rng() < 0.1 ? 120 : 0));
      run.dsqDepth = Math.max(0, Math.round(1 + run.rng() * 5 + (tail ? 3 : 0)));
      const s = { t: run.elapsedMs, rqUs, wakeUs, dsq: run.dsqDepth };
      run.samples.push(s);
      if (run.samples.length > 120) run.samples.shift();
      // histogram
      for (const b of run.hist) if (rqUs >= b.lo && rqUs < b.hi) { b.n++; break; }
      run.counters.samples++;
      // percentiles over recent window
      const recent = run.samples.slice(-40).map(x => x.rqUs).sort((a, b) => a - b);
      run.latP50 = recent[Math.floor(recent.length * 0.5)] || 0;
      run.latP99 = recent[Math.floor(recent.length * 0.99)] || recent[recent.length - 1] || 0;
      ev(run, 'runtime_sample', 'PASS', { state: 'observing', reason: `runtime samples accepted (rq=${rqUs}µs dsq=${run.dsqDepth})`, artifact: 'observe-partial/runtime-samples.jsonl' });
      // bundle path appears once samples flow
      if (run.bundlePath === 'none') run.bundlePath = `microvm-live-${run.runId}`;
    }
  }

  // ── rollback / stop wind-down ─────────────────────────────────────────────
  if (run.phase === 'rolling_back' || run.phase === 'stopping') {
    run._wind = (run._wind || 0) + dtSec;
    if (run._wind > 0.9 && run.stages[5].status !== 'pass') {
      run.pipeline.observe = 'pass'; run.pipeline.rollback = 'pass';
      run.stages[2].status = 'pass'; run.stages[5].status = 'pass';
      run.rollbackStatus = 'rollback ready/completed';
      ev(run, 'rollback', 'PASS', { state: 'rolled_back', reason: 'state restored', artifact: 'rollback-drill/audit-ledger.jsonl' });
    }
    if (run._wind > 1.7 && run.pipeline.audit !== 'pass') {
      run.pipeline.audit = 'pass';
      ev(run, 'audit', 'PASS', { state: 'audited', reason: 'runtime samples linked to audit ledger', artifact: `${run.bundlePath}/summary.json` });
    }
    if (run._wind > 2.4 && run.cleanup === 'not-started') {
      run.pipeline.cleanup = 'pass'; run.cleanup = 'cleanup receipt PASS';
      ev(run, 'cleanup', 'PASS', { state: 'clean', reason: 'process scan clean · no qemu/tmux leftovers', artifact: `${run.bundlePath}/summary.json` });
    }
    if (run._wind > 3.1) {
      run.pipeline.validate = run.phase === 'rolling_back' ? 'pass' : 'pass';
      run.stages[6].status = 'skip';
      run.labGate = 'live bundle freshness accepted';
      run.releaseEligible = false;
      ev(run, 'validation', 'PASS', { state: 'vm_live_validated', reason: 'live bundle freshness accepted · signed live proof withheld', artifact: `${run.bundlePath}/summary.json` });
      ev(run, 'release_gate', 'SKIP', { state: 'withheld', reason: 'signed live proof gate intentionally withheld' });
      run.phase = run.phase === 'rolling_back' ? 'done' : 'stopped';
      run.notice = run.phase === 'done' ? 'PASS · not release eligible' : 'stopped · rolled back';
    }
  }

  return run;
}



// Ingest real daemon-event/v1 rows from the local browser bridge. The visual model
// remains the same as the authoritative design, but event arrival can now drive the
// lifecycle/firehose instead of only the internal simulator clock.
function ingestDaemonEvent(run, raw, cfg) {
  if (!raw || typeof raw !== 'object') return run;
  let next = run;
  if (next.phase === 'idle') {
    next = freshRun(cfg || {});
    next.phase = 'booting';
    next.armed = true;
  }
  const e = {
    seq: raw.seq || raw.sequence || ((next._evSeq || 0) + 1),
    tMs: next.elapsedMs,
    schema: raw.schema || EVENT_SCHEMA,
    action: raw.action || LIVE_ACTION,
    event: raw.event || 'incident',
    status: raw.status || 'unknown',
    host_mutation: raw.host_mutation === false,
    action_id: raw.action_id || next.actionId || undefined,
    rollback_id: raw.rollback_id || next.rollbackId || undefined,
    target_action_id: raw.target_action_id || undefined,
    reason: raw.reason || undefined,
    state: raw.state || undefined,
    artifact: raw.artifact || raw.live_bundle_path || undefined,
    sample_sequence: raw.sample_sequence || undefined,
  };
  next._evSeq = Math.max(next._evSeq || 0, Number(e.seq) || 0);
  next.events.push(e);
  if (next.events.length > 220) next.events.splice(0, next.events.length - 220);
  if (e.action_id) {
    next.actionId = e.action_id;
    next.runId = e.action_id;
  }
  if (e.rollback_id) next.rollbackId = e.rollback_id;
  if (raw.audit_id) next.auditId = raw.audit_id;

  if (raw.host_mutation !== false) return applyIncident(next, 'host_mutation_not_false', 'REFUSE', e);

  const event = String(e.event || '');
  const status = String(e.status || '');
  const reason = String(e.reason || '');
  const bad = /REFUSE|SKIP|refused|failed|unsafe_to_assume|incident/i.test(status) || /refusal|incident/.test(event) || /timeout|residue|reject|stale|duplicate|lost_stream/.test(reason);
  if (bad) return applyIncident(next, reason || event, status, e);

  if (event === 'stage_started') {
    next.phase = 'booting';
    next.pipeline.preflight = 'pass';
    next.notice = 'ACTION queued run_lab_microvm_live · rollback ready';
  } else if (event === 'microvm_boot') {
    next.pipeline.build = 'pass';
    next.pipeline.boot = 'pass';
  } else if (event === 'vm_marker') {
    next.pipeline.marker = 'pass';
    next.vmMarker = raw.vm_marker_path || raw.artifact || '/run/zig-scheduler-vm-lab.marker';
  } else if (event === 'bpf_register') {
    next.pipeline.verifier = 'pass';
    next.pipeline.attach = 'pass';
    next.stages[0].status = 'pass';
    next.stages[1].status = 'pass';
  } else if (event === 'runtime_sample') {
    next.phase = 'observing';
    next.pipeline.attach = 'pass';
    next.pipeline.observe = 'active';
    next.stages[2].status = 'active';
    next.rollbackStatus = 'rollback ready';
    next.labGate = 'observing';
    next.notice = 'daemon event stream active · observing';
    next.counters.samples++;
    next.dsqDepth = Number(raw.dsq || raw.dsq_depth || next.dsqDepth || 2);
    const rqUs = Number(raw.rq_us || raw.runqueue_us || raw.latency_us || (8 + (next.counters.samples % 9) * 17));
    next.samples.push({ t: next.elapsedMs, rqUs, wakeUs: Number(raw.wake_us || 0), dsq: next.dsqDepth });
    if (next.samples.length > 120) next.samples.shift();
    for (const b of next.hist) if (rqUs >= b.lo && rqUs < b.hi) { b.n++; break; }
    const recent = next.samples.slice(-40).map(x => x.rqUs).sort((a, b) => a - b);
    next.latP50 = recent[Math.floor(recent.length * 0.5)] || 0;
    next.latP99 = recent[Math.floor(recent.length * 0.99)] || recent[recent.length - 1] || 0;
    if (next.bundlePath === 'none') next.bundlePath = raw.artifact || `microvm-live-${next.runId || 'web'}`;
  } else if (event === 'rollback') {
    next.phase = /active/i.test(status) ? 'rolling_back' : next.phase;
    next.pipeline.rollback = /PASS/i.test(status) ? 'pass' : 'active';
    next.stages[5].status = /PASS/i.test(status) ? 'pass' : 'active';
    next.rollbackStatus = /PASS/i.test(status) ? 'rollback ready/completed' : 'rollback active';
    next.notice = /PASS/i.test(status) ? 'rollback complete · cleanup pending' : 'ROLLBACK active';
  } else if (event === 'cleanup') {
    next.pipeline.cleanup = 'pass';
    next.cleanup = 'cleanup receipt PASS';
    next.notice = 'CLEANUP complete · host unchanged';
  } else if (event === 'validation') {
    next.pipeline.validate = 'pass';
    next.stages[6].status = 'skip';
    next.labGate = 'live bundle freshness accepted';
    next.phase = 'done';
    next.notice = 'PASS · not release eligible';
  }
  return next;
}

function applyIncident(run, reason, status, event) {
  const copy = incidentCopy(reason, status);
  run.phase = 'refused';
  run.pipeline.preflight = run.pipeline.preflight === 'pending' ? 'pass' : run.pipeline.preflight;
  if (copy.stage === 'verifier') run.pipeline.verifier = 'fail';
  else if (copy.stage === 'rollback') run.pipeline.rollback = 'fail';
  else if (copy.stage === 'cleanup') run.pipeline.cleanup = 'fail';
  else if (copy.stage === 'bridge') run.pipeline.preflight = 'fail';
  else run.pipeline.boot = copy.mode === 'SKIP' ? 'skip' : 'fail';
  run.incident = `${copy.mode} · ${reason || copy.title}`;
  run.incidentDetail = {
    mode: copy.mode,
    title: copy.title,
    reason: reason || copy.title,
    stage: copy.stage,
    operator: copy.operator,
    event: event && event.event ? event.event : 'incident',
  };
  run.labGate = 'closed';
  run.rollbackStatus = copy.stage === 'rollback' ? 'rollback unsafe_to_assume' : 'no attach · host unchanged';
  run.cleanup = copy.stage === 'cleanup' ? 'cleanup residue' : run.cleanup;
  run.notice = `${copy.mode} ${copy.title} · ${reason || ''}`.trim();
  run.refusal = { kind: copy.mode, reason: reason || copy.title, msg: run.notice };
  return run;
}

// commands
function cmdArm(run, cfg) {
  if (run.armed && (run.phase === 'observing' || run.phase === 'booting')) { run.notice = 'live VM already armed · rollback ready'; return run; }
  const next = freshRun(cfg);
  const pid = 1000 + Math.floor((cfg.seed || 7) % 9000);
  next.armed = true;
  next.phase = 'booting';
  next.runId = `tui-vm-lab-${pid}`;
  next.actionId = `tui-vm-lab-${pid}`;
  next.auditId = `AUD-tui-vm-lab-${pid}`;
  next.rollbackId = `RB-tui-vm-lab-${pid}`;
  next.target = cfg.target || TARGETS[0];
  next.notice = 'ACTION queued run_lab_microvm_live · rollback ready';
  // refusal path — fail closed immediately
  const ref = REFUSALS[cfg.refusal || 'none'] || (next.target.kvm === false ? REFUSALS.kvm_unavailable : null);
  if (ref) {
    next.pipeline.preflight = 'pass';
    next.pipeline.build = ref.reason === 'nix_busybox_unavailable' ? 'fail' : 'pass';
    next.pipeline.boot = 'fail';
    ev(next, 'stage_started', 'queued', { state: 'vm_only_pending', reason: 'microvm_live_runner_start' });
    ev(next, 'stage_finished', ref.kind, { state: 'fail_closed', reason: ref.reason });
    next.phase = 'refused';
    applyIncident(next, ref.reason, ref.kind, { event: 'stage_finished' });
  }
  return next;
}
function cmdRollback(run) {
  if (run.phase !== 'observing' && run.phase !== 'booting') { run.notice = 'rollback refused · no live target'; return run; }
  if (run.confirm !== 'rollback') { run.confirm = 'rollback'; run.notice = 'CONFIRM rollback — press b again'; return run; }
  run.confirm = null; run.phase = 'rolling_back'; run._wind = 0;
  run.notice = 'ACTION queued rollback_lab_run · target rollback id';
  ev(run, 'rollback', 'active', { state: 'rolling_back', reason: 'operator confirmed rollback' });
  return run;
}
function cmdStop(run) {
  if (run.phase !== 'observing' && run.phase !== 'booting') { run.notice = 'stop refused · no live target'; return run; }
  if (run.confirm !== 'stop') { run.confirm = 'stop'; run.notice = 'CONFIRM stop — press s again'; return run; }
  run.confirm = null; run.phase = 'stopping'; run._wind = 0;
  run.notice = 'ACTION queued stop_lab_run · target rollback id';
  ev(run, 'stop', 'active', { state: 'stopping', reason: 'operator confirmed safe stop' });
  return run;
}

Object.assign(window, {
  EVENT_SCHEMA, LIVE_ACTION, TARGETS, REFUSALS, STAGES, PIPELINE, GUEST_TASKS, HIST_BUCKETS,
  freshRun, step, ingestDaemonEvent, cmdArm, cmdRollback, cmdStop, ev,
  INCIDENT_COPY, incidentCopy, applyIncident,
});
