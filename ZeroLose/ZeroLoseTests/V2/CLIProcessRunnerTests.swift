import Foundation
import XCTest
@testable import ZeroLose

final class CLIProcessRunnerTests: XCTestCase {
    func testCommandNeverUsesShellInterpolation() {
        let command = CLICommand(
            sessionID: ModelSessionID(rawValue: "s1"),
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", "$(touch /tmp/never)"],
            workingDirectory: nil,
            timeoutSeconds: 10,
            environmentOverrides: [:]
        )

        XCTAssertNotEqual(command.executable.path, "/bin/sh")
        XCTAssertEqual(command.arguments, ["%s", "$(touch /tmp/never)"])
    }

    func testRunnerRejectsDirectShellExecutable() async {
        let runner = CLIProcessRunner(
            baseEnvironment: ["PATH": "/bin:/usr/bin", "HOME": "/tmp"]
        )
        let command = CLICommand(
            sessionID: ModelSessionID(rawValue: "shell"),
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf forbidden"],
            workingDirectory: nil,
            timeoutSeconds: 5,
            environmentOverrides: [:]
        )

        let stream = await runner.run(command)
        var receivedError: CLIProcessRunnerError?
        do {
            for try await _ in stream {}
        } catch let error as CLIProcessRunnerError {
            receivedError = error
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(receivedError, .disallowedExecutable)
    }

    func testSanitizedEnvironmentDropsCredentialVariables() {
        let environment = CLIProcessRunner.sanitizedEnvironment([
            "PATH": "/usr/bin",
            "HOME": "/Users/test",
            "LANG": "en_US.UTF-8",
            "OPENAI_API_KEY": "secret",
            "ANTHROPIC_API_KEY": "secret",
            "OPENCODE_SERVER_PASSWORD": "secret"
        ])

        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["HOME"], "/Users/test")
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment["OPENCODE_SERVER_PASSWORD"])
    }

    func testRunnerStreamsStdoutThenExit() async throws {
        let runner = CLIProcessRunner(
            baseEnvironment: ["PATH": "/usr/bin", "HOME": "/tmp"]
        )
        let command = CLICommand(
            sessionID: ModelSessionID(rawValue: "stdout"),
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["hello"],
            workingDirectory: nil,
            timeoutSeconds: 5,
            environmentOverrides: [:]
        )

        var events: [CLIProcessEvent] = []
        for try await event in await runner.run(command) {
            events.append(event)
        }

        XCTAssertTrue(events.contains(.stdout(Data("hello".utf8))))
        XCTAssertEqual(events.last, .exited(0))
    }

    func testRunnerPreservesNonzeroExitStatus() async throws {
        let runner = CLIProcessRunner(
            baseEnvironment: ["PATH": "/usr/bin", "HOME": "/tmp"]
        )
        let command = CLICommand(
            sessionID: ModelSessionID(rawValue: "false"),
            executable: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [],
            workingDirectory: nil,
            timeoutSeconds: 5,
            environmentOverrides: [:]
        )

        var events: [CLIProcessEvent] = []
        for try await event in await runner.run(command) {
            events.append(event)
        }

        XCTAssertEqual(events.last, .exited(1))
    }

    func testCancelTerminatesActiveSession() async throws {
        let runner = CLIProcessRunner(
            baseEnvironment: ["PATH": "/bin:/usr/bin", "HOME": "/tmp"]
        )
        let sessionID = ModelSessionID(rawValue: "cancel")
        let command = CLICommand(
            sessionID: sessionID,
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            workingDirectory: nil,
            timeoutSeconds: 5,
            environmentOverrides: [:]
        )

        let stream = await runner.run(command)
        let collector = Task { () -> CLIProcessRunnerError? in
            do {
                for try await _ in stream {}
                return nil
            } catch let error as CLIProcessRunnerError {
                return error
            } catch {
                XCTFail("unexpected error: \(error)")
                return nil
            }
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        await runner.cancel(sessionID: sessionID)
        let collectedError = await collector.value

        XCTAssertEqual(collectedError, .cancelled)
    }

    func testTimeoutTerminatesActiveSession() async throws {
        let runner = CLIProcessRunner(
            baseEnvironment: ["PATH": "/bin:/usr/bin", "HOME": "/tmp"]
        )
        let command = CLICommand(
            sessionID: ModelSessionID(rawValue: "timeout"),
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            workingDirectory: nil,
            timeoutSeconds: 0.05,
            environmentOverrides: [:]
        )

        let stream = await runner.run(command)
        var receivedError: CLIProcessRunnerError?
        do {
            for try await _ in stream {}
        } catch let error as CLIProcessRunnerError {
            receivedError = error
        }

        XCTAssertEqual(receivedError, .timeout)
    }
}
