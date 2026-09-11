import Foundation

nonisolated enum OpenCodePermissionConfig {
    private static let deniedPermissionClasses = [
        "*",
        "read",
        "edit",
        "glob",
        "grep",
        "list",
        "bash",
        "task",
        "external_directory",
        "todowrite",
        "webfetch",
        "websearch",
        "lsp",
        "skill",
        "question",
        "doom_loop"
    ]

    static func denyAllJSON() throws -> Data {
        let permission = Dictionary(
            uniqueKeysWithValues: deniedPermissionClasses.map { ($0, "deny") }
        )
        return try JSONSerialization.data(
            withJSONObject: ["permission": permission],
            options: [.sortedKeys]
        )
    }
}
