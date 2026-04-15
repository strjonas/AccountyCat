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

## Default Model

The current default model identifier is:

`unsloth/gemma-4-E2B-it-GGUF:Q4_0`

## Prompt Assets

Bundled prompts live in:

- `AC/Resources/Prompts/ACPromptV1System.md`
- `AC/Resources/Prompts/ACPromptV1Fallback.md`

## Local Data

Runtime files, logs, state, screenshots, and telemetry are stored under `~/Library/Application Support/AC`.

