# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Environment

```bash
source venv/bin/activate  # ALWAYS activate before running Python
uv pip install -e ".[all,dev]"  # First-time setup (requires uv)
```

## Commands

```bash
# Run tests
python -m pytest tests/ -q                         # Full suite (~3000 tests)
python -m pytest tests/ -n auto                    # Parallel (matches CI)
python -m pytest tests/gateway/ -q                 # Subset
python -m pytest tests/test_model_tools.py::TestFoo::test_bar -v  # Single test

# Run the agent
hermes                    # Interactive CLI
hermes gateway            # Messaging platform bridge
```

Always run the full suite before pushing changes. Integration tests (`tests/integration/`, `tests/e2e/`) require external API keys and are skipped in CI.

There is no linter or formatter configured in CI — no ruff, black, flake8, or mypy. Follow PEP 8 with practical exceptions (no strict line length enforcement).

## Architecture

**Hermes Agent** is a multi-platform AI agent framework supporting 200+ models. Core components:

### File Dependency Chain

```
tools/registry.py  (no deps — base, imported by all tool files)
       ↑
tools/*.py  (each calls registry.register() at import time)
       ↑
model_tools.py  (imports tools/registry, triggers _discover_tools())
       ↑
run_agent.py, cli.py, batch_runner.py, environments/
```

### Key Files

| File | Purpose |
|------|---------|
| `run_agent.py` | `AIAgent` class — synchronous conversation loop with tool calling |
| `cli.py` | `HermesCLI` — Rich/prompt_toolkit TUI, slash command dispatch |
| `model_tools.py` | Tool orchestration, `_discover_tools()`, `handle_function_call()` |
| `toolsets.py` | Toolset definitions, `_HERMES_CORE_TOOLS` |
| `hermes_state.py` | `SessionDB` — SQLite + FTS5 session storage |
| `hermes_cli/commands.py` | Central `COMMAND_REGISTRY` (all slash commands) |
| `hermes_cli/config.py` | `DEFAULT_CONFIG`, `OPTIONAL_ENV_VARS`, config migration |
| `hermes_constants.py` | Zero-dependency module: `get_hermes_home()`, `display_hermes_home()` |
| `agent/prompt_builder.py` | System prompt assembly |
| `agent/skill_commands.py` | Skill slash command dispatch (shared CLI/gateway) |
| `gateway/run.py` | Messaging platform main loop |
| `gateway/platforms/` | 26+ platform adapters (Telegram, Discord, Slack, Matrix, …) |

### Skill vs Tool Decision

Most new capabilities should be **skills** (instructions + shell commands + existing tools), not tools. Make it a tool only when it requires: custom Python integration with API key management, precise execution every time (not LLM-interpreted), or binary data/streaming/real-time events. Bundled skills go in `skills/`; official-but-niche ones go in `optional-skills/`.

### Tool System

Tools are registered at import time via `registry.register()`. Adding a tool requires changes to **3 files**:
1. Create `tools/your_tool.py` with `registry.register(name=, toolset=, schema=, handler=, check_fn=)`
2. Add import in `model_tools.py` `_discover_tools()` list
3. Add to `toolsets.py` (`_HERMES_CORE_TOOLS` or a new toolset)

All tool handlers **must return a JSON string**.

### Slash Command System

All slash commands are defined in `COMMAND_REGISTRY` (`hermes_cli/commands.py`). Adding a command:
1. Add `CommandDef` to `COMMAND_REGISTRY`
2. Add handler in `HermesCLI.process_command()` in `cli.py`
3. Optionally add gateway handler in `gateway/run.py`

Adding an alias only requires updating the `aliases` tuple — dispatch, help, Telegram menu, Slack map, and autocomplete all update automatically.

### Configuration

- User config: `~/.hermes/config.yaml` (settings), `~/.hermes/.env` (API keys)
- To add a config option: add to `DEFAULT_CONFIG` in `hermes_cli/config.py` and bump `_config_version`
- To add an env var: add to `OPTIONAL_ENV_VARS` in `hermes_cli/config.py`
- Two separate config loaders: `load_cli_config()` (CLI) and `load_config()` (hermes_cli subcommands)

## Critical Policies

### Prompt Caching Must Not Break
Never alter past context, toolsets, memories, or system prompts mid-conversation. Cache-breaking forces dramatically higher costs. The only valid context alteration is during context compression (`agent/context_compressor.py`).

### Profile-Safe Code (Multi-Instance)
Always use `get_hermes_home()` from `hermes_constants` for filesystem paths. Never hardcode `~/.hermes` or `Path.home() / ".hermes"` — it breaks profile isolation. Use `display_hermes_home()` in user-facing messages.

```python
# GOOD
from hermes_constants import get_hermes_home
config_path = get_hermes_home() / "config.yaml"

# BAD — breaks profiles
config_path = Path.home() / ".hermes" / "config.yaml"
```

### Testing Rules
- Tests must never write to `~/.hermes/` — the `_isolate_hermes_home` autouse fixture in `tests/conftest.py` redirects `HERMES_HOME` to a tmpdir
- Tests that mock `Path.home()` must also set `HERMES_HOME` env var (see `tests/hermes_cli/test_profiles.py` for the pattern)

### Working Directory

- **CLI**: Uses current directory (`os.getcwd()`)
- **Gateway**: Uses `MESSAGING_CWD` env var (default: user home directory)

## Known Pitfalls

- **Do not use `simple_term_menu`** for interactive menus — rendering bugs in tmux/iTerm2. Use `curses` instead (see `hermes_cli/tools_config.py`)
- **Do not use `\033[K`** (ANSI erase-to-EOL) in spinner/display code — leaks as `?[K` under prompt_toolkit. Use space-padding instead
- **`_last_resolved_tool_names` is a process-global** in `model_tools.py` — may be temporarily stale during subagent execution in `delegate_tool.py`
- **Do not hardcode cross-tool references in schema descriptions** — other toolsets may be disabled; add cross-references dynamically in `get_tool_definitions()` in `model_tools.py`
- **Profile operations are HOME-anchored**, not HERMES_HOME-anchored: `_get_profiles_root()` uses `Path.home() / ".hermes" / "profiles"` intentionally
