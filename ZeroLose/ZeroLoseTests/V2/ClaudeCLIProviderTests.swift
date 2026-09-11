import Foundation
import XCTest
@testable import ZeroLose

final class ClaudeCLIProviderTests: XCTestCase {
    func testClaudeDisablesNativeToolsAndProjectHooks() async throws {
        let runner = FixtureCLIProcessRunner(events: [.exited(0)])
        let locator = StubCLIExecutableLocator(paths: [
            "claude": URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        ])
        let provider = ClaudeCLIProvider(locator: locator, runner: runner)

        for try await _ in provider.stream(.fixture()) {}
        let commands = await runner.commands
        let command = try XCTUnwrap(commands.first)

        XCTAssertEqual(command.executable.path, "/opt/homebrew/bin/claude")
        XCTAssertTrue(command.arguments.contains("-p"))
        XCTAssertTrue(command.arguments.contains("--bare"))
        XCTAssertTrue(command.arguments.contains("--tools"))
        let toolsIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--tools"))
        XCTAssertEqual(command.arguments[toolsIndex + 1], "")
        XCTAssertTrue(command.arguments.contains("--permission-mode"))
        XCTAssertTrue(command.arguments.contains("dontAsk"))
        XCTAssertTrue(command.arguments.contains("--no-chrome"))
        XCTAssertTrue(command.arguments.contains("--no-session-persistence"))
        XCTAssertTrue(command.arguments.contains("--output-format"))
        XCTAssertTrue(command.arguments.contains("stream-json"))
        XCTAssertTrue(command.arguments.contains("--verbose"))
        XCTAssertTrue(command.arguments.contains("--include-partial-messages"))
        XCTAssertFalse(command.arguments.contains("--dangerously-skip-permissions"))
    }

    func testClaudeParsesPartialTextDeltasAndCompletion() async throws {
        let fixture = [
            #"{"type":"system","subtype":"init","session_id":"session-1"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"Hello","session_id":"session-1"}"#
        ].joined(separator: "\n") + "\n"
        let runner = FixtureCLIProcessRunner(events: [
            .stdout(Data(fixture.utf8)),
            .exited(0)
        ])
        let provider = ClaudeCLIProvider(
            locator: StubCLIExecutableLocator(paths: [
                "claude": URL(fileURLWithPath: "/opt/homebrew/bin/claude")
            ]),
            runner: runner
        )

        var events: [ModelEvent] = []
        for try await event in provider.stream(.fixture()) {
            events.append(event)
        }

        XCTAssertEqual(events, [.started, .textDelta("Hel"), .textDelta("lo"), .completed])
    }

    func testClaudeNonzeroExitMapsToProviderProcessFailure() async throws {
        let runner = FixtureCLIProcessRunner(events: [.exited(9)])
        let provider = ClaudeCLIProvider(
            locator: StubCLIExecutableLocator(paths: [
                "claude": URL(fileURLWithPath: "/opt/homebrew/bin/claude")
            ]),
            runner: runner
        )

        do {
            for try await _ in provider.stream(.fixture()) {}
            XCTFail("Expected nonzero Claude exit to fail")
        } catch let error as ProviderError {
            XCTAssertEqual(
                error,
                .processFailed(providerID: ModelProviderID(rawValue: "claude"), exitCode: 9)
            )
        }
    }

    func testClaudeCancellationDelegatesToRunner() async {
        let runner = FixtureCLIProcessRunner(events: [])
        let provider = ClaudeCLIProvider(
            locator: StubCLIExecutableLocator(paths: [:]),
            runner: runner
        )
        let sessionID = ModelSessionID(rawValue: "cancel-claude")

        await provider.cancel(sessionID: sessionID)

        let cancelled = await runner.cancelled
        XCTAssertEqual(cancelled, [sessionID])
    }
}
