// live-panes.jsx — TUI pane primitives shared across the live VM lab surface.
const { useState, useEffect, useRef, useMemo } = React;

// A bordered operator pane. Title rides a divided header; content area flexes.
function Pane({ t, title, sub, accent, right, flush, style, contentStyle, children }) {
  const col = accent || t.accent;
  return (
    <div className="vtui" style={{
      position: 'relative', border: `1px solid ${t.border}`, borderRadius: 4,
      background: t.surface, display: 'flex', flexDirection: 'column', minHeight: 0, overflow: 'hidden',
      ...style,
    }}>
      <div style={{
        display: 'flex', alignItems: 'center', gap: 9, padding: '0 13px',
        height: 27, borderBottom: `1px solid ${t.faint}`, flex: '0 0 auto',
      }}>
        <span style={{ color: col, fontWeight: 700, fontSize: 11, letterSpacing: 1.4, textTransform: 'uppercase' }}>{title}</span>
        {sub && <span style={{ color: t.muted, fontSize: 10.5, letterSpacing: 0.2 }}>{sub}</span>}
        {right != null && <span style={{ marginLeft: 'auto', color: t.muted, fontSize: 10.5, fontVariantNumeric: 'tabular-nums' }}>{right}</span>}
      </div>
      <div style={{ padding: flush ? 0 : '11px 13px', minHeight: 0, flex: '1 1 auto', display: 'flex', flexDirection: 'column', ...contentStyle }}>
        {children}
      </div>
    </div>
  );
}

// Three-column evidence row (label · value · note) — mirrors layout.zig row().
function KV({ t, k, v, note, vColor, kw, onClick, active }) {
  return (
    <div className={'v-row' + (onClick ? ' v-clk' : '')} onClick={onClick} style={{
      display: 'grid', gridTemplateColumns: `${kw || 116}px minmax(0,1fr) auto`, gap: 12, alignItems: 'baseline',
      fontSize: 12.5, lineHeight: '21px', padding: '0 4px', borderRadius: 2,
      background: active ? t.selBg : 'transparent',
    }}>
      <span style={{ color: t.muted, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{k}</span>
      <span style={{ color: vColor || t.fgBright, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', fontVariantNumeric: 'tabular-nums' }}>{v}</span>
      <span style={{ color: t.muted, fontSize: 10.5, whiteSpace: 'nowrap' }}>{note}</span>
    </div>
  );
}

function SectionLine({ t, left, right, style }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 9, margin: '11px 0 6px', ...style }}>
      <span style={{ color: t.muted, fontSize: 10, fontWeight: 700, letterSpacing: 1.8, textTransform: 'uppercase' }}>{left}</span>
      <span style={{ flex: 1, height: 1, background: t.faint }} />
      {right && <span style={{ color: t.muted, fontSize: 10, letterSpacing: 0.6, fontVariantNumeric: 'tabular-nums' }}>{right}</span>}
    </div>
  );
}

// status pill
function Pill({ t, label, color, dim, solid }) {
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 5, padding: '2px 8px', borderRadius: 3,
      border: `1px solid ${color}`, color: solid ? t.bg : color, background: solid ? color : 'transparent',
      fontSize: 10, fontWeight: 700, letterSpacing: 0.8, lineHeight: 1.2,
      whiteSpace: 'nowrap', opacity: dim ? 0.5 : 1,
    }}>{label}</span>
  );
}

const LANE_COLORS = { rt: 'accent', load: 'danger', svc: 'success', sys: 'warning', obs: 'fgBright' };

// vCPU lane strip — scrolling sched_switch cells; fills the height it is given.
function LaneStrip({ t, lane, tasks, cols, active }) {
  const colorFor = (cell) => (cell === '·') ? null : t[LANE_COLORS[(tasks[cell] || {}).cls]] || t.fg;
  const cells = lane.cells.slice(-cols);
  const cur = (active && lane.last != null && lane.last !== '·') ? tasks[lane.last] : null;
  return (
    <div style={{ display: 'flex', alignItems: 'stretch', gap: 11, flex: 1, minHeight: 20 }}>
      <div style={{ width: 58, flex: '0 0 auto', display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
        <span style={{ color: t.fgBright, fontSize: 11.5, fontWeight: 600, lineHeight: 1.2 }}>cpu{lane.id}</span>
        <span style={{ color: cur ? t[LANE_COLORS[cur.cls]] || t.muted : t.muted, fontSize: 9.5, lineHeight: 1.2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{cur ? cur.comm : 'idle'}</span>
      </div>
      <div style={{ display: 'flex', flex: 1, gap: 1, overflow: 'hidden', alignItems: 'stretch', minHeight: 0 }}>
        {cells.map((c, i) => {
          const col = colorFor(c);
          const isEdge = active && i === cells.length - 1;
          return (
            <span key={i} title={c === '·' ? 'idle' : (tasks[c] && tasks[c].comm)} style={{
              flex: 1, minWidth: 0, alignSelf: 'stretch',
              background: col || 'transparent',
              borderBottom: col ? 'none' : `1px solid ${t.faint}`,
              opacity: col ? (0.5 + 0.5 * (i / cells.length)) : 1,
              boxShadow: isEdge && col ? `0 0 8px ${col}` : 'none',
            }} />
          );
        })}
      </div>
      <div style={{ width: 54, flex: '0 0 auto', textAlign: 'right', display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
        <span style={{ color: t.fg, fontSize: 11, fontVariantNumeric: 'tabular-nums', lineHeight: 1.2 }}>{(lane.onCpuUs / 1000).toFixed(0)}ms</span>
        <span style={{ color: t.muted, fontSize: 9.5, lineHeight: 1.2 }}>on-cpu</span>
      </div>
    </div>
  );
}

// tiny sparkline from a 0..1 buffer
function Sparkline({ t, data, color, h = 16 }) {
  const c = color || t.accent;
  const chars = data.map(v => spark(Math.max(0, Math.min(1, v)))).join('');
  return <span style={{ color: c, fontSize: h, lineHeight: `${h}px`, letterSpacing: -1, fontFamily: MONO }}>{chars}</span>;
}

// horizontal mini-bar
function Bar({ t, value, max, color, width, label }) {
  const pct = Math.max(0, Math.min(1, value / (max || 1)));
  const cells = width || 16;
  const filled = Math.round(pct * cells);
  return (
    <span style={{ fontFamily: MONO, fontSize: 12.5, letterSpacing: -0.5 }}>
      <span style={{ color: color || t.accent }}>{BLK.full.repeat(filled)}</span>
      <span style={{ color: t.faint }}>{BLK.l.repeat(cells - filled)}</span>
      {label && <span style={{ color: t.muted, marginLeft: 6, fontSize: 11 }}>{label}</span>}
    </span>
  );
}

Object.assign(window, { Pane, KV, SectionLine, Pill, LaneStrip, Sparkline, Bar, LANE_COLORS });
