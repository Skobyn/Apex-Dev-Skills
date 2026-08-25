# apex-app-harness

Plan, implement, review, and test code changes

## Behavioral rules

- Use the harness's MCP tools (`mcp__apex-app-harness__*`) for orchestration
- Memory and routing are handled by the kernel — you don't need to learn them
- Defer destructive operations to the user

## Commands

After `apex-app-harness init`, the following are available:

| Command | What it does |
|---|---|
| `apex-app-harness doctor` | Health check the install |
| `apex-app-harness memory search <query>` | Semantic search across stored patterns |
| `apex-app-harness route <task>` | Get the routing tier recommendation |

## Architecture

This harness uses [@metaharness/kernel](https://www.npmjs.com/package/@metaharness/kernel) for its primitives. The kernel is a Rust-compiled WASM module with a NAPI-RS native fallback — same code runs identically on every platform.
