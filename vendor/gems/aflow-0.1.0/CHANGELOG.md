# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2026-04-25

### Added
- `Aflow::Flow` with sequence, parallel, conditional node types and builder DSL
- `Aflow::Step` abstract base class with per-step `.config` (retry, timeout, fallback, on_error)
- `Aflow::Context` — fully immutable state carrier with deep-merge via `#with`
- `Aflow::StepResult` — immutable value object with `.success`, `.error`, `.skip`, `.retry` factories
- `Aflow::Executor` — graph walker with retry loop, timeout, fallback, and halt/continue strategies
- `Aflow::Trace` — full event log per run (input snapshot, output snapshot, duration, logs, metrics)
- Deterministic replay via `replay_trace:` parameter on `Flow#run`
- Thread-safe parallel execution with conflict-aware output merging
- Zero runtime dependencies
