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
