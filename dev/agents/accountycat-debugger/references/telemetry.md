# AccountyCat Telemetry Map

## Bundle Files

- `summary.json`: compact health summary for the exported session.
- `inspector_index_summary.json`: one row per focus episode or LLM interaction, with extracted fields and artifact paths.
- `current_state_redacted.json`: state summary without credentials.
- `activity.log`: concise human-readable breadcrumbs.
- `telemetry/events.jsonl`: raw append-only session events.
- `telemetry/artifacts/`: copied raw prompts, payloads, stdout/stderr, screenshots, thumbnails.
- `openrouter_health.json`: model/provider reliability snapshot when present.

## LLM Interactions

`llm_interaction` records represent one LLM call. Important fields:

- `interactionID`: stable id used by annotations and Inspector summary.
- `kind`: `chat`, `local_chat`, `chat_action`, `policy_memory`, `memory_consolidation`, `monitoring_text`, `monitoring_vision`, `safelist_appeal`.
- `parentInteractionID`: links staged actions back to the parent chat.
- `runtime`: `openrouter` or `llama_cpp`.
- `modelIdentifier`: requested/used model.
- `requestArtifacts`: system prompt, user prompt, payload.
- `responseArtifacts`: raw stdout/stderr.
- `parsedOutputJSON`: parsed domain object when the caller annotated the interaction.
- `extractedFields`: small kind-specific fields for quick triage.
- `failure`: infrastructure or parsing failure attached to the call.
- `isAnnotation`: true for append-only enrichment events; Inspector summary merges them by `interactionID`.

## Focus Decision Episodes

Focus decisions are built from multiple events:

- `observation`: frontmost app/title, heuristics, distraction state, whether evaluation was due.
- `evaluation_requested`: evaluation id, reason, prompt mode/version, active profile.
- `model_input_saved`: prompt payload, rendered prompt, optional screenshot.
- `model_output_received`: stdout/stderr, token usage, model/runtime options.
- `model_output_parsed`: assessment/action/confidence/reason tags.
- `policy_decided`: final intervention policy, block reason, final action, profile.
- `action_executed`: nudge/overlay/minimize execution.
- `monitoring_metric`: skips, vision retries, profile changes.
- `failure`: snapshot, provider, parsing, or config failures.

## Fast Signals

- Wrong skip: check `summary.skipReasons` and `monitoring_metric` events.
- Wrong screenshot behavior: check `model_input_saved.screenshot` and `summary.artifactHints`.
- Wrong decision: check `policy_decided.model`, `blockReason`, `finalAction`.
- Provider failure: check `recentFailures`, `llm_interaction.failure`, `openrouter_health.json`.
- Bad memory/rule update: check `policy_memory` or `memory_consolidation` interactions plus `current_state_redacted.json`.
