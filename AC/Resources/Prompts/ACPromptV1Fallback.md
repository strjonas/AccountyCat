Return exactly one JSON object:
{"assessment":"focused|distracted|unclear","suggested_action":"none|nudge|overlay|abstain","confidence":0.0,"reason_tags":["tag"],"nudge":"optional short nudge","abstain_reason":"optional short reason"}

Be conservative. If unsure, return `assessment="unclear"` and `suggested_action="abstain"`.

