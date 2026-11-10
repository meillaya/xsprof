# Maintaining xsprof

How to develop, gate, and release the repository. The product is the read-only
scheduler flight recorder; the viewer is optional and frozen.

## Dev environment

Requirements:

- **Zig 0.17.0** — pinned; use `./tools/zig` (bootstraps `tools/bootstrap.sh` on
  first use; needs `curl`/`xz` once). `XSPROF_ZIG=/path/to/zig` overrides it.
- **git** — required by gate scripts that reason over tracked files
  (`repo_size`, `docs_links`).
- **Nix (optional, recommended)** — `nix develop` provides the pinned toolchain
  plus the developer-only tools below.
- **Python 3 (dev-only)** — `design/validate.py`, `tools/gen_design_tokens.py`,
  `tools/gen_ui_spec.py`.
- **ImageMagick (dev-only)** — regenerating committed stills with
  `tools/screenshots.sh` (the `--check` mode needs no ImageMagick).
- **ffmpeg (dev-only)** — reserved for media generation; never a runtime
  dependency.
- **Xvfb + Mesa (dev/CI-only)** — hidden X11/GLX smoke; CI installs them. macOS
  runs the hidden AppKit smoke instead.

None of these are runtime dependencies of the shipped binary. The product is
Zig std + system frameworks only.

## Responsibility limit

One hand-written source file should hold one responsibility, with a **1,000-line**
ceiling enforced by `./tools/zig build lines`. Exemptions:

- `tests/**` and `*_test.zig` (test shards grow with cases);
- generated files whose first line contains `GENERATED` (for example
  `src/app/design/ui_spec.zig`) — regenerate the source of truth instead.

Files over the limit should be split by responsibility, not compressed.

## Gate tiers

| Command | What it runs | Needs |
|---|---|---|
| `./tools/zig build check` | fmt, 1,000-line limit, version sync, shell syntax, design contract, privacy/no-mutation/unsafe-verb scans, CLI parity, compact round-trip, a11y smoke, xsui package, unit/integration/fuzz tests, schema conformance | no display, no root, no network |
| `./tools/zig build check-ci` | `check` + platform smokes (Xvfb/native live) + screenshots + re-render check + repo size + docs links + perf floor, with `XSPROF_REQUIRE_TOOLS=1` (a missing tool fails, never silently skips) | Linux (X11/Xvfb, python3, ffmpeg, ImageMagick); arm64 runs the same gate |
| `./tools/zig build check-vm` | root-only `qa/live_smoke.sh`, `qa/service_smoke.sh`, `qa/retention_bench.sh 600000 0 2G yes` | disposable KVM Linux VM with readable tracefs |

CI (`.github/workflows/zig-ci.yml`) runs `check-ci` on Linux x86_64 and
aarch64 runners and `check` on macOS. The release preflight runs `check-ci` and
`qa/version_sync.sh` before any artifact is built.

Useful individual steps: `test`, `fuzz`, `fmt-check`, `lines`, `design-check`,
`repo-size`, `docs-links`, `screenshots-check`, `cli-parity`, `cli-manifest`,
`perf-smoke`, `compact-roundtrip`, `a11y-smoke`, `xsui-package`, platform
smokes (`xvfb-smoke`, `native-live-smoke`), and the VM gates
(`live-smoke`, `service-smoke`, `retention-bench`). Never run privileged gates
on a production host.

## Repository size policy

A trust-first repository must stay cheap to clone, mirror, and review:

- **Tracked tree ≤ 12 MiB total**; **no tracked file > 2 MiB**, with one exact
  allowlist entry for the GPU glyph atlas
  (`lib/xsui/assets/fonts/chromium_text_atlas.bin`, ≤ 5 MiB, generated once from
  bundled fonts).
- **No committed evidence, media, or vendor corpora.** VM logs, benchmark
  output, release artifacts, full captures, videos, and vendored reference text
  live in release assets or CI artifacts, not git.
- **Fixtures are small deterministic prefixes.** Real captures are committed
  only as prefixes (the macOS-VM prefix is 12,000 lines; `scheduler-mix` and
  `vm-fragmented` are 4,000 lines each). The full macOS-VM capture is attached
  to the release; never commit it.
- `./tools/zig build repo-size` (part of `check-ci`) enforces the budgets at
  `HEAD`; build output and ignored files cannot change the result.

## Wire schema policy

- Twenty canonical schemas live in `schemas/xsprof/`; each has
  `$id = https://xsprof.dev/schemas/<basename>`, a 2020-12 `$schema`, a root
  object type, and `properties.schema.const = xsprof/<name>/v1`.
- The schema-conformance test root (`tests/schema.zig`, wired into
  `./tools/zig build check`) validates every schema-backed committed wire sample
  (golden JSON docs, recorder golden NDJSON, `fixtures/ui/healthy.ndjson`,
  `fixtures/real/*.ndjson`) line-by-line, journal entries against `event.v1`,
  checks the archived legacy daemon transcript for canonical framing, and
  structurally checks every schema document.
- Lab schemas were removed; do not reintroduce them. Keep Zig serializers,
  schemas, fixtures, and goldens in lockstep; a schema change is a wire change.

## Documentation policy

- Every relative markdown link must resolve (`./tools/zig build docs-links`,
  part of `check-ci`). Stale links and stale claims are bugs.
- Current truth lives in `README.md`, `AGENTS.md`, `DESIGN.md`, `docs/` and
  `CHANGELOG.md`. Superseded material goes to `docs/history/` (frozen).
- Committed stills are limited to
  `design/screenshots/native/{dark,light}/{home,overview}.png` plus their
  provenance; `./tools/zig build screenshots-check` verifies bytes/provenance,
  and `sh tools/screenshots.sh` regenerates them (offscreen CPU raster; never a
  window capture).
- Do not advertise removed surfaces (browser/WASM, lab, microVM lane, Homebrew/
  notarization/macOS artifacts, committed evidence).

## Release checklist (tag-first)

0. **One-time history diet, before the first tag only**: run
   `CONFIRM=1 sh tools/repo_diet.sh` from a clean checkout (requires
   `git-filter-repo`; creates a backup branch + bundle). It rewrites every commit
   id to drop `.zig-cache` and removed asset blobs. Never rewrite history after a
   tag exists; fix forward instead. Re-run `./tools/zig build check` afterward.
1. **Bump the version in all four sources** (`build.zig.zon`,
   `src/core/version.zig`, the top `CHANGELOG.md` heading, and the README version
   badge/artifacts). `qa/version_sync.sh` fails if they disagree.
2. **Run the gates**: `./tools/zig build check` and `check-ci` on Linux
   x86_64/aarch64, and `check` on macOS. Do not tag with a red or skipped gate.
3. **Run `./tools/zig build check-vm`** on a disposable KVM Linux VM (live,
   service, retention). Save the output.
4. **Commit the release notes** under a new `CHANGELOG.md` heading; review that
   `README.md` names the release version.
5. **Tag `vX.Y.Z` and push the tag.** Publishing happens only for a pushed tag
   equal to the manifest version; a tag-driven run is the only path to a
   release. Never rewrite history after a tag — fix forward.
6. **The release workflow** (`release.yml`) builds Linux tarballs, Debian
   packages, and AppImages for x86_64/aarch64, runs per-artifact checksums,
   creates SHA256SUMS, attests build provenance with Sigstore, and publishes.
   macOS artifacts and Homebrew/notarization tooling do not exist.
7. **Attach evidence to the release** (not git): the `check-vm` logs/results,
   the full macOS-VM capture (`macos-vm-sched.ndjson`, sha256
   `f658213f58939f69f5a887b1211da5bf6cbb7c728111dd4a2ecc93b3c74a39a5`), and any
   benchmark/measurement output referenced by docs.
8. **Verify the published release**: `sha256sum -c SHA256SUMS`,
   `gh attestation verify <file> -R meillaya/xsprof`, and a quick install
   (`version`, `help`, `doctor`) from at least the tarball.

## Zig pin upgrade runbook

The toolchain is a deliberate dependency; upgrade it as one reviewable change,
never opportunistically inside a feature PR.

1. Pick the target version and obtain the official tarball hashes for
   `x86_64-linux`, `aarch64-linux`, `aarch64-darwin` (and `x86_64-darwin` only
   if that host is re-added).
2. Edit `tools/bootstrap.sh` (`VERSION`, per-host `sum`). Mirror the version and
   hashes in `nix/zig.nix`; `nix flake check` fails if they drift.
3. Run `./tools/zig version` and remove the stale `.tools/zig-<old>` (never
   commit `.tools/`).
4. Fix compile/API breakage against the **pinned stdlib** (`./tools/zig env`
   → `lib_dir`), not by guessing. Update `docs/zig-0.17-api-usage.md` with any
   newly observed idiom differences.
5. Regenerate generated files as needed: `python3 design/validate.py`,
   design-token/UI-spec generators, glyph atlas (only if API/atlas changed),
   completions (generated at package time).
6. Run `./tools/zig build check`, `check-ci` (Linux x86_64 + aarch64, macOS
   `check`), and `check-vm`; confirm `nix flake check` still passes.
7. Commit toolchain + docs + any generated output together; keep the change
   isolated from product behavior so a bisect can attribute a regression.

## Incident feedback

We do not collect telemetry. The only demand/quality signal is explicit
feedback: the privacy-safe
[incident feedback form](../.github/ISSUE_TEMPLATE/incident-feedback.yml) and
release-asset download counts. When someone reports a real incident, prefer
asking for a redacted `summary.json` or incident bundle over asking for logs.
