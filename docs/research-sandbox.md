# research sandbox

the simulator is the optional research sandbox branch for experimental policies and
experiments.

## Purpose

Allow fast policy experimentation without destabilizing the supported simulator
teaching spine.

The sandbox is intentionally **unstable**:
- experimental policies are not supported defaults
- they are not part of the public SDK stable subset
- they are not part of the packaged teaching path
- they must not silently widen stable contracts or README quick-start claims

## Current sandbox namespace

- `src/policies/experimental/`
- `src/policies/experimental/root.zig`

Current bounded example experimental policy:
- `lottery` — deterministic weight-biased chooser for sandbox experiments only

## Stable vs unstable rule

Supported mainline policies remain the documented set under `src/policies/` and
its existing built-in descriptors.

Experimental policies:
- stay outside the built-in stable policy descriptor list
- must carry explicit unstable labeling
- must not be presented as defaults in README or courseware

## Promotion path

An experimental policy may be promoted only when all of the following happen:
1. the sandbox experiment is documented clearly enough to explain its purpose
2. dedicated tests prove its intended semantics
3. a workstream/ADR explicitly approves promotion into the supported surface
4. stable docs/tests are updated to include the new supported policy intentionally

Without those steps, the policy remains experimental-only.

## Non-goals

the simulator does not imply:
- browser/WASM work
- service or production scope
- live observability capture
- automatic promotion into the stable teaching path
- public SDK stabilization of experimental policy internals
