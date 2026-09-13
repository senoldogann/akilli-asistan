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

    /// Captured from a real `codex exec --json` run whose account hit its usage
    /// limit. The provider states the reason; the app must show it instead of
    /// collapsing it into an opaque malformed-output error.
    func testCodexUsageLimitIsSurfacedAsTheProviderReason() async throws {
        let fixture = [
            #"{"type":"thread.started","thread_id":"thread-1"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Skill descriptions were shortened."}}"#,
            #"{"type":"error","message":"You've hit your usage limit. Upgrade to Pro or try again later."}"#,
            #"{"type":"turn.failed","error":{"message":"You've hit your usage limit. Upgrade to Pro or try again later."}}"#
        ].joined(separator: "\n") + "\n"
        let runner = FixtureCLIProcessRunner(events: [
            .stdout(Data(fixture.utf8)),
            .exited(1)
        ])
        let provider = CodexCLIProvider(
            locator: StubCLIExecutableLocator(paths: [
                "codex": URL(fileURLWithPath: "/opt/homebrew/bin/codex")
            ]),
            runner: runner,
            workspaceRoot: URL(fileURLWithPath: "/tmp/codex-limit", isDirectory: true)
        )

        let error = try await Self.capturedProviderError(from: provider)

        XCTAssertEqual(
            error,
            .providerReported(
                providerID: ModelProviderID(rawValue: "codex"),
                message: "You've hit your usage limit. Upgrade to Pro or try again later."
            )
        )
        XCTAssertTrue(
            error.localizedDescription.contains("usage limit"),
            "The user must see why Codex refused the turn, not an enum index"
        )
        XCTAssertFalse(error.localizedDescription.contains("error 7"))
    }

    /// A CLI that fails without structured JSON must still explain itself through
    /// its (bounded, redacted) stderr instead of a bare exit status.
    func testCodexNonzeroExitWithoutStructuredReasonFallsBackToStderr() async throws {
        let runner = FixtureCLIProcessRunner(events: [
            .stderr(Data("error: not signed in, run codex login\n".utf8)),
            .exited(1)
        ])
        let provider = CodexCLIProvider(
            locator: StubCLIExecutableLocator(paths: [
                "codex": URL(fileURLWithPath: "/opt/homebrew/bin/codex")
            ]),
            runner: runner,
            workspaceRoot: URL(fileURLWithPath: "/tmp/codex-stderr", isDirectory: true)
        )

        let error = try await Self.capturedProviderError(from: provider)

        XCTAssertEqual(
            error,
            .providerReported(
                providerID: ModelProviderID(rawValue: "codex"),
                message: "error: not signed in, run codex login"
            )
        )
    }

    /// Provider text is untrusted: credential-shaped material must never reach the
    /// user through an error message.
    func testCodexStderrDiagnosticsRedactCredentialShapedText() async throws {
        let runner = FixtureCLIProcessRunner(events: [
            .stderr(Data("failed: Authorization: Bearer sk-live-abcdef1234567890\n".utf8)),
            .exited(1)
        ])
        let provider = CodexCLIProvider(
            locator: StubCLIExecutableLocator(paths: [
                "codex": URL(fileURLWithPath: "/opt/homebrew/bin/codex")
            ]),
            runner: runner,
            workspaceRoot: URL(fileURLWithPath: "/tmp/codex-secret", isDirectory: true)
        )

        let error = try await Self.capturedProviderError(from: provider)
        let rendered = error.localizedDescription

        XCTAssertFalse(rendered.contains("sk-live-abcdef1234567890"))
        XCTAssertFalse(rendered.contains("Bearer sk-live"))
        XCTAssertTrue(rendered.contains("<redacted>"))
    }

    private static func capturedProviderError(
        from provider: CodexCLIProvider
    ) async throws -> ProviderError {
        do {
            for try await _ in provider.stream(.fixture()) {}
            XCTFail("Expected the Codex stream to fail")
            throw ProviderError.providerUnavailable(providerID: ModelProviderID(rawValue: "codex"))
        } catch let error as ProviderError {
            return error
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
