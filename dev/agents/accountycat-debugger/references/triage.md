# AccountyCat Runtime Triage

## OpenRouter Failed

1. Read `summary.json.recentFailures`.
2. Read `openrouter_health.json` for banned models, failure statuses, providers, retries, fallback successes.
3. Open the failing `llm_interaction` record in `inspector_index_summary.json`.
4. Read only that interaction's `rawStdout` and `rawStderr` artifacts.
5. Check whether backoff or fallback telemetry exists: `evaluation_skipped` with `api_failure`, `vision_retried`, retries in health stats.

Likely fixes: fallback model ordering, retry classification, provider error parsing, timeout, prompt/image size, missing API key handling.

## Bad Chat Reply

1. Find latest `chat` or `local_chat` in `summary.recentLLMInteractions`.
2. Inspect system prompt, user prompt, raw stdout, parsed output, extracted fields.
3. Verify `parentInteractionID` if a staged `chat_action` followed.
4. Compare expected memory/profile/rule changes with `current_state_redacted.json`.

Likely fixes: prompt instruction, output parsing, action resolver schema, chat context assembly, memory extraction trigger.

## Wrong Nudge or Missed Nudge

1. Find latest `focus_decision` episode in `inspector_index_summary.json`.
2. Check whether it skipped or evaluated. If skipped, inspect `summary.skipReasons` and `monitoring_metric.reason`.
3. If evaluated, inspect prompt payload, screenshot path, parsed model output, `policy_decided.blockReason`, and final action.
4. Verify recent action cooldowns in `current_state_redacted.json.recentActions`.
5. Check profile/rule scope and active profile.

Likely fixes: cadence gate, safelist rule matching, title-only heuristic, confidence threshold, distraction ladder, intervention cooldown.

## Screenshot Missing or Wrong

1. Check `model_input_saved.screenshot` and `artifactPaths.screenshot`.
2. Check `MonitoringConfiguration.screenshotCaptureMode`, `titleLengthForTextOnly`, and `periodicFullScreenInterval` in state.
3. Check skip/evaluation reason and vision retry events.
4. Inspect snapshot failures in `recentFailures`.

Likely fixes: screen recording permission, title-length gate, active-window capture, periodic fullscreen trigger, one-shot escalation path.

## Safelist Did Not Promote

1. Inspect `current_state_redacted.json.activePolicyRules` for existing allow rules.
2. Inspect `safelist_appeal` interactions and extracted fields.
3. Check `monitoring_metric` and `activity.log` for promotion denied/approved breadcrumbs.
4. Verify active profile id because promoted rules are profile-scoped.

Likely fixes: observation thresholds, distinct-day tracking, appeal prompt, rule scope validation, profile stamping.

## Profile or Memory Wrong

1. Inspect `chat`, `chat_action`, `policy_memory`, and `memory_consolidation` interactions in chronological order.
2. Verify `parentInteractionID` from chat to action.
3. Compare parsed output to `current_state_redacted.json.profiles`, `recentMemory`, and `activePolicyRules`.
4. For expiry issues, remember profile expiry happens on monitoring tick, not a timer.

Likely fixes: chat output parsing, policy operation application, profile LRU, tick-driven expiry, memory consolidation prompt.
