---
inclusion: auto
name: harness-spec-guide
description: How to write or refine a Kiro spec so the harness agent can execute it reliably. Use when creating a new spec, refining requirements, or turning a request into tasks.
---

# Writing a spec the harness can run (Spotify prompt lessons)

A spec is the agent's prompt: keep it large, static and version-controlled so it can be reused and improved.

## requirements.md must contain
- **Goal as an end state**, not a list of steps. Describe what the code looks like when done; let the agent choose the path.
- **Preconditions / when NOT to act**: the cases where the agent must stop and report instead of changing code (e.g. "if the module still targets minSdk < 26 and desugaring is off, stop").
- **Examples**: 2–3 before/after code snippets of the exact change. Examples shape the output more than prose.
- **Acceptance criteria in EARS form**: `WHEN <event> THE SYSTEM SHALL <response>` / `IF <condition> THEN THE SYSTEM SHALL ...`. Each criterion must map to a test or a command that can be run.
- **Out of scope**: what must not change.

## tasks.md
- One change per task. If two changes could each fail on their own, they are two tasks.
- Each task names the verification that proves it (`verify.sh --full`, a specific test).
- Keep tasks small enough to fit in one context window; cascading multi-file changes are the most common failure.

## Anti-patterns
- Too generic ("modernise this module") or too procedural (breaks on the first unexpected case).
- No verifiable end state ("make the code better").
- Mixing a migration with a refactor or a dependency bump.

After each run, read `retro.md` in the spec folder and fold what was missing back into the spec.
