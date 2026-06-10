# Regression Fixtures

This directory is reserved for minimized deterministic regression scenarios found by the generator/shrinker workflow.

Guidelines:
- keep fixtures in canonical object-style ZON so they remain runnable through `--scenario-file`
- prefer lowercase kebab-case filenames that describe the preserved failure
- keep curated teaching examples in `scenarios/basic/`
- keep wording simulator-local and evidence-based
