import Foundation
import XCTest
@testable import ZeroLose

final class OpenCodeCLIProviderTests: XCTestCase {
    func testOpenCodeRunsWithEphemeralDenyAllPermissions() async throws {
        let runner = FixtureCLIProcessRunner(events: [.exited(0)])
        let locator = StubCLIExecutableLocator(paths: [
            "opencode": URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
        ])
        let workspace = URL(fileURLWithPath: "/tmp/zero-opencode", isDirectory: true)
        let provider = OpenCodeCLIProvider(
            locator: locator,
            runner: runner,
            workspaceRoot: workspace
        )

        for try await _ in provider.stream(.fixture()) {}
        let commands = await runner.commands
        let command = try XCTUnwrap(commands.first)

        XCTAssertEqual(command.executable.path, "/opt/homebrew/bin/opencode")
        XCTAssertEqual(Array(command.arguments.prefix(3)), ["run", "--format", "json"])
        XCTAssertFalse(command.arguments.contains("--auto"))
        XCTAssertFalse(command.arguments.contains(where: { $0.contains("opencode.ai/") }))
        XCTAssertFalse(command.arguments.contains(where: {
            $0.lowercased().contains("session") && $0.lowercased().contains("header")
        }))
        XCTAssertEqual(command.workingDirectory, workspace)
        let configPath = try XCTUnwrap(command.environmentOverrides[.openCodeConfig])
        XCTAssertTrue(configPath.hasPrefix(workspace.path))
    }

    func testDenyAllPermissionConfigDeniesEveryDeclaredPermissionClass() throws {
        let data = try OpenCodePermissionConfig.denyAllJSON()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let permissions = try XCTUnwrap(object["permission"] as? [String: String])
        let expected = Set([
            "*", "read", "edit", "glob", "grep", "list", "bash", "task",
            "external_directory", "todowrite", "webfetch", "websearch", "lsp",
            "skill", "question", "doom_loop"
        ])

        XCTAssertEqual(Set(permissions.keys), expected)
        XCTAssertTrue(permissions.values.allSatisfy { $0 == "deny" })
    }

    func testOpenCodeParsesJSONEventsIntoCanonicalEvents() async throws {
        let fixture = [
            #"{"type":"step_start","sessionID":"ses_1","part":{"type":"step-start"}}"#,
            #"{"type":"text","sessionID":"ses_1","part":{"type":"text","text":"hello from opencode","time":{"start":1,"end":2}}}"#,
            #"{"type":"step_finish","sessionID":"ses_1","part":{"type":"step-finish","reason":"stop"}}"#
        ].joined(separator: "\n") + "\n"
        let runner = FixtureCLIProcessRunner(events: [
            .stdout(Data(fixture.utf8)),
            .exited(0)
        ])
        let provider = OpenCodeCLIProvider(
            locator: StubCLIExecutableLocator(paths: [
                "opencode": URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
            ]),
            runner: runner,
            workspaceRoot: URL(fileURLWithPath: "/tmp/zero-opencode-events", isDirectory: true)
        )

        var events: [ModelEvent] = []
        for try await event in provider.stream(.fixture()) {
            events.append(event)
        }

        XCTAssertEqual(events, [.started, .textDelta("hello from opencode"), .completed])
    }

    func testOpenCodeIgnoresSyntheticCompactionText() async throws {
        let fixture = [
            #"{"type":"step_start","sessionID":"ses_1","part":{"type":"step-start"}}"#,
            #"{"type":"text","sessionID":"ses_1","part":{"type":"text","text":"internal compaction","synthetic":true,"metadata":{"compaction_continue":true}}}"#,
            #"{"type":"text","sessionID":"ses_1","part":{"type":"text","text":"visible answer"}}"#,
            #"{"type":"step_finish","sessionID":"ses_1","part":{"type":"step-finish","reason":"stop"}}"#
        ].joined(separator: "\n") + "\n"
        let runner = FixtureCLIProcessRunner(events: [
            .stdout(Data(fixture.utf8)),
            .exited(0)
        ])
        let provider = OpenCodeCLIProvider(
            locator: StubCLIExecutableLocator(paths: [
                "opencode": URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
            ]),
            runner: runner,
            workspaceRoot: URL(fileURLWithPath: "/tmp/zero-opencode-synthetic", isDirectory: true)
        )

        var events: [ModelEvent] = []
        for try await event in provider.stream(.fixture()) {
            events.append(event)
        }

        XCTAssertEqual(events, [.started, .textDelta("visible answer"), .completed])
    }

    func testOpenCodeNonzeroExitMapsToProviderProcessFailure() async throws {
        let runner = FixtureCLIProcessRunner(events: [.exited(12)])
        let provider = OpenCodeCLIProvider(
            locator: StubCLIExecutableLocator(paths: [
                "opencode": URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
            ]),
            runner: runner,
            workspaceRoot: URL(fileURLWithPath: "/tmp/zero-opencode-failure", isDirectory: true)
        )

        do {
            for try await _ in provider.stream(.fixture()) {}
            XCTFail("Expected nonzero OpenCode exit to fail")
        } catch let error as ProviderError {
            XCTAssertEqual(
                error,
                .processFailed(providerID: ModelProviderID(rawValue: "opencode"), exitCode: 12)
            )
        }
    }
}
