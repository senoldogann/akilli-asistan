import Foundation
import XCTest
@testable import ZeroLose

final class AskModeBoundaryTests: XCTestCase {
    func testNormalChatRoutesThroughRequestCoordinator() throws {
        let source = try productionSource("V2/Application/V2ShellRuntimeController.swift")
        let sendBody = try XCTUnwrap(functionBody(named: "sendChatMessage", in: source))

        XCTAssertTrue(sendBody.contains("processAsk("))
        XCTAssertFalse(sendBody.contains("processText("))
        XCTAssertTrue(source.contains("private let requestCoordinator: RequestCoordinator"))
    }

    func testNormalAskPathContainsNoLegacyInterviewOrProviderSpecificOrchestration() throws {
        let source = try productionSource("V2/Application/V2ShellRuntimeController.swift")
        let askBody = try XCTUnwrap(functionBody(named: "processAsk", in: source))

        XCTAssertTrue(askBody.contains("requestCoordinator.stream("))
        XCTAssertTrue(askBody.contains("case .textDelta"))

        for forbidden in [
            "intelligence" + "Service",
            "InterviewKnowledge" + "Matcher",
            "responseCache" + "Service",
            "warmUpInterview" + "Context",
            "Ollama" + "Service",
            "nativeToolRuntime.configuration()",
            "nativeTools:"
        ] {
            XCTAssertFalse(askBody.contains(forbidden), "Normal Ask path still references \(forbidden)")
        }
    }

    func testStopForwardsCancellationToRequestCoordinatorWithBoundProvider() throws {
        let source = try productionSource("V2/Application/V2ShellRuntimeController.swift")
        let stopBody = try XCTUnwrap(functionBody(named: "stopResponse", in: source))

        XCTAssertTrue(stopBody.contains("requestCoordinator.cancel("))
        XCTAssertTrue(stopBody.contains("providerID:"))
        XCTAssertTrue(source.contains("activeAskSelection"))
    }

    func testAskCapturesV2SelectionAndDoesNotRebuildLegacyProviderDisplay() throws {
        let source = try productionSource("V2/Application/V2ShellRuntimeController.swift")
        let askBody = try XCTUnwrap(functionBody(named: "processAsk", in: source))
        let shellViewModel = try productionSource("V2/UI/ShellViewModel.swift")

        XCTAssertTrue(source.contains("selectionProvider"))
        XCTAssertTrue(askBody.contains("let selection = await selectionProvider()"))
        XCTAssertTrue(askBody.contains("selection: selection"))
        XCTAssertFalse(source.contains("modelIDProvider"))
        XCTAssertFalse(source.contains("AIModelNames"))
        XCTAssertFalse(shellViewModel.contains("currentModelDisplay"))
        XCTAssertFalse(shellViewModel.contains("contextUsage"))
    }

    func testIsBusyIsClaimedBeforeAwaitingSelectionToPreventConcurrentAsks() throws {
        let source = try productionSource("V2/Application/V2ShellRuntimeController.swift")
        let askBody = try XCTUnwrap(functionBody(named: "processAsk", in: source))

        guard let busyRange = askBody.range(of: "isBusy = true"),
              let selectionRange = askBody.range(of: "let selection = await selectionProvider()") else {
            XCTFail("Expected both 'isBusy = true' and the selection await inside processAsk")
            return
        }

        XCTAssertTrue(
            busyRange.lowerBound < selectionRange.lowerBound,
            "isBusy must be claimed synchronously before the first await (selectionProvider()); otherwise two near-simultaneous processAsk calls can both pass the isBusy guard"
        )
    }

    func testProductionCompositionBuildsGeneralContextAndRequestCoordinator() throws {
        let source = try productionSource("V2/Application/ZeroLoseRuntimeContainer.swift")

        XCTAssertTrue(source.contains("ConversationContextSource("))
        XCTAssertTrue(source.contains("MemoryContextSource("))
        XCTAssertTrue(source.contains("AttachmentContextSource("))
        XCTAssertTrue(source.contains("ContextOrchestrator("))
        XCTAssertTrue(source.contains("RequestCoordinator("))
        XCTAssertTrue(source.contains("requestCoordinator: requestCoordinator"))
    }

    func testAttachmentContextIsProvidedToGeneralContextPipeline() throws {
        let controller = try productionSource("V2/Application/V2ShellRuntimeController.swift")
        let container = try productionSource("V2/Application/ZeroLoseRuntimeContainer.swift")

        XCTAssertTrue(controller.contains("attachmentContextProvider"))
        XCTAssertTrue(container.contains("AttachmentContextProviding"))
        XCTAssertFalse(
            functionBody(named: "sendChatMessage", in: controller)?.contains("INTERVIEW") == true
        )
    }

    private func functionBody(named name: String, in source: String) -> String? {
        guard let nameRange = source.range(of: "func \(name)(") else { return nil }
        guard let openingBrace = source[nameRange.lowerBound...].firstIndex(of: "{") else { return nil }

        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            let character = source[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[openingBrace...index])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private func productionSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent("ZeroLose/\(relativePath)"),
            encoding: .utf8
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
