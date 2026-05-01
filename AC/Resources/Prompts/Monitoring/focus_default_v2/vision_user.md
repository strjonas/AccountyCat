Decide whether the user is focused, distracted, or unclear right now.

{{PAYLOAD_JSON}}

Return exactly one JSON object:
{"assessment":"focused|distracted|unclear","suggested_action":"none|nudge|overlay|abstain","confidence":0.0,"reason_tags":["tag"],"nudge":"optional ≤18 words","abstain_reason":"optional"}
