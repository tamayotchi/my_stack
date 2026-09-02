# Tamayotchi Stack Agent Guide

Tamayotchi Stack is a development-time Igniter package. It configures and
updates target repositories; generated applications own their implementation.

Rules:

- Do not introduce a Tamayotchi runtime proxy around Phoenix, Oban, R2, Kamal,
  or other integrations.
- Keep one public package and one version. Feature modules are internal.
- Every patcher must be idempotent and preserve compatible user changes.
- Refuse unsafe overwrites and report actionable conflicts.
- Never write credentials into generated or source-controlled files.
- Keep interactive prompts paired with noninteractive flags.
- Run `mix precommit` in the root package and `installer/` after changes.
- Run a generated-project smoke test when changing `tamayotchi.new` or feature
  installation behavior.

The durable design is in `docs/definition.md`.
