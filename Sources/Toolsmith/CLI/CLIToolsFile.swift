import Foundation

/// On-disk shape of a `--cli-tools-config` file. Sibling of
/// `ServerConfigFile`; the two formats stay completely independent.
public struct CLIToolsFile: Codable, Hashable, Sendable {
    public var cliServers: [String: CLIExposureConfig]

    public init(cliServers: [String: CLIExposureConfig]) {
        self.cliServers = cliServers
    }
}

public enum CLIToolsLoader {
    public enum Failure: Error, Sendable, Equatable {
        case fileNotFound(String)
        case malformedJSON(String)
    }

    public static func load(contentsOfFile path: String) throws -> CLIToolsFile {
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Failure.fileNotFound(path)
        }
        do {
            return try JSONDecoder().decode(CLIToolsFile.self, from: data)
        } catch {
            throw Failure.malformedJSON(error.localizedDescription)
        }
    }

    /// Convert a parsed CLI tools file into the spec list
    /// `ServerModeProxy` expects, in deterministic alphabetic order.
    public static func specs(from config: CLIToolsFile) -> [ServerModeProxy.NamedServer] {
        config.cliServers
            .map { name, exposure in
                ServerModeProxy.NamedServer(name: name, backend: .cliExposure(exposure))
            }
            .sorted { $0.name < $1.name }
    }
}
