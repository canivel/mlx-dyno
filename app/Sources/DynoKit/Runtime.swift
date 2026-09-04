import Foundation

/// Where the Python side of Dyno lives.
///
/// The shipped app carries its own Python and MLX inside the bundle, so a user
/// installs one thing and nothing else. A development build (`build.sh --slim`)
/// has no runtime inside it, and falls back to a `dyno` CLI on disk.
public enum Runtime {
    public enum Kind: Equatable, Sendable {
        /// Python and MLX bundled in `Dyno.app/Contents/Resources`.
        case bundled(python: String, libraries: String)
        /// A `dyno` executable found on the system.
        case external(executable: String)

        public var describedPath: String {
            switch self {
            case let .bundled(python, _): return python
            case let .external(executable): return executable
            }
        }
    }

    /// Resolve once at launch: the answer cannot change while the app runs.
    public static let current: Kind? = resolve()

    public static var isBundled: Bool {
        if case .bundled = current { return true }
        return false
    }

    private static func resolve() -> Kind? {
        if let resources = Bundle.main.resourceURL {
            let libraries = resources.appendingPathComponent("pylib").path
            let pythonDirectory = resources.appendingPathComponent("python/bin")
            let manager = FileManager.default
            if manager.fileExists(atPath: libraries),
               let entries = try? manager.contentsOfDirectory(atPath: pythonDirectory.path) {
                // The interpreter is named for its version (python3.12).
                let interpreters = entries
                    .filter { $0.hasPrefix("python3") && !$0.hasSuffix("-config") }
                    .sorted()
                if let interpreter = interpreters.last {
                    let python = pythonDirectory.appendingPathComponent(interpreter).path
                    if manager.isExecutableFile(atPath: python) {
                        return .bundled(python: python, libraries: libraries)
                    }
                }
            }
        }
        if let executable = findCLI() { return .external(executable: executable) }
        return nil
    }

    /// Candidate locations for a separately installed `dyno`, most specific first.
    public static func findCLI(configured: String? = nil) -> String? {
        let manager = FileManager.default
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            configured,
            "\(home)/.mlx-dyno/venv/bin/dyno",
            "/opt/homebrew/bin/dyno",
            "/usr/local/bin/dyno",
        ].compactMap { $0 }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map {
                (String($0) as NSString).appendingPathComponent("dyno")
            }
        }
        return candidates.first { manager.isExecutableFile(atPath: $0) }
    }

    /// The command and environment that run `dyno <arguments>`.
    public static func invocation(
        for arguments: [String]
    ) -> (executable: String, arguments: [String], environment: [String: String])? {
        guard let current else { return nil }
        var environment = ProcessInfo.processInfo.environment
        switch current {
        case let .bundled(python, libraries):
            environment["PYTHONPATH"] = libraries
            // A stray PYTHONHOME or user site-packages from the launching shell
            // would send the bundled interpreter looking outside the bundle.
            environment.removeValue(forKey: "PYTHONHOME")
            environment["PYTHONNOUSERSITE"] = "1"
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            return (python, ["-m", "dyno"] + arguments, environment)
        case let .external(executable):
            return (executable, arguments, environment)
        }
    }
}
