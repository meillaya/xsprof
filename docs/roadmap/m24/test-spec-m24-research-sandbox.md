# Test Spec — M24 research sandbox branch

## Status
Execution test spec reconstructed from approved consensus summary on 2026-04-22.

## Required verification
- stable vs unstable boundary is explicit
- experimental work is clearly labeled unstable
- promotion path from sandbox to supported milestone is documented
- stable docs do not present sandbox policies as defaults
- `zig build test --summary all` passes

## Minimum checks
- sandbox labeling audit
- boundary tests where applicable
- governance/docs audit
- regression pass
