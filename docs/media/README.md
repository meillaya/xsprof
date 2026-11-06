# Demo recording

`watch.gif` shows `xsprof watch` over a real four-vCPU perf capture
(`fixtures/real/scheduler-mix.ndjson`). The tape builds a temporary recorder
manifest around that fixture, so the capture stays repository-sized while the
viewer still reads a normal recorder state directory.

`watch.tape` is the VHS source. VHS 0.12.0 has a context bug that prevents
output; use the current main branch:

```sh
go install github.com/charmbracelet/vhs@main
vhs docs/media/watch.tape
```

The recording needs `ffmpeg` and `ttyd` on `PATH`.

## Native showcase media

The native GPU console evidence lives under [`design/media/`](../../design/media/):

- `xsprof-native-showcase.{mp4,gif}` — tour of Home, onboarding, GPU picker,
  Overview, Timeline replay, Advisor, Events, Recorder, Audit, Settings,
  accessibility focus, and export, plus the real VM capture;
- `xsprof-native-live-replay.{mp4,gif}` — REPLAY of the committed podman
  Linux-VM perf capture (`host_mutation=false`);
- canonical `*.provenance.json` files with input hashes, scene flags, frame
  hashes, and output hashes.

[`native-showcase.md`](native-showcase.md) documents the headless renderer,
determinism rules, and the provenance schema. Regenerate with
`tools/showcase.sh` (headless; no window or display capture) and gate with
`qa/showcase_smoke.sh`.
