// live-app.jsx — full-bleed live microVM lab operator TUI: shell, keyboard, scaling, Tweaks.
const { useState: uS, useEffect: uE, useRef: uR, useCallback: uCb } = React;

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "theme": "black",
  "speed": 1,
  "vcpus": 4,
  "density": "standard",
  "target": "sched-ext-lab",
  "refusal": "none",
  "autoLaunch": true
}/*EDITMODE-END*/;

const THEME_ORDER = ['black', 'cool', 'paper', 'mocha', 'latte'];
function nextTheme(cur) {
  const i = THEME_ORDER.indexOf(cur);
  return THEME_ORDER[(i + 1) % THEME_ORDER.length] || 'black';
}

// ── Attach picker (idle) ──────────────────────────────────────────────────────
function AttachPicker({ t, targets, selected, setSelected, onArm, refusal }) {
  return (
    <div style={{ flex: 1, display: 'grid', gridTemplateColumns: '1.15fr 1fr', gap: 12, padding: 12, minHeight: 0 }}>
      <Pane t={t} title="attach target" sub="disposable microVM · VM-only path" accent={t.accent}>
        <div style={{ color: t.muted, fontSize: 12, marginBottom: 8, lineHeight: 1.5 }}>
          The host stays fail-closed. <span style={{ color: t.warning }}>load · attach · enable · mutate · apply</span> are refused on the host.
          A live run boots a throwaway guest, registers <span style={{ color: t.accent }}>zigsched_minimal</span> inside it, and streams runtime samples.
        </div>
        <SectionLine t={t} left="pick a tuple" right="↵ / m to arm" />
        <div style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
          {targets.map((tg, i) => {
            const ok = tg.qemu && tg.kvm && tg.nix;
            const sel = i === selected;
            return (
              <div key={tg.id} className="v-clk" onClick={() => setSelected(i)} style={{
                border: `1px solid ${sel ? t.accent : t.faint}`, borderRadius: 3, padding: '7px 10px',
                background: sel ? t.selBg : 'transparent', display: 'grid', gridTemplateColumns: '16px 1fr auto', gap: 9, alignItems: 'center',
              }}>
                <span style={{ color: sel ? t.accent : t.muted, fontSize: 13 }}>{sel ? '▸' : (i + 1)}</span>
                <div>
                  <div style={{ color: t.fgBright, fontSize: 12.5 }}>{tg.release} <span style={{ color: t.muted }}>· {tg.arch}</span></div>
                  <div style={{ color: t.muted, fontSize: 10.5 }}>{tg.note}</div>
                </div>
                <Pill t={t} label={ok ? 'READY' : 'SKIP'} color={ok ? t.success : t.warning} />
              </div>
            );
          })}
        </div>
        <div style={{ marginTop: 'auto', paddingTop: 10, display: 'flex', gap: 8, alignItems: 'center' }}>
          <button onClick={onArm} className="v-clk" style={{
            background: t.accent, color: t.bg, border: 'none', borderRadius: 3, padding: '7px 16px',
            fontFamily: MONO, fontWeight: 700, fontSize: 12.5, letterSpacing: 0.5, cursor: 'pointer',
          }}>m ▸ request live microVM run</button>
          <span style={{ color: t.muted, fontSize: 11 }}>arms rollback + audit ids before any attach</span>
        </div>
      </Pane>
      <Pane t={t} title="preflight" sub="read-only host facts" accent={t.warning}>
        <KV t={t} k="sched_ext" v="host fail-closed" note="no BPF load on host" vColor={t.warning} />
        <KV t={t} k="cgroup v2" v="vm-only" note="no cgroup writes" vColor={t.fg} />
        <KV t={t} k="capabilities" v="host unchanged" note="refuse unsafe verbs" vColor={t.fg} />
        <KV t={t} k="BTF" v="lab gate required" note="no load before approval" vColor={t.warning} />
        <SectionLine t={t} left="fail-closed outcomes" />
        <div style={{ display: 'flex', flexDirection: 'column', gap: 3, fontSize: 11.5, color: t.muted }}>
          {['SKIP: qemu unavailable', 'SKIP: kvm unavailable', 'REFUSE: VM_CONFIG_INVALID', 'REFUSE: nix_busybox_unavailable'].map(x => (
            <div key={x} style={{ display: 'flex', gap: 7 }}>
              <span style={{ color: t.danger }}>{x.split(':')[0]}</span>
              <span style={{ color: t.muted }}>{x.split(':')[1]}</span>
            </div>
          ))}
          <div style={{ marginTop: 4, color: t.muted }}>every refusal keeps <span style={{ color: t.success }}>host_mutation=false</span></div>
        </div>
        {refusal !== 'none' && (
          <div style={{ marginTop: 'auto', padding: '6px 9px', border: `1px solid ${t.danger}`, borderRadius: 3, color: t.danger, fontSize: 11.5 }}>
            tweak armed: this run will fail closed → <b>{refusal}</b>
          </div>
        )}
      </Pane>
    </div>
  );
}

// ── Help overlay ──────────────────────────────────────────────────────────────
function HelpOverlay({ t, onClose }) {
  const keys = [
    ['m', 'request fresh disposable microVM lab run'],
    ['b', 'rollback — confirm with a second b'],
    ['s', 'safe stop — confirm with a second s'],
    ['h', 'home / attach picker'],
    ['w', 'theme · warm dark ⇄ cool dark'],
    ['?', 'toggle this help'],
    ['q', 'quit'],
    ['1-3', 'pick attach target (in picker)'],
  ];
  const hidden = [['r', 'host-safe lab'], ['v', 'verifier only'], ['p', 'partial attach'], ['o', 'observe'], ['i', 'incident drill']];
  return (
    <div onClick={onClose} style={{ position: 'absolute', inset: 0, background: 'rgba(8,7,5,.66)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 40 }}>
      <div onClick={e => e.stopPropagation()} style={{ width: 560, border: `1px solid ${t.border}`, borderRadius: 4, background: t.surface, padding: 0 }}>
        <div style={{ padding: '8px 14px', borderBottom: `1px solid ${t.faint}`, display: 'flex', alignItems: 'center' }}>
          <span style={{ color: t.accent, fontWeight: 700, letterSpacing: 1 }}>KEY MAP</span>
          <span style={{ marginLeft: 'auto', color: t.muted, fontSize: 11 }}>fail-closed operator · ? or esc to close</span>
        </div>
        <div style={{ padding: 14, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '4px 20px' }}>
          {keys.map(([k, v]) => (
            <div key={k} style={{ display: 'grid', gridTemplateColumns: '40px 1fr', gap: 9, alignItems: 'baseline', fontSize: 12 }}>
              <span style={{ background: t.bgInv || t.surfaceAlt, color: t.accent, border: `1px solid ${t.border}`, borderRadius: 2, padding: '0 6px', textAlign: 'center', fontWeight: 700 }}>{k}</span>
              <span style={{ color: t.fg }}>{v}</span>
            </div>
          ))}
        </div>
        <div style={{ padding: '8px 14px', borderTop: `1px solid ${t.faint}` }}>
          <div style={{ color: t.muted, fontSize: 10.5, letterSpacing: 1, marginBottom: 5 }}>HIDDEN QUEUE KEYS</div>
          <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap' }}>
            {hidden.map(([k, v]) => (
              <span key={k} style={{ fontSize: 11.5, color: t.muted }}><span style={{ color: t.warning }}>{k}</span> {v}</span>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

// ── Footer ────────────────────────────────────────────────────────────────────
function Footer({ t, run, onKey }) {
  const keys = [['m', 'live vm'], ['b', 'rollback'], ['s', 'stop'], ['h', 'home'], ['?', 'help'], ['w', 'theme'], ['q', 'quit']];
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 14, padding: '0 16px', height: 32, borderTop: `1px solid ${t.border}`, background: t.surfaceAlt, flex: '0 0 auto' }}>
      <Pill t={t} label="NORMAL" color={t.accent} />
      <div style={{ display: 'flex', gap: 12, alignItems: 'center', flexWrap: 'wrap' }}>
        {keys.map(([k, v]) => (
          <span key={k} className="v-clk" onClick={() => onKey(k)} style={{ display: 'inline-flex', gap: 6, alignItems: 'center', fontSize: 11.5 }}>
            <span style={{ color: t.accent, fontWeight: 700, border: `1px solid ${t.border}`, borderRadius: 3, minWidth: 16, height: 16, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 10.5, padding: '0 3px' }}>{k}</span>
            <span style={{ color: t.muted }}>{v}</span>
          </span>
        ))}
        <span style={{ color: t.accent }}>↵ select</span>
      </div>
      <span style={{ marginLeft: 'auto', color: t.muted, fontSize: 11 }}>host_mutation=<span style={{ color: t.success }}>false</span></span>
      <span style={{ color: t.border, opacity: 0.7 }}>│</span>
      <span style={{ color: t.danger, fontWeight: 700, fontSize: 11.5, letterSpacing: 1.2 }}>FAIL-CLOSED</span>
    </div>
  );
}

// ── Welcome / intro screen ────────────────────────────────────────────────────
function WelcomeScreen({ t, target, autoLaunch, onEnter }) {
  const cards = [
    { g: '◆', c: t.accent,  k: 'live attach', v: 'Boots a disposable microVM and registers a zigsched_minimal sched_ext scheduler inside the guest.' },
    { g: '▤', c: t.success, k: 'runtime telemetry', v: 'Per-vCPU sched_switch lanes, utilization, runqueue-latency histogram — observed, descriptive, no perf claim.' },
    { g: '⇉', c: t.warning, k: 'daemon event stream', v: 'Every lifecycle step arrives as a zig-scheduler/daemon-event/v1 record, filterable in real time.' },
    { g: '⊘', c: t.danger,  k: 'fail-closed', v: 'host_mutation=false on every event. load · attach · enable · mutate · apply are refused on the host.' },
  ];
  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minHeight: 0, background: t.bg, position: 'relative', overflow: 'hidden' }}>
      <div className="v-scan" style={{ position: 'absolute', inset: 0, background: `repeating-linear-gradient(0deg, ${t.faint}22 0 1px, transparent 1px 4px)`, pointerEvents: 'none' }} />
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '0 16px', height: 30, borderBottom: `1px solid ${t.border}`, background: t.surfaceAlt }}>
        <span style={{ color: t.accent, fontWeight: 700, fontSize: 13 }}>▚ zig-scheduler</span>
        <span style={{ color: t.border }}>│</span>
        <span style={{ color: t.muted, fontSize: 11.5 }}>local daemon · read-only · disposable VM lab</span>
        <span style={{ marginLeft: 'auto', color: t.muted, fontSize: 11 }}>v1 · sched_ext readiness</span>
      </div>

      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', alignItems: 'center', padding: '0 80px', position: 'relative', zIndex: 1 }}>
        <div style={{ width: '100%', maxWidth: 1000 }}>
          <pre style={{ color: t.accent, fontSize: 13, lineHeight: 1.25, margin: 0, textShadow: `0 0 18px ${t.accent}44` }}>{
`██████ ██  ███████      live microVM lab
   ██ ██ ██     ██      ────────────────────────────────
  ██  ██ ██  ███████     fail-closed Linux scheduler operator`
}</pre>

          <div style={{ color: t.fgBright, fontSize: 16, lineHeight: 1.55, marginTop: 22, maxWidth: 760 }}>
            A read-only operator surface for the <span style={{ color: t.accent }}>live VM</span> path. It attaches to a throwaway
            microVM, observes a <span style={{ color: t.accent }}>zigsched_minimal</span> sched_ext scheduler running inside the guest, and
            streams the lifecycle as evidence — <span style={{ color: t.fg }}>the host is never mutated</span>.
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginTop: 24 }}>
            {cards.map(cd => (
              <div key={cd.k} style={{ border: `1px solid ${t.faint}`, borderLeft: `2px solid ${cd.c}`, borderRadius: 3, padding: '11px 14px', background: t.surface }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 5 }}>
                  <span style={{ color: cd.c, fontSize: 14 }}>{cd.g}</span>
                  <span style={{ color: cd.c, fontSize: 12, fontWeight: 700, letterSpacing: 1, textTransform: 'uppercase' }}>{cd.k}</span>
                </div>
                <div style={{ color: t.muted, fontSize: 12, lineHeight: 1.5 }}>{cd.v}</div>
              </div>
            ))}
          </div>

          <div style={{ display: 'flex', alignItems: 'center', gap: 18, marginTop: 26 }}>
            <div style={{ color: t.success, fontSize: 13, fontFamily: MONO }}>
              $ zig build tui-live-vm<span className="v-blink" style={{ color: t.accent }}> ▌</span>
            </div>
            <span style={{ color: t.muted, fontSize: 12, marginLeft: 'auto' }}>target · {target.release} · {target.arch}</span>
            <button onClick={onEnter} className="v-clk" style={{
              background: t.accent, color: t.bg, border: 'none', borderRadius: 3, padding: '9px 22px',
              fontFamily: MONO, fontWeight: 700, fontSize: 13.5, letterSpacing: 0.5, cursor: 'pointer', boxShadow: `0 0 22px ${t.accent}55`,
            }}>{autoLaunch ? 'enter ▸ launch live run' : 'enter ▸ attach picker'}</button>
          </div>
        </div>
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '0 16px', height: 28, borderTop: `1px solid ${t.border}`, background: t.surfaceAlt }}>
        <span style={{ color: t.muted, fontSize: 11.5 }}>press <span style={{ color: t.accent, fontWeight: 700 }}>⏎</span> or <span style={{ color: t.accent, fontWeight: 700 }}>m</span> to continue</span>
        <span style={{ color: t.border }}>│</span>
        <span style={{ color: t.muted, fontSize: 11.5 }}>? key map · w theme</span>
        <span style={{ marginLeft: 'auto', color: t.danger, fontWeight: 700, fontSize: 11.5, letterSpacing: 1 }}>FAIL-CLOSED</span>
      </div>
    </div>
  );
}

// ── Root app ──────────────────────────────────────────────────────────────────
function App() {
  const [tw, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const t = THEMES[tw.theme] || THEMES.black;
  const [entered, setEntered] = uS(false);
  const enteredRef = uR(false); enteredRef.current = entered;
  const targetIdx = Math.max(0, TARGETS.findIndex(x => x.id === tw.target));
  const [sel, setSel] = uS(targetIdx < 0 ? 0 : targetIdx);
  const [help, setHelp] = uS(false);
  const [filter, setFilter] = uS('all');
  const [daemonMs, setDaemonMs] = uS(2.1);
  const [bridgeStatus, setBridgeStatus] = uS({ connected: false, mode: 'design-simulation' });

  const cfg = useCfg(tw, sel);
  const [run, setRun] = uS(() => freshRun(cfg));
  const runRef = uR(run); runRef.current = run;
  const cfgRef = uR(cfg); cfgRef.current = cfg;
  const bridgeRef = uR(null);

  // Optional local browser bridge: when served by `zig build live-vm-web`,
  // daemon-event/v1 rows are consumed incrementally and folded into the same
  // authoritative visual model. If the bridge is absent, the design simulation
  // remains fully interactive for review.
  uE(() => {
    const br = window.ZigSchedulerLiveBridge;
    if (!br) return;
    bridgeRef.current = br;
    br.status().then(st => setBridgeStatus({ ...st, connected: !!st.schema })).catch(() => {});
    return br.subscribe(
      (event) => setRun(r => ({ ...ingestDaemonEvent(r, event, cfgRef.current) })),
      () => setRun(r => ({ ...r, incident: r.incident === 'none' ? 'lost stream · browser bridge' : r.incident, notice: 'INCIDENT lost stream · browser bridge' }))
    );
  }, []);

  const requestBridgeAction = uCb((kind) => {
    const br = bridgeRef.current;
    if (!br) return;
    const call = kind === 'rollback' ? br.rollback.bind(br) : kind === 'stop' ? br.stop.bind(br) : br.run.bind(br);
    call().catch(err => {
      if (err && err.event) setRun(r => ({ ...ingestDaemonEvent(r, err.event, cfgRef.current) }));
      else setRun(r => ({ ...r, notice: `bridge ${kind} unavailable · design simulation continues` }));
    });
  }, []);

  // rebuild run when structural tweaks change (vcpus / density / target while idle)
  uE(() => {
    setRun(r => {
      if (r.phase === 'idle' || r.phase === 'refused' || r.phase === 'done' || r.phase === 'stopped') return freshRun(cfgRef.current);
      return r;
    });
  }, [tw.vcpus, tw.density, tw.target]);

  // launch run only after the operator enters from the welcome screen
  const launched = uR(false);
  const enterApp = uCb(() => {
    setEntered(true);
    if (tw.autoLaunch && !launched.current) {
      launched.current = true;
      setTimeout(() => { setRun(r => cmdArm(r, cfgRef.current)); requestBridgeAction('run'); }, 450);
    }
  }, [tw.autoLaunch, requestBridgeAction]);

  // run loop
  uE(() => {
    const iv = setInterval(() => {
      setRun(r => {
        if (r.phase === 'idle' || r.phase === 'refused' || r.phase === 'done' || r.phase === 'stopped') return r;
        step(r, 0.09 * (cfgRef.current.speed || 1), cfgRef.current);
        return { ...r };
      });
    }, 90);
    return () => clearInterval(iv);
  }, []);

  // jitter the daemon rtt for liveness
  uE(() => {
    const iv = setInterval(() => setDaemonMs(1.4 + Math.random() * 1.8), 1100);
    return () => clearInterval(iv);
  }, []);

  const doKey = uCb((k) => {
    if (!enteredRef.current) {
      if (k === 'Enter' || k === 'm' || k === ' ') enterApp();
      else if (k === 'w') setTweak('theme', nextTheme(tw.theme));
      else if (k === '?') setHelp(h => !h);
      else if (k === 'Escape') setHelp(false);
      return;
    }
    if (k === '?') { setHelp(h => !h); return; }
    if (k === 'Escape') { setHelp(false); return; }
    if (help && k !== 'q') { setHelp(false); return; }
    if (k === 'm') { setRun(r => cmdArm(r, cfgRef.current)); requestBridgeAction('run'); return; }
    if (k === 'b') { const confirm = runRef.current.confirm === 'rollback'; setRun(r => { cmdRollback(r); return { ...r }; }); if (confirm) requestBridgeAction('rollback'); return; }
    if (k === 's') { const confirm = runRef.current.confirm === 'stop'; setRun(r => { cmdStop(r); return { ...r }; }); if (confirm) requestBridgeAction('stop'); return; }
    if (k === 'h') { setRun(() => freshRun(cfgRef.current)); launched.current = true; return; }
    if (k === 'w') { setTweak('theme', nextTheme(tw.theme)); return; }
    if (k === 'q') { setRun(r => ({ ...r, notice: 'QUIT requested — session is read-only, host unchanged' })); return; }
    if (/^[1-9]$/.test(k) && runRef.current.phase === 'idle') {
      const i = parseInt(k, 10) - 1; if (i < TARGETS.length) { setSel(i); setTweak('target', TARGETS[i].id); }
      return;
    }
    if (k === 'Enter' && runRef.current.phase === 'idle') { setRun(r => cmdArm(r, cfgRef.current)); }
  }, [help, tw.theme, enterApp, requestBridgeAction]);

  uE(() => {
    const h = (e) => {
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
      if (['m', 'b', 's', 'h', 'w', 'q', '?', 'Escape', 'Enter', ' '].includes(k) || /^[1-9]$/.test(k)) { e.preventDefault(); doKey(k); }
    };
    window.addEventListener('keydown', h);
    return () => window.removeEventListener('keydown', h);
  }, [doKey]);

  const onArm = () => { setRun(r => cmdArm(r, cfgRef.current)); requestBridgeAction('run'); };
  const idle = run.phase === 'idle';

  // ── fixed TUI canvas, scaled to fit ──
  const W = 1480, H = 904;
  const stageRef = uR(null);
  const [scale, setScale] = uS(1);
  uE(() => {
    const fit = () => {
      const vw = window.innerWidth, vh = window.innerHeight;
      setScale(Math.min(vw / W, vh / H));
    };
    fit(); window.addEventListener('resize', fit);
    return () => window.removeEventListener('resize', fit);
  }, []);

  return (
    <div style={{ position: 'fixed', inset: 0, background: t.bg, overflow: 'hidden' }}>
      <div className="vtui" style={{
        position: 'absolute', left: '50%', top: '50%',
        width: W, height: H, transform: `translate(-50%, -50%) scale(${scale})`, transformOrigin: 'center center',
        background: t.bg, color: t.fg, display: 'flex', flexDirection: 'column',
        border: `1px solid ${t.border}`, borderRadius: 5, overflow: 'hidden', position: 'relative',
        boxShadow: '0 24px 80px rgba(0,0,0,.55)',
      }}>
        {!entered ? (
          <WelcomeScreen t={t} target={cfg.target} autoLaunch={tw.autoLaunch} onEnter={enterApp} />
        ) : (
        <React.Fragment>
        <HeaderBar t={t} run={run} daemonMs={daemonMs} theme={t.name} bridgeStatus={bridgeStatus} />
        <ModeStrip t={t} run={run} />

        {idle ? (
          <AttachPicker t={t} targets={TARGETS} selected={sel} setSelected={(i) => { setSel(i); setTweak('target', TARGETS[i].id); }} onArm={onArm} refusal={tw.refusal} />
        ) : (
          <div style={{ flex: 1, display: 'grid', gridTemplateColumns: '358px minmax(0,1fr) 398px', gap: 12, padding: 12, minHeight: 0 }}>
            {/* LEFT */}
            <div style={{ display: 'grid', gridTemplateRows: 'auto 1fr auto', gap: 12, minHeight: 0, minWidth: 0 }}>
              <IncidentPane t={t} run={run} />
              <PipelinePane t={t} run={run} />
              <GateLedgerPane t={t} run={run} />
              <AlertStrip t={t} run={run} />
            </div>
            {/* CENTER */}
            <div style={{ display: 'grid', gridTemplateRows: '1fr auto', gap: 12, minHeight: 0, minWidth: 0 }}>
              <VcpuPane t={t} run={run} />
              <LatencyPane t={t} run={run} />
            </div>
            {/* RIGHT */}
            <div style={{ display: 'grid', minHeight: 0, minWidth: 0 }}>
            <FirehosePane t={t} run={run} filter={filter} setFilter={setFilter} />
            </div>
          </div>
        )}

        <Footer t={t} run={run} onKey={doKey} />
        {help && <HelpOverlay t={t} onClose={() => setHelp(false)} />}
        </React.Fragment>
        )}

        <TweaksPanel title="Tweaks">
          <TweakSection label="Surface" />
          <TweakSelect label="Theme" value={tw.theme} options={['black', 'cool', 'paper', 'mocha', 'latte']} onChange={v => setTweak('theme', v)} />
          <TweakSection label="Live stream" />
          <TweakToggle label="Auto-launch run" value={tw.autoLaunch} onChange={v => setTweak('autoLaunch', v)} />
          <TweakSlider label="Stream speed" value={tw.speed} min={0.25} max={3} step={0.25} unit="×" onChange={v => setTweak('speed', v)} />
          <TweakRadio label="vCPUs" value={String(tw.vcpus)} options={['2', '4', '6']} onChange={v => setTweak('vcpus', parseInt(v, 10))} />
          <TweakRadio label="Lane density" value={tw.density} options={['compact', 'standard', 'wide']} onChange={v => setTweak('density', v)} />
          <TweakSection label="Target & safety" />
          <TweakSelect label="Attach target" value={tw.target} options={TARGETS.map(x => x.id)} onChange={v => { setTweak('target', v); setSel(Math.max(0, TARGETS.findIndex(x => x.id === v))); }} />
          <TweakSelect label="Force fail-closed" value={tw.refusal} options={['none', 'qemu_not_found', 'kvm_unavailable', 'nix_busybox', 'config_invalid', 'verifier_reject', 'lost_stream', 'timeout', 'rollback_failed', 'cleanup_residue', 'stale_id', 'duplicate_id']} onChange={v => setTweak('refusal', v)} />
          <TweakButton label="Relaunch run" onClick={onArm} />
        </TweaksPanel>
      </div>
    </div>
  );
}

function useCfg(tw, sel) {
  return React.useMemo(() => {
    const density = { compact: 44, standard: 56, wide: 72 }[tw.density] || 56;
    return {
      speed: tw.speed || 1,
      vcpus: tw.vcpus || 4,
      laneCols: density + 8,
      cells: density,
      target: TARGETS[sel] || TARGETS[0],
      refusal: tw.refusal || 'none',
      seed: 7 + sel * 3 + (tw.vcpus || 4),
    };
  }, [tw.speed, tw.vcpus, tw.density, tw.refusal, sel]);
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
