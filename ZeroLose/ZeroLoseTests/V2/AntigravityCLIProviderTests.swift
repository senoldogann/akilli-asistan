import Foundation
import XCTest
@testable import ZeroLose

final class AntigravityCLIProviderTests: XCTestCase {
    func testAntigravityWithoutAgyIsNotInstalled() async {
        let provider = AntigravityCLIProvider(
            locator: StubCLIExecutableLocator(paths: [:]),
            runner: FixtureCLIProcessRunner(events: [])
        )

        let status = await provider.status()

        XCTAssertEqual(status.availability, .notInstalled)
    }

    func testAntigravityNeverSkipsPermissions() async throws {
        let runner = FixtureCLIProcessRunner(events: [.exited(0)])
        let locator = StubCLIExecutableLocator(paths: [
            "agy": URL(fileURLWithPath: "/opt/homebrew/bin/agy")
        ])
        let workspace = URL(fileURLWithPath: "/tmp/zero-agy", isDirectory: true)
        let provider = AntigravityCLIProvider(
            locator: locator,
            runner: runner,
            workspaceRoot: workspace
        )

        for try await _ in provider.stream(.fixture()) {}
        let commands = await runner.commands
        let command = try XCTUnwrap(commands.first)

        XCTAssertEqual(command.executable.path, "/opt/homebrew/bin/agy")
        XCTAssertTrue(command.arguments.contains("--sandbox"))
        XCTAssertTrue(command.arguments.contains("-p"))
        XCTAssertTrue(command.arguments.contains("--output-format"))
        XCTAssertTrue(command.arguments.contains("stream-json"))
        XCTAssertTrue(command.arguments.contains("--print-timeout"))
        XCTAssertFalse(command.arguments.contains("--dangerously-skip-permissions"))
        XCTAssertEqual(command.workingDirectory, workspace)
    }

    func testAntigravityParsesStreamingJSONIntoCanonicalEvents() async throws {
        let fixture = [
            #"{"event":"init","conversation_id":"c1","init":{"permission_mode":"request-review"}}"#,
            #"{"event":"step_update","step_update":{"step_index":3,"state":"DONE","step_type":"agent_response","text_delta":"Hello "}}"#,
            #"{"event":"step_update","step_update":{"step_index":4,"state":"DONE","step_type":"agent_response","text_delta":"world"}}"#,
            #"{"event":"result","result":{"conversation_id":"c1","status":"SUCCESS","response":"Hello world"}}"#
        ].joined(separator: "\n") + "\n"
        let runner = FixtureCLIProcessRunner(events: [
            .stdout(Data(fixture.utf8)),
            .exited(0)
        ])
        let provider = AntigravityCLIProvider(
            locator: StubCLIExecutableLocator(paths: [
                "agy": URL(fileURLWithPath: "/opt/homebrew/bin/agy")
            ]),
            runner: runner,
            workspaceRoot: URL(fileURLWithPath: "/tmp/zero-agy-events", isDirectory: true)
        )

        var events: [ModelEvent] = []
        for try await event in provider.stream(.fixture()) {
            events.append(event)
        }

        XCTAssertEqual(
            events,
            [.started, .textDelta("Hello "), .textDelta("world"), .completed]
        )
    }

    func testAntigravityTerminalErrorStatusFailsClosed() async throws {
        let fixture = [
            #"{"event":"init","conversation_id":"c1","init":{"permission_mode":"request-review"}}"#,
            #"{"event":"result","result":{"conversation_id":"c1","status":"ERROR","response":"","error":"authentication required"}}"#
        ].joined(separator: "\n") + "\n"
        let runner = FixtureCLIProcessRunner(events: [
            .stdout(Data(fixture.utf8)),
            .exited(1)
        ])
        let provider = AntigravityCLIProvider(
            locator: StubCLIExecutableLocator(paths: [
                "agy": URL(fileURLWithPath: "/opt/homebrew/bin/agy")
            ]),
            runner: runner,
            workspaceRoot: URL(fileURLWithPath: "/tmp/zero-agy-auth", isDirectory: true)
        )

        do {
            for try await _ in provider.stream(.fixture()) {}
            XCTFail("Expected authentication-required result to fail closed")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .loginRequired(providerID: ModelProviderID(rawValue: "antigravity")))
        }
    }

    func testAntigravityCancellationDelegatesToRunner() async {
        let runner = FixtureCLIProcessRunner(events: [])
        let provider = AntigravityCLIProvider(
            locator: StubCLIExecutableLocator(paths: [:]),
            runner: runner
        )
        let sessionID = ModelSessionID(rawValue: "cancel-agy")

        await provider.cancel(sessionID: sessionID)

        let cancelled = await runner.cancelled
        XCTAssertEqual(cancelled, [sessionID])
    }
}
