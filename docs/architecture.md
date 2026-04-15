# Architecture

AccountyCat has a deliberately small surface area.

- `AC/` contains the menu bar app, setup flow, UI, monitoring loop, and local chat.
- `BrainService` drives the observation loop, cooldowns, and action policy.
- `LLMService` runs the local model through `llama.cpp` and parses strict JSON output.
- `SnapshotService` reads the active app/window and captures screenshots when needed.
- `ExecutiveArm` handles visible interventions like nudges, overlays, and rescue-app launches.
- `TelemetryStore` writes local sessions and artifacts; `ACInspector/` is the companion tool for reviewing them.

The intended behavior is conservative: if the model is unsure, it does nothing. Missing a distraction is fine. Interrupting a flow state is not.

