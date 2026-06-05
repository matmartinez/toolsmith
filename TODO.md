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

## Phase 4 — CLI-as-MCP-server

- [x] **CLI-as-MCP-server**: separate `--cli-tools-config <path>` config file declares host executables and the MCP tools they expose. Each `tools/call` runs a one-shot subprocess via `CLIRunner`; stdout → `TextContent`; non-zero exit → `isError: true` with stderr. Argv encoded as discriminated tagged objects (`literal`, `argument`, `optionalArgument`, `flag`, `booleanFlag`). `CLIBackend` actor implements `MCPServerBackend` in-process so the existing routes serve it untouched. Sample at `samples/cli-tools.json`. Mixed-backend integration test in place.

## Phase 5 — CLI-as-MCP-server: resources

- [x] **Resource exposure**: `CLIExposureConfig` gains optional `resources` and `resourceTemplates`. `resources/list` and `resources/templates/list` advertise them; `resources/read` matches the URI (exact for static, `{name}`-placeholder template for dynamic), projects captures through the existing `projectArgv`, spawns via `runCLI`, and wraps stdout as text or base64 blob per the spec's `output` field. Captures are percent-decoded and a synthetic `uri` argument carries the inbound URI verbatim. `MCPResourcesCapability(subscribe: false, listChanged: false)` advertised only when at least one resource or template is declared. Unknown URI / non-zero exit surface as JSON-RPC `-32002`.

## Future (deferred)

- [ ] `resources/subscribe` + `resources/unsubscribe` for CLI-backed resources.
- [ ] CLI-driven dynamic `resources/list` (server runs a registry subcommand per request instead of serving a static config list).
- [ ] File-path indirection for binary resource output (CLI writes to a temp file, prints the path; backend reads + base64-encodes).
- [ ] RFC 6570 operators (`{?query}`, `{+path}`) in resource URI templates.
- [ ] stdin piping into the CLI subprocess from a `tools/call` argument (a new `ArgvSpec` variant or a top-level `stdin: { fromArgument: "..." }` field).
- [ ] Auto-generated CLI manifests from `--help` parsing.
- [ ] Output schemas / `structuredContent` on `MCPCallToolResult`.
- [ ] Per-tool resource limits (timeouts, max bytes captured).
- [ ] A `toolsmith expose <command>` one-shot subcommand without a config file.

## Notes

- Upstream is the source-of-truth for flag names, defaults, env-var fallbacks, and wire-level behavior. When in doubt, read `sparfenyuk/mcp-proxy`.
- We deviate from upstream on `--header` / `--env` / `--named-server` (delimited single value per occurrence instead of two tokens) because swift-argument-parser has no `nargs=2` strategy. Documented in commit `5910c77`.
