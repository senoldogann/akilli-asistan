import Foundation
import Observation

struct ShellProjectionSnapshot {
    let messages: [ChatMessage]
    let isBusy: Bool
    let statusMessage: String
    let currentModelDisplay: String
    let contextUsage: ContextUsage
    let isClipboardActive: Bool
    let isListeningActive: Bool
    let liveVoicePreview: String
    let attachedFileData: Data?
    let attachedFileName: String?
    let isIndexing: Bool

    static let empty = ShellProjectionSnapshot(
        messages: [],
        isBusy: false,
        statusMessage: "Ready",
        currentModelDisplay: "",
        contextUsage: ContextUsage(usedTokens: 0, windowTokens: 1),
        isClipboardActive: false,
        isListeningActive: false,
        liveVoicePreview: "",
        attachedFileData: nil,
        attachedFileName: nil,
        isIndexing: false
    )
}

@MainActor
protocol ShellFeatureControlling: AnyObject {
    func clearHistory()
    func toggleClipboard()
    func toggleListening()
    func stopResponse()
    func submitQuery(_ text: String, webSearchMode: WebSearchMode)
    func refineAnswer(messageID: UUID)
    func clearAttachment()
    func attachFile(from url: URL)
    func analyzeScreen()
    @discardableResult func warmUpInterviewContext() -> String
}

@MainActor
@Observable
final class ShellViewModel {
    private(set) var snapshot: ShellProjectionSnapshot = .empty
    private let controller: any ShellFeatureControlling

    init(controller: any ShellFeatureControlling) {
        self.controller = controller
    }

    var messages: [ChatMessage] { snapshot.messages }
    var isBusy: Bool { snapshot.isBusy }
    var statusMessage: String { snapshot.statusMessage }
    var currentModelDisplay: String { snapshot.currentModelDisplay }
    var contextUsage: ContextUsage { snapshot.contextUsage }
    var isClipboardActive: Bool { snapshot.isClipboardActive }
    var isListeningActive: Bool { snapshot.isListeningActive }
    var liveVoicePreview: String { snapshot.liveVoicePreview }
    var attachedFileData: Data? { snapshot.attachedFileData }
    var attachedFileName: String? { snapshot.attachedFileName }
    var isIndexing: Bool { snapshot.isIndexing }

    func apply(_ snapshot: ShellProjectionSnapshot) {
        self.snapshot = snapshot
    }

    func clearHistory() { controller.clearHistory() }
    func toggleClipboard() { controller.toggleClipboard() }
    func toggleListening() { controller.toggleListening() }
    func stopResponse() { controller.stopResponse() }
    func submitQuery(_ text: String, webSearchMode: WebSearchMode) {
        controller.submitQuery(text, webSearchMode: webSearchMode)
    }
    func refineAnswer(messageID: UUID) { controller.refineAnswer(messageID: messageID) }
    func clearAttachment() { controller.clearAttachment() }
    func attachFile(from url: URL) { controller.attachFile(from: url) }
    func analyzeScreen() { controller.analyzeScreen() }
    @discardableResult func warmUpInterviewContext() -> String { controller.warmUpInterviewContext() }
}
