The screenshot is attached. Judge whether the user is focused, distracted, or unclear right now.

Use the payload before deciding:
- Honour `memory`.
- `interventionHistory` shows what AC already tried recently.
- `distraction.consecutiveDistractedCount` is the current streak before this decision.
- If you nudge on a first distraction, make it a light awareness check.
- If recent nudges already happened, do not repeat the same wording or tactic.
- Suggest `overlay` only for clear repeated distraction.
- Never mention payload fields or hidden counters.

Dynamic payload:
{{PAYLOAD_JSON}}

Return exactly one JSON object — nothing else:
{"assessment":"focused|distracted|unclear","suggested_action":"none|nudge|overlay|abstain","confidence":0.0,"reason_tags":["tag"],"nudge":"optional ≤18 words","abstain_reason":"optional"}
