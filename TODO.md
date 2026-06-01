# Toolsmith — Porting Roadmap

A staged plan for porting [`sparfenyuk/mcp-proxy`](https://github.com/sparfenyuk/mcp-proxy) to Swift. Each box should land as one small, testable commit.

## Phase 1 — Protocol & transport layer

- [x] JSON-RPC 2.0 envelope types (`Request`, `Response`, `Notification`, `Error`) with `Codable` + round-trip tests
- [x] MCP message types against spec rev 2025-06-18: `initialize`, `tools/*`, `resources/*`, `resources/templates/*`, `prompts/*`, `completion/complete`, `logging/setLevel`, progress, cancellation, list-changed notifications
- [x] `StdioTransport`: line-delimited JSON over `FileHandle`/`Pipe`. Drives both the child process (server mode) and our own stdin/stdout (client mode).
- [x] HTTP client abstraction (`HTTPClient` protocol) with URLSession-backed implementation; TLS-toggle via per-session delegate
- [x] `SSEClientTransport` — MCP SSE flow: GET stream, endpoint event, POST messages back, custom headers forwarded on both directions
- [x] OAuth2 client-credentials token flow + composable `BearerTokenHTTPClient` decorator
- [x] `StreamableHTTPClientTransport`: POST request with JSON / 202 / SSE response paths per the MCP streamable-HTTP spec.
- [ ] `HTTPServer` on NIO: routes for `/status`, `/sse`, `/messages/`, `/mcp`, and `/servers/<name>/{sse,mcp}`. CORS via `--allow-origin` / `--expose-header`. Stateless mode for `/mcp`.

## Phase 2 — Proxy core

- [ ] **Client mode**: read JSON-RPC from our stdin, forward to the remote HTTP transport, stream responses back to stdout. Progress-token plumbing.
- [ ] **Server mode**: spawn child stdio process(es) per `--named-server` / positional command, expose them via `HTTPServer`. Activity tracker for `/status`.
- [ ] `--named-server-config` JSON loader matching upstream's `mcpServers` schema. Accept `timeout`/`transportType` fields but ignore them for now (parity).
- [ ] `--pass-environment`, `--cwd`, `--env` plumbing through `Process`.
- [ ] Logging with levels per `--log-level` / `--debug`.

## Phase 3 — Test parity with upstream

- [ ] Port `test_config_loader.py` → `ConfigLoaderTests`
- [ ] Port `test_mcp_server.py` → `HTTPServerTests`
- [ ] Port `test_proxy_server.py` → `ProxyServerTests`
- [ ] Port `test_progress_forwarding.py` → `ProgressForwardingTests`

## Phase 4 — Future (not part of the mcp-proxy port)

- [ ] **CLI-as-MCP-server**: a new mode that wraps an arbitrary host executable as an MCP tool, so any CLI on the host becomes discoverable via MCP. Sketch:
  - Shape: `toolsmith expose <command> [--manifest path.json]` (or a top-level `--expose-cli` flag, TBD).
  - A manifest (JSON or TOML) declares the tool's MCP name, description, JSON-schema for arguments, and how to project the MCP `tools/call` arguments onto argv + stdin.
  - Tool result: exit code, stdout, and stderr returned to the MCP client.
  - Auto-generated manifests from `--help` parsing are a stretch goal.
  - Design doc lands before code.

## Notes

- Upstream is the source-of-truth for flag names, defaults, env-var fallbacks, and wire-level behavior. When in doubt, read `sparfenyuk/mcp-proxy`.
- We deviate from upstream on `--header` / `--env` / `--named-server` (delimited single value per occurrence instead of two tokens) because swift-argument-parser has no `nargs=2` strategy. Documented in commit `5910c77`.
