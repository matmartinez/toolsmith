# AGENTS.md

This file provides guidance to coding agents working with code in this repository.

## Overview

Toolsmith is a Swift 6 / SwiftPM executable that bridges Model Context Protocol (MCP)
transports **and** exposes arbitrary host CLIs as MCP servers. It began as a port of
[`sparfenyuk/mcp-proxy`](https://github.com/sparfenyuk/mcp-proxy); `TODO.md` is the
staged porting roadmap, and upstream remains the source-of-truth for flag names,
defaults, env-var fallbacks, and wire-level behavior.

## Commands

```sh
swift build
swift run toolsmith --help
swift test                                          # full suite
swift test --filter ToolsmithTests.ArgvSpecTests    # one test class
swift test --filter ArgvSpecTests/testRoundTrip     # one test method
```

There is no separate lint step. Targets: the `Toolsmith` executable and the
`ToolsmithTests` test target (swift-testing). Dependencies are swift-argument-parser,
swift-nio (NIO/NIOHTTP1), and swift-subprocess — see `Package.swift`.

## Two modes, one binary

`Mode.detect` (`Sources/Toolsmith/Mode.swift`) picks the mode from the positional
`commandOrUrl` argument: an `http(s)://` URL ⇒ **client mode**, anything else (or any
config flag with no positional) ⇒ **server mode**. The single entry point is
`Toolsmith.run()` in `Toolsmith.swift`, which also holds all CLI flag definitions and
validation.

- **Client mode** (`runClientMode`): reads JSON-RPC on stdin, talks to a remote MCP
  server over SSE or streamable-HTTP, writes responses to stdout. `ClientModeProxy`
  pumps stdin↔remote in a TaskGroup. Auth layering: OAuth2 client-credentials
  (`--client-id/--client-secret/--token-url`) wraps the `HTTPClient` in a
  `BearerTokenHTTPClient`; otherwise an `API_ACCESS_TOKEN` env var is injected as a
  Bearer header (unless `--header Authorization:` already set one).

- **Server mode** (`runServerMode`): exposes one or more MCP servers over HTTP via NIO.
  `Toolsmith.run()` assembles a `[ServerModeProxy.NamedServer]` from four sources
  (positional command, `--named-server`, `--named-server-config`, `--cli-tools-config`),
  then `ServerModeProxy.start()` builds a backend per spec, registers its routes, and
  binds the listener. Shutdown is signal-driven (SIGINT/SIGTERM via dispatch sources).

## The backend abstraction (central design seam)

Everything in server mode funnels through `MCPServerBackend`
(`Sources/Toolsmith/Server/MCPServerBackend.swift`) — a small protocol
(`start/stop/subscribe/unsubscribe/send`). The HTTP route registrars dispatch traffic
to a backend **without knowing** whether it pipes JSON-RPC to a spawned child or handles
it in-process. Two conformances:

- **`ChildSession`** (`.stdioChild` backend kind): spawns a child MCP server process and
  speaks line-delimited JSON-RPC over its stdio, broadcasting messages to subscribers.
  Used by the positional command, `--named-server`, and `--named-server-config`.
- **`CLIBackend`** (`.cliExposure` backend kind): in-process backend that wraps a host
  executable. Handles `initialize`, `tools/list`/`tools/call`, and (when configured)
  `resources/list`, `resources/templates/list`, `resources/read` itself, running a
  one-shot subprocess per call (via `CLIRunner`); for tools, stdout → `TextContent`,
  non-zero exit → `isError: true` with stderr. Used by `--cli-tools-config`.

Each named server mounts three routes under a prefix (`""` for the default server,
`/servers/<name>` otherwise): `/sse` + `/messages` (legacy SSE, `ServerModeRoutes`) and
`/mcp` (streamable-HTTP, `StreamableHTTPRoutes`). A `/status` route reports activity.
Adding a new backend flavor means conforming to `MCPServerBackend` and adding a
`BackendKind` case — the routes are reused untouched.

## CLI-as-MCP-server projection

The `--cli-tools-config` JSON (schema in `Sources/Toolsmith/CLI/`, sample at
`samples/cli-tools.json`) declares, per server, an `executable` and a list of tools.
Each tool's `name`/`description`/`inputSchema` flow into `tools/list` verbatim; its
`argv` array maps the inbound `tools/call` arguments onto a concrete argv via
`projectArgv` (`ArgvProjection.swift`). `ArgvSpec` is a single-key tagged enum —
`literal`, `argument` (required; missing ⇒ JSON-RPC `-32602`), `optionalArgument`,
`flag` (`-n <value>` when present), `booleanFlag` (literal only when arg `== true`).
Non-scalar JSON argument values (null/array/object) are rejected.

The same config may also declare `resources` and `resourceTemplates`. A `resources`
entry has an exact-match `uri`; a `resourceTemplates` entry has a `uriTemplate` with
`{name}` placeholders (RFC 6570 operators are intentionally unsupported, validated at
config-load time via `URITemplateMatcher`). On `resources/read`, `CLIBackend` matches
static URIs first, then templates; placeholder captures plus a synthetic `uri` argument
feed the same `projectArgv` path, and the subprocess's stdout is wrapped per the spec's
`output` (`text` ⇒ `TextResourceContents`, `blob` ⇒ base64 `BlobResourceContents`). A
non-zero exit yields a JSON-RPC error rather than an `isError` result.

**Env merging:** a backend's per-server `env` is layered *on top of* the parent
process's environment (host CLIs need `PATH`, `HOME`, etc.); `env` supplies overrides
and additions. `--pass-environment` controls the same inheritance for spawned stdio
servers (`Toolsmith.mergeEnvironment`).

## Source layout

- `Transport/` — client-side transports: `SSEClientTransport`,
  `StreamableHTTPClientTransport`, `StdioTransport`, the `HTTPClient` abstraction +
  URLSession impl, `OAuth2`, `SSEParser`.
- `Server/` — server-mode orchestration: `ServerModeProxy`, the two backends, route
  registrars, `CORS`, `ActivityTracker`, `ServerConfigFile` loader.
- `CLI/` — CLI-exposure config types, `ArgvProjection`, `CLIRunner`, `URITemplateMatcher`.
- `JSONRPC/` — JSON-RPC 2.0 envelope + `JSONValue`.
- `MCP/` — MCP message/spec types (rev 2025-06-18): tools, resources, prompts,
  completion, progress, cancellation, handshake, logging.
- `HTTPServer/` — NIO HTTP/1.1 server + `ServerRouter` (method/path → handler).
- `Logging/` — synchronous lock-guarded `Logger` to stderr, ISO-8601 timestamps,
  level-filtered via `--log-level`/`--debug`.

## Conventions

- Concurrency uses Swift 6 strict concurrency: backends and `ServerModeProxy` are
  `actor`s; shared types are `Sendable`. Match this when adding code.
- Tests are organized one file per concern in `Tests/ToolsmithTests/`, many named
  `…ParityTests` because they port specific upstream pytest cases — preserve the parity
  intent when touching those.
- This project deviates from upstream on `--header`/`--env`/`--named-server`: a single
  delimited value per occurrence (repeat the flag) instead of two tokens, because
  swift-argument-parser has no `nargs=2`. Keep that pattern for new repeatable flags.
- `--sse-port`/`--sse-host` are deprecated aliases for `--port`/`--host`.
