import Foundation

nonisolated protocol CLIExecutableLocating: Sendable {
    func executable(named name: String) -> URL?
}

nonisolated struct CLIExecutableLocator: CLIExecutableLocating, Sendable {
    let searchPaths: [URL]

    init(
        searchPaths: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/bin", isDirectory: true),
            URL(fileURLWithPath: "/bin", isDirectory: true)
        ]
    ) {
        self.searchPaths = searchPaths
    }

    func executable(named name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/") else {
            return nil
        }

        return searchPaths
            .map { $0.appendingPathComponent(name, isDirectory: false) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
