# Zig Scheduler Operator TUI Design System

## 1. Atmosphere & Identity

A fail-closed terminal command center for Linux scheduler lab evidence. The signature is a warm dark operator dashboard: dense box-drawing panes, compact status bars, and semantic ANSI accents that make safety state readable without claiming production readiness.

## 2. Color

### Palette

| Role | Token | Light | Dark | Usage |
|------|-------|-------|------|-------|
| Surface/primary | `ansi.surface.primary` | N/A | `48;5;235` | Warm dark TUI background; never pure black |
| Surface/secondary | `ansi.surface.border` | N/A | `38;5;94` | Amber-brown box borders and dividers |
| Text/primary | `ansi.text.primary` | N/A | `38;5;245` | Main operator labels and values |
| Text/secondary | `ansi.text.muted` | N/A | `38;5;240` | Muted caveats and inactive affordances |
| Accent/primary | `ansi.accent.primary` | N/A | `38;5;45` | Header, selected flow, live stream accents |
| Status/warning | `ansi.status.warning` | N/A | `38;5;220` | Pending, required, skipped, closed, read-only |
| Status/success | `ansi.status.success` | N/A | `38;5;114` | PASS, validated, rollback complete, cleanup complete |
| Status/error | `ansi.status.danger` | N/A | `38;5;205` | Incident, refusal, unsafe-to-assume, failure |

### Rules

- Plain snapshots remain ANSI-free for deterministic test compatibility.
- Interactive/ANSI captures must include background, neutral text, and distinct accent/warning/success/danger classes.
- Semantic colors describe operator state only; do not introduce simulator workload labels.

## 3. Typography

### Scale

| Level | Size | Weight | Line Height | Tracking | Usage |
|-------|------|--------|-------------|----------|-------|
| Header | terminal cell | N/A | 1 row | N/A | Brand, screen title, mode |
| Section | terminal cell | N/A | 1 row | N/A | Pane/section labels |
| Body | terminal cell | N/A | 1 row | N/A | Operator evidence rows |
| Caption | terminal cell | N/A | 1 row | N/A | Footer keys and caveats |

### Font Stack

- Primary: terminal monospace selected by the operator.
- Mono: terminal monospace selected by the operator.
- Serif: none.

### Rules

- Use concise operator labels that fit 80-column fallbacks.
- Preserve box-drawing and glyph alignment by counting display cells, not bytes.

## 4. Spacing & Layout

### Base Unit

All TUI spacing derives from one terminal cell.

| Token | Value | Usage |
|-------|-------|-------|
| `cell.1` | 1 terminal cell | Borders, gutters, footer separators |
| `cell.2` | 2 terminal cells | Inner row padding |
| `row.1` | 1 terminal row | Header, row, divider, footer |

### Grid

- Max content width: caller-provided terminal width.
- Column system: three operator columns from `src/tui/layout.zig`.
- Breakpoints: narrow `<100`, standard `<140`, wide `>=140` columns.

### Rules

- Never overflow requested terminal width.
- Keep root/operator semantics only; no simulator workload terms.

## 5. Components

### Operator Frame

- **Structure**: top border, compact header, divider, dense evidence rows, divider, status/footer, bottom border.
- **Variants**: plain snapshot, interactive ANSI.
- **Spacing**: `cell.1`, `cell.2`, `row.1`.
- **States**: read-only snapshot, fixture warning, action status, fail-closed footer.
- **Accessibility**: semantic words remain visible without color.
- **Motion**: none.

### Semantic ANSI Tokenizer

- **Structure**: post-processes plain frames into ANSI frames so geometry remains deterministic.
- **Variants**: accent, warning, success, danger, neutral, border, surface.
- **Spacing**: no layout mutation.
- **States**: PASS/rollback/cleanup success, pending/required warning, incident/refusal danger, live/header accent.
- **Accessibility**: color supplements status text; it never replaces it.
- **Motion**: none.

## 6. Motion & Interaction

### Timing

| Type | Duration | Easing | Usage |
|------|----------|--------|-------|
| Micro | none | none | Key status changes are text/color only |
| Standard | none | none | Snapshot determinism |
| Emphasis | none | none | Not used |
| Scroll-driven | none | none | Not used |

### Rules

- No animation in deterministic snapshots.
- Interactive feedback uses text and semantic ANSI only.

## 7. Depth & Surface

### Strategy

Tonal-shift through ANSI surface/background plus muted amber borders.

- Primary surface: `48;5;235` warm dark.
- Borders/dividers: `38;5;94` muted amber-brown.
- Depth comes from compact panes, dividers, and semantic color contrast rather than shadows.
