// live-views.jsx — composed panes for the live microVM lab operator surface.

// ── Header bar ──────────────────────────────────────────────────────────────
function HeaderBar({ t, run, daemonMs, theme, bridgeStatus }) {
  const attached = run.phase !== 'idle';
  const conn = run.phase === 'refused'
    ? { c: t.danger, txt: 'runner fail-closed' }
    : attached
      ? { c: t.success, txt: `attached · ${daemonMs.toFixed(1)}ms rtt` }
      : { c: t.warning, txt: 'idle · local' };
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 16, padding: '0 16px', height: 34,
      borderBottom: `1px solid ${t.border}`, background: t.surfaceAlt, flex: '0 0 auto',
    }}>
      <span style={{ color: t.accent, fontWeight: 700, fontSize: 14.5, letterSpacing: 0.3 }}>▚ zig-scheduler</span>
      <span style={{ color: t.border, opacity: 0.7 }}>│</span>
      <span style={{ color: t.fgBright, fontSize: 13, letterSpacing: 0.2 }}>live microVM lab</span>
      <span style={{ color: t.muted, fontSize: 11 }}>vm-lab · {run.target.release}</span>
      <span style={{ marginLeft: 'auto', display: 'inline-flex', alignItems: 'center', gap: 8 }}>
        <span className={attached ? 'v-pulse' : ''} style={{ width: 7, height: 7, borderRadius: 7, background: conn.c, boxShadow: `0 0 8px ${conn.c}` }} />
        <span style={{ color: conn.c, fontSize: 11.5 }}>daemon {conn.txt}</span>
      </span>
      <span style={{ color: t.border, opacity: 0.7 }}>│</span>
      <span style={{ color: bridgeStatus && bridgeStatus.schema ? t.success : t.muted, fontSize: 11 }}>
        bridge {bridgeStatus && (bridgeStatus.bridge_mode || bridgeStatus.mode) ? (bridgeStatus.bridge_mode || bridgeStatus.mode) : 'design-simulation'} · host_mutation=<span style={{ color: t.success }}>false</span>
      </span>
      <span style={{ color: t.border, opacity: 0.7 }}>│</span>
      <span style={{ color: t.muted, fontSize: 11 }}>theme <span style={{ color: t.fg }}>{theme}</span> <span style={{ color: t.accent }}>▸ w</span></span>
    </div>
  );
}

// notice / mode strip under header
function ModeStrip({ t, run }) {
  const incident = run.incident && run.incident !== 'none';
  const modeLabel = incident ? (run.refusal && run.refusal.kind ? run.refusal.kind : 'INCIDENT') : 'NORMAL';
  const noticeCol = run.confirm ? t.warning
    : incident ? (modeLabel === 'SKIP' ? t.warning : t.danger)
    : run.phase === 'done' ? t.success
    : run.notice && /PASS|ready|accepted/.test(run.notice) ? t.success : t.accent;
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 14, padding: '0 16px', height: 27, background: t.bg, flex: '0 0 auto', borderBottom: `1px solid ${t.faint}` }}>
      <Pill t={t} label={modeLabel} color={incident ? noticeCol : t.accent} />
      <span style={{ color: t.muted, fontSize: 11.5 }}>run <span style={{ color: t.fg, fontVariantNumeric: 'tabular-nums' }}>{run.runId || '—'}</span></span>
      <span style={{ color: t.muted, fontSize: 11.5 }}>elapsed <span style={{ color: t.fg, fontVariantNumeric: 'tabular-nums' }}>{(run.elapsedMs / 1000).toFixed(1)}s</span></span>
      <span style={{ color: t.border, opacity: 0.7 }}>│</span>
      <span style={{ color: noticeCol, fontSize: 12, fontWeight: 600, letterSpacing: 0.2 }}>
        {run.notice || (run.phase === 'idle' ? 'press m to request a fresh disposable microVM lab run' : 'streaming runtime samples…')}
        {run.confirm && <span className="v-blink"> ▌</span>}
      </span>
    </div>
  );
}

function IncidentPane({ t, run }) {
  if (!run.incident || run.incident === 'none') return null;
  const detail = run.incidentDetail || incidentCopy(run.refusal && run.refusal.reason, run.refusal && run.refusal.kind);
  const mode = detail.mode || (run.refusal && run.refusal.kind) || 'INCIDENT';
  const color = mode === 'SKIP' ? t.warning : t.danger;
  return (
    <Pane t={t} title={`${mode} · ${detail.title || 'incident'}`} sub="first-class failure state" accent={color}
      contentStyle={{ gap: 8 }}>
      <div style={{ display: 'grid', gridTemplateColumns: '92px 1fr', gap: '5px 10px', fontSize: 12 }}>
        <span style={{ color: t.muted }}>state</span>
        <span style={{ color, fontWeight: 800, letterSpacing: 0.8 }}>{mode}</span>
        <span style={{ color: t.muted }}>reason</span>
        <span style={{ color: t.fgBright }}>{detail.reason || run.incident}</span>
        <span style={{ color: t.muted }}>stage</span>
        <span style={{ color: t.fg }}>{detail.stage || 'daemon'}</span>
        <span style={{ color: t.muted }}>operator</span>
        <span style={{ color: t.muted }}>{detail.operator || 'Fail closed; preserve evidence.'}</span>
      </div>
      <SectionLine t={t} left="safety invariant" right="visible refusal" />
      <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8, fontSize: 11.5 }}>
        <span style={{ color: t.success }}>host_mutation=false</span>
        <span style={{ color }}>release gate closed</span>
      </div>
    </Pane>
  );
}

// ── Lifecycle pipeline ───────────────────────────────────────────────────────
function PipelinePane({ t, run }) {
  const statusCol = (s) => s === 'pass' ? t.success : s === 'active' ? t.accent : s === 'fail' ? t.danger : s === 'skip' ? t.warning : t.muted;
  const glyph = (s) => s === 'pass' ? '✓' : s === 'active' ? '▶' : s === 'fail' ? '✗' : s === 'skip' ? '⊘' : '·';
  const done = PIPELINE.filter(p => run.pipeline[p.key] === 'pass').length;
  const prog = Math.round((done / PIPELINE.length) * 12);
  return (
    <Pane t={t} title="lifecycle" sub="disposable microVM · VM-only attach" right={`${done}/${PIPELINE.length}`}>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '7px 10px' }}>
        {PIPELINE.map(p => {
          const s = run.pipeline[p.key];
          return (
            <div key={p.key} style={{ display: 'flex', alignItems: 'center', gap: 6, opacity: s === 'pending' ? 0.45 : 1 }}>
              <span style={{ color: statusCol(s), fontSize: 12, width: 12, textAlign: 'center' }} className={s === 'active' ? 'v-blink' : ''}>{glyph(s)}</span>
              <span style={{ color: s === 'pending' ? t.muted : t.fgBright, fontSize: 11.5 }}>{p.label}</span>
            </div>
          );
        })}
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 11 }}>
        <span style={{ color: t.success, fontFamily: MONO, fontSize: 13, letterSpacing: 0 }}>
          {'▰'.repeat(prog)}<span style={{ color: t.faint }}>{'▱'.repeat(12 - prog)}</span>
        </span>
        <span style={{ color: t.muted, fontSize: 10.5 }}>host_mutation=<span style={{ color: t.success }}>false</span></span>
      </div>
      <SectionLine t={t} left="stage ledger" right="run-all-lab/v1" />
      <div style={{ display: 'flex', flexDirection: 'column' }}>
        {run.stages.map(s => (
          <KV key={s.key} t={t} kw={130} k={s.key}
            v={s.status === 'pending' ? 'pending' : s.status === 'active' ? 'observing' : s.skip ? 'SKIP' : 'PASS'}
            vColor={statusCol(s.status === 'active' ? 'active' : s.status === 'pass' ? 'pass' : s.skip && s.status !== 'pending' ? 'skip' : 'pending')}
            note={s.skip ? 'withheld' : s.reason.length > 26 ? s.reason.slice(0, 26) + '…' : s.reason} />
        ))}
      </div>
    </Pane>
  );
}

// ── Gate ledger / safety contract ─────────────────────────────────────────────
function GateLedgerPane({ t, run }) {
  const c = statusColor;
  return (
    <Pane t={t} title="gate ledger" sub="fail-closed · not release proof" accent={t.warning}
      contentStyle={{ justifyContent: 'space-between', gap: 6 }}>
      <div>
        <KV t={t} k="lab scope" v={run.target ? 'lab-only vm guest' : '—'} note="host fail-closed" vColor={t.fg} />
        <KV t={t} k="vm marker" v={run.vmMarker} note="vm-live" vColor={c(t, run.vmMarker)} />
        <KV t={t} k="kernel tuple" v={run.target.release} note={run.target.arch} vColor={t.fg} />
        <KV t={t} k="bundle" v={run.bundlePath} note={run.cleanup} vColor={run.bundlePath === 'none' ? t.muted : t.fg} />
      </div>
      <div>
        <SectionLine t={t} left="audit · rollback" style={{ marginTop: 0 }} />
        <KV t={t} k="audit id" v={run.auditId || 'AUD-tui-vm-lab'} note="ledger linked" vColor={t.fg} />
        <KV t={t} k="rollback id" v={run.rollbackId || 'RB-tui-vm-lab'} note={run.rollbackStatus} vColor={c(t, run.rollbackStatus)} />
        <KV t={t} k="cleanup" v={run.cleanup} note="process scan" vColor={c(t, run.cleanup)} />
      </div>
      <div>
        <SectionLine t={t} left="release gate" style={{ marginTop: 0 }} />
        <KV t={t} k="release eligible" v={run.releaseEligible ? 'eligible' : 'not release eligible'} note="proof withheld" vColor={run.releaseEligible ? t.success : t.warning} />
        <KV t={t} k="approved lab" v={run.labGate} note="load absent" vColor={c(t, run.labGate)} />
      </div>
    </Pane>
  );
}

// ── Alert / threshold strip ───────────────────────────────────────────────────
function AlertStrip({ t, run }) {
  const dsq = run.dsqDepth;
  const starv = run.latP99 > 300;
  const dropped = run.counters.dropped;
  const items = [
    { k: 'runqueue depth', v: `dsq=${dsq}`, lvl: dsq >= 6 ? 'warn' : 'ok', note: dsq >= 6 ? 'backlog building' : 'within bound' },
    { k: 'starvation watch', v: starv ? `p99 ${run.latP99}µs` : 'clear', lvl: starv ? 'warn' : 'ok', note: 'wakeup→run tail' },
    { k: 'nr_rejected', v: run.counters.nr_rejected, lvl: run.counters.nr_rejected ? 'crit' : 'ok', note: 'must stay 0' },
    { k: 'dropped events', v: dropped, lvl: dropped ? 'crit' : 'ok', note: 'stream backpressure' },
    { k: 'incident', v: run.incident, lvl: run.incident !== 'none' ? 'crit' : 'ok', note: 'unsafe_to_assume on gaps' },
  ];
  const col = (l) => l === 'crit' ? t.danger : l === 'warn' ? t.warning : t.success;
  return (
    <Pane t={t} title="alert strip" sub="thresholds" accent={items.some(i => i.lvl !== 'ok') ? t.warning : t.success} flush>
      <div style={{ display: 'flex', flexDirection: 'column', flex: 1, minHeight: 0 }}>
        {items.map((it, i) => (
          <div key={it.k} style={{ flex: 1, display: 'grid', gridTemplateColumns: '16px 116px 1fr auto', gap: 9, alignItems: 'center', padding: '0 13px', borderTop: i ? `1px solid ${t.faint}` : 'none' }}>
            <span className={it.lvl !== 'ok' ? 'v-blink' : ''} style={{ color: col(it.lvl), fontSize: 11 }}>{it.lvl === 'ok' ? '●' : '▲'}</span>
            <span style={{ color: t.muted, fontSize: 12 }}>{it.k}</span>
            <span style={{ color: col(it.lvl), fontSize: 12.5, fontWeight: 600, fontVariantNumeric: 'tabular-nums' }}>{it.v}</span>
            <span style={{ color: t.muted, fontSize: 10 }}>{it.note}</span>
          </div>
        ))}
      </div>
    </Pane>
  );
}

// ── vCPU telemetry ────────────────────────────────────────────────────────────
function VcpuPane({ t, run }) {
  const active = run.phase === 'observing';
  const totalUtil = run.lanes.reduce((a, l) => a + (l.util.slice(-1)[0] || 0), 0) / run.lanes.length;
  return (
    <Pane t={t} title="vCPU runtime" sub="zigsched_minimal · sched_ext · observed — no perf claim"
      right={`${run.lanes.length} vCPU · Σ ${(totalUtil * 100).toFixed(0)}%`} accent={t.accent} contentStyle={{ gap: 0 }}>
      {/* scrolling lanes fill available height */}
      <div style={{ display: 'flex', flexDirection: 'column', flex: 1, minHeight: 90, gap: 7 }}>
        {run.lanes.map(l => <LaneStrip key={l.id} t={t} lane={l} tasks={GUEST_TASKS} cols={run.cells || 56} active={active} />)}
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 15, marginTop: 10, paddingTop: 9, borderTop: `1px solid ${t.faint}`, flexWrap: 'wrap' }}>
        {[['rt', t.accent], ['load', t.danger], ['svc', t.success], ['sys', t.warning], ['obs', t.fgBright], ['idle', null]].map(([k, c]) => (
          <span key={k} style={{ display: 'inline-flex', alignItems: 'center', gap: 6, fontSize: 10, color: t.muted }}>
            <span style={{ width: 13, height: 9, background: c || 'transparent', borderBottom: c ? 'none' : `1px solid ${t.faint}` }} />{k}
          </span>
        ))}
      </div>
      <SectionLine t={t} left="per-vCPU utilization" right="rolling" />
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '4px 22px' }}>
        {run.lanes.map(l => (
          <div key={l.id} style={{ display: 'flex', alignItems: 'center', gap: 9 }}>
            <span style={{ color: t.muted, fontSize: 11, width: 32 }}>cpu{l.id}</span>
            <Sparkline t={t} data={l.util} color={t.accent} h={15} />
            <span style={{ color: t.fg, fontSize: 11, marginLeft: 'auto', fontVariantNumeric: 'tabular-nums' }}>{((l.util.slice(-1)[0] || 0) * 100).toFixed(0)}%</span>
          </div>
        ))}
      </div>
    </Pane>
  );
}

// ── latency histogram + counters ──────────────────────────────────────────────
function LatencyPane({ t, run }) {
  const maxN = Math.max(1, ...run.hist.map(b => b.n));
  return (
    <Pane t={t} title="runqueue latency" sub="runqueue-wait · observed distribution" accent={t.accent}
      right={`p50 ${run.latP50}µs · p99 ${run.latP99}µs`}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
        {run.hist.map(b => (
          <div key={b.label} style={{ display: 'grid', gridTemplateColumns: '64px 1fr 30px', gap: 10, alignItems: 'center', fontSize: 12 }}>
            <span style={{ color: t.muted }}>{b.label}</span>
            <Bar t={t} value={b.n} max={maxN} width={30} color={b.lo >= 200 ? t.danger : b.lo >= 50 ? t.warning : t.success} />
            <span style={{ color: t.fg, textAlign: 'right', fontSize: 11, fontVariantNumeric: 'tabular-nums' }}>{b.n}</span>
          </div>
        ))}
      </div>
      <SectionLine t={t} left="runtime counters" right="nr_rejected stable" />
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '2px 22px' }}>
        <KV t={t} kw={96} k="samples" v={`x${run.counters.samples}`} note="before/during/after" vColor={t.fg} />
        <KV t={t} kw={96} k="nr_rejected" v={run.counters.nr_rejected} note="must stay 0" vColor={run.counters.nr_rejected ? t.danger : t.success} />
        <KV t={t} kw={96} k="switches" v={run.counters.nr_switches} note="sched_switch" vColor={t.fg} />
        <KV t={t} kw={96} k="wakeups" v={run.counters.nr_wakeups} note="sched_wakeup" vColor={t.fg} />
        <KV t={t} kw={96} k="migrations" v={run.counters.migrations} note="cross-vCPU" vColor={t.fg} />
        <KV t={t} kw={96} k="ops" v="zigsched_minimal" note="attach-only" vColor={t.accent} />
      </div>
    </Pane>
  );
}

// ── event firehose ────────────────────────────────────────────────────────────
const FILTERS = ['all', 'lifecycle', 'runtime_sample', 'rollback', 'incident'];
function FirehosePane({ t, run, filter, setFilter }) {
  const evs = run.events.filter(e => {
    if (filter === 'all') return true;
    if (filter === 'lifecycle') return !/runtime_sample/.test(e.event);
    if (filter === 'runtime_sample') return e.event === 'runtime_sample';
    if (filter === 'rollback') return /rollback|stop|cleanup|validation|audit/.test(e.event);
    if (filter === 'incident') return /incident|refus|stage_finished/.test(e.event) && (e.status === 'REFUSE' || e.status === 'SKIP' || e.event === 'incident');
    return true;
  }).slice(-200);
  const scRef = React.useRef(null);
  React.useEffect(() => { if (scRef.current) scRef.current.scrollTop = scRef.current.scrollHeight; }, [run.events.length, filter]);
  const stCol = (e) => e.status === 'PASS' ? t.success : e.status === 'REFUSE' || e.status === 'SKIP' || e.event === 'incident' ? t.danger
    : e.status === 'queued' || e.status === 'active' ? t.warning : t.fg;
  return (
    <Pane t={t} title="daemon event stream" sub="daemon-event/v1" accent={t.accent}
      right={`${run.events.length} ev`} flush>
      <div style={{ display: 'flex', gap: 6, padding: '8px 11px', borderBottom: `1px solid ${t.faint}`, flexWrap: 'wrap' }}>
        {FILTERS.map(f => (
          <span key={f} className="v-clk" onClick={() => setFilter(f)} style={{
            fontSize: 10, padding: '2px 9px', borderRadius: 3, letterSpacing: 0.5,
            border: `1px solid ${filter === f ? t.accent : t.faint}`,
            color: filter === f ? t.accent : t.muted, background: filter === f ? t.selBg : 'transparent',
          }}>{f}</span>
        ))}
      </div>
      <div ref={scRef} style={{ flex: '1 1 auto', overflow: 'auto', padding: '6px 0', minHeight: 0 }}>
        {evs.length === 0 && <div style={{ color: t.muted, fontSize: 12, padding: '10px 13px' }}>no events — press m to launch a run</div>}
        {evs.map((e) => (
          <div key={e.seq} className="v-fade-in" style={{ display: 'grid', gridTemplateColumns: '50px 14px 1fr', gap: 9, alignItems: 'baseline', padding: '2px 13px', fontSize: 11.5, lineHeight: '17px' }}>
            <span style={{ color: t.muted, fontVariantNumeric: 'tabular-nums' }}>{(e.tMs / 1000).toFixed(2)}s</span>
            <span style={{ color: stCol(e), textAlign: 'center' }}>{e.status === 'PASS' ? '✓' : e.status === 'queued' ? '·' : e.status === 'active' ? '▶' : '✗'}</span>
            <span style={{ whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
              <span style={{ color: t.accent }}>{e.event}</span>
              <span style={{ color: stCol(e), fontWeight: 600 }}> {e.status}</span>
              {e.reason && <span style={{ color: t.muted }}> · {e.reason}</span>}
            </span>
          </div>
        ))}
      </div>
      <div style={{ padding: '6px 13px', borderTop: `1px solid ${t.faint}`, color: t.muted, fontSize: 10, display: 'flex', justifyContent: 'space-between', gap: 8 }}>
        <span>host_mutation=<span style={{ color: t.success }}>false</span></span>
        <span style={{ whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>journal → {run.bundlePath === 'none' ? '.omo/evidence/tui-live-vm' : run.bundlePath}</span>
      </div>
    </Pane>
  );
}

Object.assign(window, { HeaderBar, ModeStrip, IncidentPane, PipelinePane, GateLedgerPane, AlertStrip, VcpuPane, LatencyPane, FirehosePane, FILTERS });
