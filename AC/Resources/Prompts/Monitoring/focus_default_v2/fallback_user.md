The screenshot is attached. Judge whether the user is focused, distracted, or unclear right now.

Read the payload carefully. Honour `memory`. Use `interventionHistory` and `distraction` so you do not repeat recent nudges.
First distraction in a run: keep the nudge a light awareness check. Repeated: change wording and tactic.
Only suggest `overlay` for clearly repeated distraction.

Dynamic payload:
{{PAYLOAD_JSON}}

Return exactly one JSON object — nothing else:
{"assessment":"focused|distracted|unclear","suggested_action":"none|nudge|overlay|abstain","confidence":0.0,"reason_tags":["tag"],"nudge":"optional","abstain_reason":"optional"}
