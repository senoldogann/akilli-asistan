import ExamPilotCore
import Foundation
import XCTest
@testable import ZeroLose

@MainActor
final class MacOSComputerMutationAdapterTests: XCTestCase {
    func testMapperProducesFullBoundedActionVocabulary() throws {
        let mapper = ComputerActionToolMapper()
        let state = ComputerMutationState(stateVersion: 42, observationID: "obs-42")

        let fixtures: [(ToolFabricComputerAction, String, [String: AnyHashable])] = [
            (.click(x: 10.5, y: 20.25), "computer.pointer.click", ["x": 10.5, "y": 20.25]),
            (.type("hello"), "computer.keyboard.type", ["text": "hello"]),
            (.pressKey("return"), "computer.keyboard.press", ["key": "return"]),
            (.scroll(amount: -1400), "computer.scroll", ["amount": -1400]),
            (.wait(milliseconds: 5000), "computer.wait", ["milliseconds": 5000]),
        ]

        for (action, expectedToolID, expectedArguments) in fixtures {
            let mapping = try mapper.map(action, state: state)
            XCTAssertEqual(mapping.toolID.rawValue, expectedToolID)

            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: mapping.argumentsJSON) as? [String: Any]
            )
            XCTAssertEqual((object["stateVersion"] as? NSNumber)?.uint64Value, 42)
            XCTAssertEqual(object["observationID"] as? String, "obs-42")
            for (key, value) in expectedArguments {
                XCTAssertEqual(object[key] as? AnyHashable, value)
            }
        }
    }

    func testMapperRejectsInvalidInputsBeforePhysicalExecution() {
        let mapper = ComputerActionToolMapper()
        let validState = ComputerMutationState(stateVersion: 1, observationID: "obs-1")
        let blankObservation = ComputerMutationState(stateVersion: 1, observationID: "   ")

        assertMapperError(.invalidObservationID) {
            try mapper.map(.type("hello"), state: blankObservation)
        }
        assertMapperError(.invalidCoordinate) {
            try mapper.map(.click(x: .nan, y: 10), state: validState)
        }
        assertMapperError(.invalidScrollAmount) {
            try mapper.map(.scroll(amount: 1401), state: validState)
        }
        assertMapperError(.invalidScrollAmount) {
            try mapper.map(.scroll(amount: -1401), state: validState)
        }
        assertMapperError(.invalidWaitDuration) {
            try mapper.map(.wait(milliseconds: 5001), state: validState)
        }
        assertMapperError(.unsupportedKey("cmd+enter")) {
            try mapper.map(.pressKey("cmd+enter"), state: validState)
        }
    }

    func testStaleStateRejectsWithoutInputDriverCall() async throws {
        let driver = RecordingInputDriver()
        let stateProvider = FixedComputerMutationStateProvider(
            state: ComputerMutationState(stateVersion: 8, observationID: "obs-8")
        )
        let adapter = MacOSComputerMutationAdapter(
            inputDriver: driver,
            stateProvider: stateProvider
        )
        let proposal = proposal(
            action: "pointer.click",
            stateVersion: 7,
            observationID: "obs-7",
            arguments: ["x": 10, "y": 20]
        )

        do {
            _ = try await adapter.executePhysicalProposal(
                proposal,
                parentInvocationID: InvocationID(rawValue: "inv-stale")
            )
            XCTFail("Expected stale proposal to fail closed")
        } catch let error as MacOSComputerMutationAdapterError {
            XCTAssertEqual(error, .staleState)
        }

        let events = await driver.events
        XCTAssertTrue(events.isEmpty)
    }

    func testCurrentStateMapsEachActionToExactlyOneDriverCall() async throws {
        let fixtures: [(String, [String: Any], String)] = [
            ("pointer.click", ["x": 11.5, "y": 22.5], "click:11.5:22.5"),
            ("keyboard.type", ["text": "hello"], "type:hello"),
            ("keyboard.press", ["key": "tab"], "key:tab"),
            ("scroll", ["amount": 250], "scroll:250"),
            ("wait", ["milliseconds": 125], "wait:125"),
        ]

        for (index, fixture) in fixtures.enumerated() {
            let driver = RecordingInputDriver()
            let state = ComputerMutationState(
                stateVersion: UInt64(index + 1),
                observationID: "obs-\(index + 1)"
            )
            let adapter = MacOSComputerMutationAdapter(
                inputDriver: driver,
                stateProvider: FixedComputerMutationStateProvider(state: state)
            )
            let proposal = proposal(
                action: fixture.0,
                stateVersion: state.stateVersion,
                observationID: state.observationID,
                arguments: fixture.1
            )
            let invocationID = InvocationID(rawValue: "inv-\(index)")

            let receipt = try await adapter.executePhysicalProposal(
                proposal,
                parentInvocationID: invocationID
            )

            let events = await driver.events
            XCTAssertEqual(events, [fixture.2])
            XCTAssertEqual(receipt.invocationID, invocationID)
            XCTAssertEqual(receipt.toolID.rawValue, "computer.\(fixture.0)")
        }
    }

    func testInvalidActionArgumentsFailBeforeInputDriverCall() async throws {
        let driver = RecordingInputDriver()
        let state = ComputerMutationState(stateVersion: 3, observationID: "obs-3")
        let adapter = MacOSComputerMutationAdapter(
            inputDriver: driver,
            stateProvider: FixedComputerMutationStateProvider(state: state)
        )
        let proposal = proposal(
            action: "scroll",
            stateVersion: state.stateVersion,
            observationID: state.observationID,
            arguments: ["amount": 1401]
        )

        do {
            _ = try await adapter.executePhysicalProposal(
                proposal,
                parentInvocationID: InvocationID(rawValue: "inv-invalid")
            )
            XCTFail("Expected invalid arguments to fail closed")
        } catch let error as MacOSComputerMutationAdapterError {
            XCTAssertEqual(error, .invalidArguments)
        }

        let events = await driver.events
        XCTAssertTrue(events.isEmpty)
    }

    private func proposal(
        action: String,
        stateVersion: UInt64,
        observationID: String,
        arguments: [String: Any]
    ) -> ComputerPhysicalProposal {
        var object = arguments
        object["stateVersion"] = stateVersion
        object["observationID"] = observationID
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return ComputerPhysicalProposal(
            action: action,
            stateVersion: stateVersion,
            observationID: observationID,
            argumentsJSON: data
        )
    }

    private func assertMapperError(
        _ expected: ComputerActionToolMapperError,
        operation: () throws -> ComputerActionToolMapping
    ) {
        do {
            _ = try operation()
            XCTFail("Expected mapper error: \(expected)")
        } catch let error as ComputerActionToolMapperError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private final class RecordingInputDriver: InputDriving, @unchecked Sendable {
    private let log = RecordingInputLog()

    var events: [String] {
        get async { await log.events }
    }

    func moveAndClick(x: Double, y: Double) async throws {
        await log.append("click:\(x):\(y)")
    }

    func typeText(_ text: String) async throws {
        await log.append("type:\(text)")
    }

    func pressKey(_ key: String) async throws {
        await log.append("key:\(key)")
    }

    func scroll(amount: Int) async throws {
        await log.append("scroll:\(amount)")
    }

    func wait(milliseconds: Int) async throws {
        await log.append("wait:\(milliseconds)")
    }
}

private actor RecordingInputLog {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

private actor FixedComputerMutationStateProvider: ComputerMutationStateProviding {
    private let state: ComputerMutationState

    init(state: ComputerMutationState) {
        self.state = state
    }

    func currentComputerMutationState() async throws -> ComputerMutationState {
        state
    }
}
