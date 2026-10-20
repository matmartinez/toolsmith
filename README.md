# Toolsmith

A Swift CLI that bridges Model Context Protocol transports plus
exposes arbitrary host CLIs as MCP servers. Started as a port of
[`sparfenyuk/mcp-proxy`](https://github.com/sparfenyuk/mcp-proxy) —
now does that and one extra trick.

## What it does

Two modes, picked automatically from the positional argument:

- **Client mode** (`toolsmith http(s)://…`) — reads JSON-RPC on stdin,
  speaks to a remote MCP server over SSE or streamable-HTTP, writes
  responses to stdout. OAuth2 client-credentials and `API_ACCESS_TOKEN`
  env are wired in.

- **Server mode** (`toolsmith <command>` or any of the config flags)
  exposes one or more MCP servers over HTTP. Each declared server is
  mounted at `/sse` + `/messages` (legacy) and `/mcp` (streamable
  HTTP); named entries get a `/servers/<name>/` prefix. CORS,
  `/status`, and a `--log-level` aware logger to stderr are included.

Server-mode servers come in two flavors:

- **Stdio MCP servers**: spawned as child processes that speak JSON-RPC
  over their stdio (existing mcp-proxy behavior).
- **CLI-as-MCP-server**: any host executable advertised as a set of
  MCP tools. Each `tools/call` runs a one-shot subprocess; stdout
  flows back as `TextContent`, non-zero exit becomes `isError: true`
  with stderr in the content.

## Quick examples

### Bridge stdin/stdout to a remote streamable-HTTP MCP server

```sh
API_ACCESS_TOKEN='…' toolsmith --transport streamablehttp \
  http://server.example/api/mcp
```

### Expose a local stdio MCP server over HTTP

```sh
toolsmith --port 8080 uvx mcp-server-fetch
# → http://127.0.0.1:8080/sse  +  /messages  +  /mcp
```

### Expose multiple stdio servers via a config file

```sh
toolsmith --port 8080 --named-server-config servers.json
```

`servers.json`:

```json
{
  "mcpServers": {
    "fetch": { "command": "uvx", "args": ["mcp-server-fetch"] }
  }
}
```

### Expose host CLIs as MCP tools

A separate config file declares which host executables to wrap and how
their MCP `tools/call` arguments project onto argv. Both config files
can be used together.

```sh
toolsmith --port 8080 \
  --named-server-config servers.json \
  --cli-tools-config samples/cli-tools.json
```

`cli-tools.json` (excerpt):

```json
{
  "cliServers": {
    "git": {
      "executable": "/usr/bin/git",
      "tools": [
        {
          "name": "status",
          "description": "Show the working tree status (short form).",
          "inputSchema": { "type": "object", "properties": {}, "required": [] },
          "argv": [
            { "literal": "status" },
            { "literal": "--porcelain" }
          ]
        },
        {
          "name": "log",
          "description": "Show commit logs.",
          "inputSchema": {
            "type": "object",
            "properties": {
              "path":    { "type": "string" },
              "limit":   { "type": "integer" },
              "verbose": { "type": "boolean" }
            }
          },
          "argv": [
            { "literal": "log" },
            { "flag": "-n", "argument": "limit" },
            { "booleanFlag": "--stat", "argument": "verbose" },
            { "optionalArgument": "path" }
          ]
        }
      ]
    }
  }
}
```

Argv tokens are tagged objects, one variant per kind:

| JSON shape                                              | Behavior |
| ------------------------------------------------------- | -------- |
| `{ "literal": "x" }`                                    | always emit `x` |
| `{ "argument": "n" }`                                   | emit value of arg `n`; missing ⇒ JSON-RPC `-32602` |
| `{ "optionalArgument": "n" }`                           | emit value of arg `n` only if present |
| `{ "flag": "-n", "argument": "limit" }`                 | emit `-n <value>` only if `limit` is present |
| `{ "booleanFlag": "--verbose", "argument": "verbose" }` | emit `--verbose` only if `verbose == true` |

A full `samples/cli-tools.json` is checked into the repo.

**Resources**: a CLI server can also expose MCP resources alongside
its tools. Each entry adds optional `resources` and/or
`resourceTemplates` arrays. Static entries match a URI exactly;
templates use `{name}` placeholders that become captured arguments
available to the same `argv` projection used for tools. The captured
values, plus a synthetic `uri` argument carrying the inbound URI, are
projected through `argv` and the subprocess's stdout is wrapped as
either text or base64 blob per the `output` field.

```json
"files": {
  "executable": "/bin/cat",
  "tools": [],
  "resources": [
    { "name": "hosts", "uri": "file:///etc/hosts",
      "mimeType": "text/plain", "output": "text",
      "argv": [ { "literal": "/etc/hosts" } ] }
  ],
  "resourceTemplates": [
    { "name": "text-file", "uriTemplate": "file-text://{path}",
      "mimeType": "text/plain", "output": "text",
      "argv": [ { "argument": "path" } ] },
    { "name": "binary-file", "uriTemplate": "file-bytes://{path}",
      "mimeType": "application/octet-stream", "output": "blob",
      "argv": [ { "argument": "path" } ] }
  ]
}
```

> **Note:** the `file-text://` / `file-bytes://` templates above hand an
> arbitrary client-supplied path to `cat`, so any connected client can
> read any file the process can. They're a demo — don't expose this
> config on a non-loopback `--host`.

The `resources` capability is advertised on `initialize` only when at
least one resource or template is declared. `resources/subscribe`,
list-changed notifications, and RFC 6570 template operators are not
supported in this phase.

**Env merging**: the per-server `env` block is layered on top of the
parent process's environment — host CLIs almost always need `PATH`,
`HOME`, etc. to function. Use `env` for overrides and additions; the
caller's environment flows through automatically.

## Install

```sh
brew install matmartinez/tools/toolsmith
```

Requires macOS 14 or later. The sample configs land in
`$(brew --prefix)/share/toolsmith/samples`.

## Build / Run / Test

```sh
swift build
swift run toolsmith --help
swift test
```

## Status

Feature-complete vs. mcp-proxy on the bridging side (both transports,
both modes, OAuth, CORS, config loader, signal-driven shutdown, log
levels) plus the CLI-as-MCP-server extension. See `TODO.md` for the
full porting roadmap and any remaining future work.
