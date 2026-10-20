/// Single source of truth for the release version. Reported by `--version`,
/// `/status`, and the `serverInfo`/`clientInfo` MCP handshake fields.
/// Bump together with the git tag the Homebrew formula points at.
public enum ToolsmithVersion {
    public static let current = "0.1.0"
}
