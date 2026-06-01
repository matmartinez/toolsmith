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
- [x] NIO HTTP/1.1 server scaffold + `ServerRouter` (registers method/path → handler, 404/405 split). Streaming response support via chunked transfer-encoding.
- [x] MCP SSE server-side routes: `/sse` + `/messages` (default), `/servers/<name>/{sse,messages}` per named server, `/status` with activity tracker, CORS via `--allow-origin` / `--expose-header` including OPTIONS preflight
- [x] `/mcp` streamable-HTTP server route: POST (notification → 202, request → SSE stream closing on matching reply, response → 400) and GET (server-initiated SSE). Leading `: stream-open` comment chunk to force URLSession header delivery.

## Phase 2 — Proxy core

- [x] **Client mode**: `ClientModeProxy` pumps stdin↔remote.send and remote.incoming↔stdout in a TaskGroup. Wired into `Toolsmith.run()` with both SSE and streamable-HTTP transports + OAuth + API_ACCESS_TOKEN env fallback. End-to-end test against the real HTTPServer.
- [x] **Server mode**: `ChildSession` spawns one child per server, broadcasts its messages to subscribers; `ServerModeProxy` orchestrates one HTTPServer + N children with `/sse`+`/messages` and named-server routes. Signal-driven shutdown.
- [x] `--named-server-config` JSON loader matching upstream's `mcpServers` schema. `enabled:false` filtered, per-entry env layered on top of CLI `--env`, deterministic alphabetic mount order.
- [x] `--pass-environment`, `--cwd`, `--env` plumbing through `Process`.
- [x] Logging: synchronous lock-guarded `Logger` to stderr with ISO-8601 timestamps, level filtering driven by `--log-level` / `--debug`, log points across run(), ChildSession lifecycle, and the client-mode auth + transport selection.

## Phase 3 — Test parity with upstream

- [x] Port `test_config_loader.py` parity cases into `ServerConfigLoaderTests` (empty mcpServers, missing top-level key, empty file/JSON object, invalid entry shapes, mixed enabled states)
- [x] Port `test_mcp_server.py` SSE + streamable transport parity → `MCPServerTransportParityTests` (initialize + list_prompts over /sse, 3× tools/call echo over /mcp)
- [x] Port `test_proxy_server.py` method round-trip parity → `MCPProxyMethodParityTests` (10 methods: initialize, resources/*, prompts/get, completion/complete, logging/setLevel, tools/call with isError, method-not-found error)
- [x] Port `test_progress_forwarding.py` → `ProgressForwardingParityTests` (progress over /mcp + /sse, no-token case, MCPProgressTokenExtractor parity)

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
