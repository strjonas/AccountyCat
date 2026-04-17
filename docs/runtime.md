# Runtime Notes

## Default Runtime

- New installs use `~/Library/Application Support/AC/runtime`
- Legacy installs at `~/accountycat` are still detected so existing setups do not break
- The runtime binary is expected at `llama.cpp/build/bin/llama-cli`

## Dependencies

The in-app installer expects:

- `git`
- `cmake`
- `ninja`

The installer clones `llama.cpp`, fetches commit `a279d0f0f4e746d1ef3429d8e9d02d2990b2daa7`, and builds that pinned revision instead of tracking GitHub HEAD.

## Default Model

The current default model identifier is:

`unsloth/gemma-4-E2B-it-GGUF:Q4_0`

## Prompt Assets

Bundled prompts live in:

- `AC/Resources/Prompts/Monitoring/focus_default_v2/vision_system.md`
- `AC/Resources/Prompts/Monitoring/focus_default_v2/vision_user.md`
- `AC/Resources/Prompts/Monitoring/focus_default_v2/fallback_system.md`
- `AC/Resources/Prompts/Monitoring/focus_default_v2/fallback_user.md`
- `AC/Resources/Prompts/Extraction/screen_state_v1/system.md`
- `AC/Resources/Prompts/Extraction/screen_state_v1/user_prompt.md`
- `AC/Resources/Prompts/Chat/companion_chat_v1.md`
- `AC/Resources/Prompts/Memory/extract_memory_v1.md`
- `AC/Resources/Prompts/Memory/compress_memory_v1.md`

## Local Data

Runtime files, logs, state, screenshots, and telemetry are stored under `~/Library/Application Support/AC`.
