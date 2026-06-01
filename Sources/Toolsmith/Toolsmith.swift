import ArgumentParser

@main
struct Toolsmith: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "toolsmith",
        abstract: "Bridge MCP transports (stdio ↔ SSE/StreamableHTTP).",
        version: "0.0.0"
    )

    mutating func run() async throws {
        print("toolsmith: not implemented")
    }
}
