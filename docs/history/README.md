# History

This folder keeps **superseded** design and verification records for provenance.
Nothing here is a current product contract. Historical documents may describe
surfaces that no longer ship — the browser/WASM lane, the lab/experiment rail,
the microVM verification lane, macOS release artifacts, Homebrew/notarization
tooling, and committed evidence corpora were all removed. When a claim here
conflicts with the current docs, the current docs win.

## Contents

| File | What it records |
|---|---|
| [`roadmap.md`](roadmap.md) | The rewrite phase history (P0–P7, M0–M7, R1) and the productization milestones, with the status each phase had at the time. |
| [`parity.md`](parity.md) | Behavior retained from the archived C++ predecessor and the defects the Zig rewrite intentionally fixed. The C++ tree is reachable in `main` history at commit `44d7594` (no archive branch or tag exists in this repository). |
| [`audits/v0.3.0.md`](audits/v0.3.0.md) | 0.3.0 correctness/durability audit and remediation, with the then-current VM measurements. |
| [`audits/v0.4.0.md`](audits/v0.4.0.md) | 0.4.0 UI-first console audit: compact raw storage, native live capture, accessibility tree, CLI simplification. |
| [`audits/v0.5.0.md`](audits/v0.5.0.md) | 0.5.0 native-only removal audit (browser lane removed) and the KVM VM acceptance results for that release. |
| [`audits/live-feed-stall.md`](audits/live-feed-stall.md) | Postmortem for the bounded live-feed stop stall; the fix and its verification. |

## Policy

- Historical documents are frozen. Do not edit them to reflect new behavior;
  write current documentation under `docs/` and keep the release narrative in
  `CHANGELOG.md`.
- Measurement evidence is attached to GitHub releases, never committed to git
  (see `docs/maintaining.md`). Historical numbers here are therefore
  reproduced only from the text, not from committed logs.
- Commit hashes in these files refer to commits in this repository's history.
  The repository does not currently use tags; references are for `git show`
  use, not install paths.
