import Foundation
import XCTest
@testable import ZeroLose

final class CodexCLIProviderTests: XCTestCase {
    func testCodexRunsReasoningOnlyInReadOnlyIsolatedWorkspace() async throws {
        let runner = FixtureCLIProcessRunner(events: [.exited(0)])
        let locator = StubCLIExecutableLocator(paths: [
            "codex": URL(fileURLWithPath: "/opt/homebrew/bin/codex")
        ])
        let workspace = URL(fileURLWithPath: "/tmp/zerolose-provider-s1", isDirectory: true)
        let provider = CodexCLIProvider(
            locator: locator,
            runner: runner,
            workspaceRoot: workspace
        )

        for try await _ in provider.stream(.fixture()) {}
        let commands = await runner.commands
        let command = try XCTUnwrap(commands.first)

        XCTAssertEqual(command.executable.path, "/opt/homebrew/bin/codex")
        XCTAssertEqual(Array(command.arguments.prefix(2)), ["exec", "--json"])
        XCTAssertTrue(command.arguments.contains("--sandbox"))
        XCTAssertTrue(command.arguments.contains("read-only"))
        XCTAssertTrue(command.arguments.contains("--skip-git-repo-check"))
        XCTAssertTrue(command.arguments.contains("-C"))
        XCTAssertTrue(command.arguments.contains(workspace.path))
        XCTAssertFalse(command.arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    func testCodexParsesSupportedJSONLIntoCanonicalEvents() async throws {
        let fixture = [
            #"{"type":"thread.started","thread_id":"thread-1"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.completed","item":{"id":"item-1","type":"agent_message","text":"hello from codex"}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5}}"#
        ].joined(separator: "\n") + "\n"
        let runner = FixtureCLIProcessRunner(events: [
            .stdout(Data(fixture.utf8)),
            .exited(0)
        ])
        let provider = CodexCLIProvider(
            locator: StubCLIExecutableLocator(paths: [
                "codex": URL(fileURLWithPath: "/opt/homebrew/bin/codex")
            ]),
            runner: runner,
            workspaceRoot: URL(fileURLWithPath: "/tmp/codex-fixture", isDirectory: true)
        )

        var events: [ModelEvent] = []
        for try await event in provider.stream(.fixture()) {
            events.append(event)
        }

        XCTAssertEqual(events, [.started, .textDelta("hello from codex"), .completed])
    }

    func testCodexNonzeroExitMapsToProviderProcessFailure() async throws {
        let runner = FixtureCLIProcessRunner(events: [.exited(17)])
        let provider = CodexCLIProvider(
            locator: StubCLIExecutableLocator(paths: [
                "codex": URL(fileURLWithPath: "/opt/homebrew/bin/codex")
            ]),
            runner: runner,
            workspaceRoot: URL(fileURLWithPath: "/tmp/codex-failure", isDirectory: true)
        )

        do {
            for try await _ in provider.stream(.fixture()) {}
            XCTFail("Expected nonzero Codex exit to fail")
        } catch let error as ProviderError {
            XCTAssertEqual(
                error,
                .processFailed(providerID: ModelProviderID(rawValue: "codex"), exitCode: 17)
            )
        }
    }

    func testCodexCancellationDelegatesToRunner() async {
        let runner = FixtureCLIProcessRunner(events: [])
        let provider = CodexCLIProvider(
            locator: StubCLIExecutableLocator(paths: [:]),
            runner: runner,
            workspaceRoot: URL(fileURLWithPath: "/tmp/codex-cancel", isDirectory: true)
        )
        let sessionID = ModelSessionID(rawValue: "cancel-codex")

        await provider.cancel(sessionID: sessionID)

        let cancelled = await runner.cancelled
        XCTAssertEqual(cancelled, [sessionID])
    }
}
