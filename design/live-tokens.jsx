// live-tokens.jsx — design tokens for the zig-scheduler LIVE microVM lab operator TUI.
// Source of truth: DESIGN.md "Zig Scheduler Operator TUI Design System" + src/tui/render.zig AnsiPalette.
// xterm-256 anchors: surface 235, border 94 (amber-brown), text 245/240, accent 45 (cyan),
// warning 220, success 114, danger 205. Neutrals warmed slightly for the "warm dark, never pure black" rule.

const THEMES = {
  // Default operator theme — truly black. Pure-black surfaces, neutral text, WHITE line highlights.
  black: {
    name: 'black',
    bg:      '#000000',   // pure black — behind panes / letterbox
    surface: '#000000',   // truly black pane fill
    surfaceAlt:'#000000',
    fg:      '#8c8c8c',   // neutral primary operator text
    fgBright:'#d6d6d6',   // emphasized values (neutral light)
    muted:   '#585858',   // caveats / inactive
    faint:   '#1e1e1e',   // hairline fills (neutral)
    border:  '#d4d4d4',   // WHITE box frames + divider lines (was amber)
    borderDim:'#5a5a5a',
    accent:  '#34c8e8',   // cyan — header / live / selected
    warning: '#ffffff',   // WHITE — line highlight (pending / required / read-only / closed)
    success: '#86cf86',   // green — PASS / validated / complete
    danger:  '#f368ad',   // pink-magenta — incident / refusal / FAIL-CLOSED
    selBg:   '#141414',   // row selection (neutral)
  },
  // `w` toggles to cool dark (interaction.zig: "THEME cool dark").
  cool: {
    name: 'cool dark',
    bg:      '#0e1113',
    surface: '#1b2024',
    surfaceAlt:'#161b1f',
    fg:      '#8b9398',
    fgBright:'#c4ccd1',
    muted:   '#525a5f',
    faint:   '#2a3137',
    border:  '#3f6c7a',
    borderDim:'#2c4d57',
    accent:  '#34c8e8',
    warning: '#e8c24a',
    success: '#86cf86',
    danger:  '#f368ad',
    selBg:   '#222a2f',
  },
  // Bonus paper variant for daylight / presenters (DESIGN lists light as N/A; offered as a tweak).
  paper: {
    name: 'paper',
    bg:      '#cfc7b4',
    surface: '#e8e1d0',
    surfaceAlt:'#ded6c2',
    fg:      '#3a352c',
    fgBright:'#1c1813',
    muted:   '#857c69',
    faint:   '#c4bba6',
    border:  '#1c160c',   // near-black box frames + divider lines (was amber)
    borderDim:'#6b6453',
    accent:  '#1f7e93',
    warning: '#1a140a',   // near-black — line highlight (pending / required / read-only)
    success: '#3f7a3f',
    danger:  '#b03a76',
    selBg:   '#d8cfba',
  },
  // Catppuccin Mocha — soft pastel dark.
  mocha: {
    name: 'catppuccin mocha',
    bg:      '#11111b',   // crust — letterbox
    surface: '#1e1e2e',   // base — pane fill
    surfaceAlt:'#181825', // mantle — header/footer
    fg:      '#a6adc8',   // subtext0 — primary text
    fgBright:'#cdd6f4',   // text — emphasized values
    muted:   '#6c7086',   // overlay0 — caveats / inactive
    faint:   '#313244',   // surface0 — hairline fills
    border:  '#585b70',   // surface2 — box frames + divider lines
    borderDim:'#45475a',  // surface1
    accent:  '#cba6f7',   // mauve — header / live / selected
    warning: '#f9e2af',   // yellow — pending / required / read-only
    success: '#a6e3a1',   // green — PASS / validated / complete
    danger:  '#f38ba8',   // red — incident / refusal / FAIL-CLOSED
    selBg:   '#313244',   // surface0 — row selection
  },
  // Catppuccin Latte — soft pastel light.
  latte: {
    name: 'catppuccin latte',
    bg:      '#dce0e8',   // crust — letterbox
    surface: '#eff1f5',   // base — pane fill
    surfaceAlt:'#e6e9ef', // mantle — header/footer
    fg:      '#5c5f77',   // subtext1 — primary text
    fgBright:'#4c4f69',   // text — emphasized values
    muted:   '#8c8fa1',   // overlay1 — caveats / inactive
    faint:   '#bcc0cc',   // surface1 — hairline fills
    border:  '#9ca0b0',   // overlay0 — box frames + divider lines
    borderDim:'#acb0be',  // surface2
    accent:  '#8839ef',   // mauve — header / live / selected
    warning: '#df8e1d',   // yellow — pending / required / read-only
    success: '#40a02b',   // green — PASS / validated / complete
    danger:  '#d20f39',   // red — incident / refusal / FAIL-CLOSED
    selBg:   '#ccd0da',   // surface0 — row selection
  },
};

const MONO = '"JetBrains Mono", "Fira Code", "SF Mono", Menlo, Consolas, monospace';

// Semantic status → color key (mirrors render.zig semantic_tokens grouping).
function statusColor(t, status) {
  const s = String(status || '').toLowerCase();
  if (/(pass|completed|complete|ready|validated|clean|accepted|present|none after)/.test(s)) return t.success;
  if (/(refuse|refused|incident|unsafe|fail-closed|failed|reject|stale|danger)/.test(s)) return t.danger;
  if (/(pending|required|queued|read-only|closed|skip|withheld|not-started|missing|active|armed|partial)/.test(s)) return t.warning;
  if (/(live|stream|attach|observ|zigsched|cyan|accent)/.test(s)) return t.accent;
  return t.fg;
}

// Box-drawing — rounded corners per render.zig border tokens (╭ ╮ ╰ ╯), light interior, heavy frame option.
const BOX = {
  round: { tl:'╭', tr:'╮', bl:'╰', br:'╯', h:'─', v:'│', lT:'├', rT:'┤', tT:'┬', bT:'┴', x:'┼' },
  heavy: { tl:'┏', tr:'┓', bl:'┗', br:'┛', h:'━', v:'┃', lT:'┣', rT:'┫', tT:'┳', bT:'┻', x:'╋' },
  light: { tl:'┌', tr:'┐', bl:'└', br:'┘', h:'─', v:'│', lT:'├', rT:'┤', tT:'┬', bT:'┴', x:'┼' },
};

// Block shades for lanes / sparklines / progress.
const BLK = { full:'█', d:'▓', m:'▒', l:'░', up:'▀', lo:'▄', lft:'▌', rgt:'▐' };
const SPARK = ['▁','▂','▃','▄','▅','▆','▇','█'];
const BRAILLE_DOT = ['⠀','⠄','⠆','⠇','⠧','⠷','⠿'];

function pad(s, n, side = 'right', ch = ' ') {
  s = String(s);
  if (s.length >= n) return s.slice(0, n);
  const fill = ch.repeat(n - s.length);
  return side === 'left' ? fill + s : s + fill;
}
function spark(v01) {
  const i = Math.max(0, Math.min(SPARK.length - 1, Math.round(v01 * (SPARK.length - 1))));
  return SPARK[i];
}

// Inject base TUI css once.
if (typeof document !== 'undefined' && !document.getElementById('live-tui-styles')) {
  const link = document.createElement('link');
  link.rel = 'stylesheet';
  link.href = 'https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600;700&display=swap';
  document.head.appendChild(link);
  const s = document.createElement('style');
  s.id = 'live-tui-styles';
  s.textContent = `
    .vtui, .vtui * { box-sizing: border-box; font-family: ${MONO}; font-feature-settings: "zero","ss01"; }
    .vtui pre { margin: 0; font-family: inherit; }
    .vtui ::selection { background: rgba(52,200,232,.30); }
    .v-blink { animation: v-blink 1.05s steps(2,start) infinite; }
    @keyframes v-blink { to { opacity: 0; } }
    .v-cur { animation: v-blink 1.05s steps(2,start) infinite; }
    @keyframes v-flow { from { background-position: 0 0; } to { background-position: -200px 0; } }
    .v-scan { animation: v-scan 2.4s linear infinite; }
    @keyframes v-scan { 0%{opacity:.0} 50%{opacity:.6} 100%{opacity:0} }
    .v-fade-in { animation: v-fade-in .28s ease both; }
    @keyframes v-fade-in { from { opacity: 0; transform: translateY(2px); } to { opacity: 1; transform: none; } }
    .v-pulse { animation: v-pulse 1.4s ease-in-out infinite; }
    @keyframes v-pulse { 0%,100%{ opacity:.45 } 50%{ opacity:1 } }
    .v-row:hover { filter: brightness(1.12); }
    .v-clk { cursor: pointer; }
    ::-webkit-scrollbar { width: 8px; height: 8px; }
    ::-webkit-scrollbar-thumb { background: #5c4310; }
    ::-webkit-scrollbar-track { background: transparent; }
  `;
  document.head.appendChild(s);
}

Object.assign(window, { THEMES, MONO, BOX, BLK, SPARK, BRAILLE_DOT, statusColor, pad, spark });
