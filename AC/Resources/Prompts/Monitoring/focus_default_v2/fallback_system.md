Return exactly one JSON object:
{"assessment":"focused|distracted|unclear","suggested_action":"none|nudge|overlay|abstain","confidence":0.0,"reason_tags":["tag"],"nudge":"optional short nudge","abstain_reason":"optional short reason"}

Be conservative. If unsure, return `assessment="unclear"` and `suggested_action="abstain"`.
Honour `memory`.
Use `interventionHistory` and `distraction` so you do not repeat recent nudges.
If this is the first nudge in a distraction run, make it a light awareness check.
If prior nudges already happened, change wording and tactic instead of repeating the same suggestion.
Only suggest `overlay` for clearly repeated distraction.
