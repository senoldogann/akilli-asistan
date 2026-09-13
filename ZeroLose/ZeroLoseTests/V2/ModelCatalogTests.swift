import Foundation
import XCTest
@testable import ZeroLose

/// The picker was empty because every CLI provider returned no models, and no
/// reasoning effort could be chosen because the contract had no such field. These
/// tests pin the real catalog shapes (captured from `codex debug models` and
/// `opencode models` on this machine) so the dropdown and effort control stay
/// backed by provider-published data rather than a hardcoded list.
final class ModelCatalogTests: XCTestCase {
    private let codexID = ModelProviderID(rawValue: "codex")
    private let openCodeID = ModelProviderID(rawValue: "opencode")

    func testCodexCatalogExposesListedModelsWithTheirReasoningLevels() throws {
        let catalog = """
        {
          "models": [
            {
              "slug": "gpt-6-astra",
              "display_name": "GPT-6-Astra",
              "visibility": "list",
              "default_reasoning_level": "low",
              "supported_reasoning_levels": [
                {"effort": "low", "description": "Fast responses"},
                {"effort": "high", "description": "Greater depth"},
                {"effort": "xhigh", "description": "Extra high"}
              ],
              "input_modalities": ["text", "image"]
            },
            {
              "slug": "internal-hidden-model",
              "display_name": "Hidden",
              "visibility": "hidden",
              "supported_reasoning_levels": [{"effort": "low"}]
            }
          ]
        }
        """

        let models = CodexModelCatalog.models(
            from: Data(catalog.utf8),
            providerID: codexID
        )

        XCTAssertEqual(models.count, 1, "Hidden catalog rows must not be offered")
        let model = try XCTUnwrap(models.first)
        XCTAssertEqual(model.id, "gpt-6-astra")
        XCTAssertEqual(model.displayName, "GPT-6-Astra")
        XCTAssertEqual(model.providerID, codexID)
        XCTAssertEqual(model.reasoningEfforts, ["low", "high", "xhigh"])
        XCTAssertEqual(model.defaultReasoningEffort, "low")
        XCTAssertTrue(model.capabilities.contains(.vision))
        XCTAssertTrue(model.capabilities.contains(.textStreaming))
    }

    func testCodexCatalogWithoutEffortLevelsAdvertisesNoEffortControl() throws {
        let catalog = """
        {"models":[{"slug":"plain-model","display_name":"Plain","visibility":"list"}]}
        """

        let model = try XCTUnwrap(
            CodexModelCatalog.models(from: Data(catalog.utf8), providerID: codexID).first
        )

        XCTAssertTrue(model.reasoningEfforts.isEmpty)
        XCTAssertNil(model.defaultReasoningEffort)
        XCTAssertFalse(model.capabilities.contains(.vision))
    }

    func testCodexCatalogIgnoresUnreadableInput() {
        XCTAssertTrue(
            CodexModelCatalog.models(from: Data("not json".utf8), providerID: codexID).isEmpty
        )
        XCTAssertTrue(
            CodexModelCatalog.models(from: Data(#"{"models":"nope"}"#.utf8), providerID: codexID).isEmpty
        )
    }

    func testCodexCatalogDropsADefaultEffortItDoesNotPublish() throws {
        let catalog = """
        {"models":[{"slug":"m","visibility":"list","default_reasoning_level":"ultra",
        "supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]}]}
        """

        let model = try XCTUnwrap(
            CodexModelCatalog.models(from: Data(catalog.utf8), providerID: codexID).first
        )

        XCTAssertNil(
            model.defaultReasoningEffort,
            "A default the model does not publish would be an invalid request"
        )
    }

    func testOpenCodeCatalogParsesProviderScopedModelIDs() throws {
        let listing = """
        opencode/big-pickle
        opencode-go/deepseek-v4-pro
        not a model line
        {"json":"noise"}
        """

        let models = OpenCodeModelCatalog.models(from: listing, providerID: openCodeID)

        XCTAssertEqual(models.map(\.id), ["opencode/big-pickle", "opencode-go/deepseek-v4-pro"])
        XCTAssertEqual(models[1].displayName, "deepseek-v4-pro (opencode-go)")
        XCTAssertEqual(models[0].providerID, openCodeID)
        XCTAssertTrue(models[0].reasoningEfforts.isEmpty)
    }

    func testProviderPassesBoundReasoningEffortToTheCLI() async throws {
        let runner = FixtureCLIProcessRunner(events: [.exited(0)])
        let provider = CodexCLIProvider(
            locator: StubCLIExecutableLocator(paths: [
                "codex": URL(fileURLWithPath: "/opt/homebrew/bin/codex")
            ]),
            runner: runner,
            workspaceRoot: URL(fileURLWithPath: "/tmp/codex-effort", isDirectory: true)
        )
        let request = ModelRequest(
            sessionID: ModelSessionID(rawValue: "effort"),
            conversation: [ModelMessage(role: .user, content: "hello")],
            modelID: "gpt-6-astra",
            tools: [],
            responseMode: .text,
            reasoningEffort: "xhigh"
        )

        for try await _ in provider.stream(request) {}

        let commands = await runner.commands
        let command = try XCTUnwrap(commands.first)
        XCTAssertTrue(command.arguments.contains("--model"))
        XCTAssertTrue(command.arguments.contains("gpt-6-astra"))
        XCTAssertTrue(command.arguments.contains("-c"))
        XCTAssertTrue(
            command.arguments.contains("model_reasoning_effort=\"xhigh\""),
            "The bound effort must reach the CLI; got \(command.arguments)"
        )
    }

    func testProviderSendsNoEffortFlagWhenNoneIsBound() async throws {
        let runner = FixtureCLIProcessRunner(events: [.exited(0)])
        let provider = CodexCLIProvider(
            locator: StubCLIExecutableLocator(paths: [
                "codex": URL(fileURLWithPath: "/opt/homebrew/bin/codex")
            ]),
            runner: runner,
            workspaceRoot: URL(fileURLWithPath: "/tmp/codex-noeffort", isDirectory: true)
        )

        for try await _ in provider.stream(.fixture()) {}

        let commands = await runner.commands
        let command = try XCTUnwrap(commands.first)
        XCTAssertFalse(command.arguments.contains("-c"))
    }

    func testOpenCodePassesBoundEffortAsVariant() async throws {
        let runner = FixtureCLIProcessRunner(events: [.exited(0)])
        let provider = OpenCodeCLIProvider(
            locator: StubCLIExecutableLocator(paths: [
                "opencode": URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
            ]),
            runner: runner,
            workspaceRoot: URL(fileURLWithPath: "/tmp/opencode-effort", isDirectory: true)
        )
        let request = ModelRequest(
            sessionID: ModelSessionID(rawValue: "effort-oc"),
            conversation: [ModelMessage(role: .user, content: "hello")],
            modelID: "opencode-go/deepseek-v4-pro",
            tools: [],
            responseMode: .text,
            reasoningEffort: "high"
        )

        for try await _ in provider.stream(request) {}

        let commands = await runner.commands
        let command = try XCTUnwrap(commands.first)
        XCTAssertTrue(command.arguments.contains("--variant"))
        XCTAssertTrue(command.arguments.contains("high"))
    }

    func testCodexDiscoveryUsesThePublishedCatalogCommand() async throws {
        let catalog = #"{"models":[{"slug":"gpt-6-astra","display_name":"GPT-6-Astra","visibility":"list","supported_reasoning_levels":[{"effort":"medium"}]}]}"#
        let runner = FixtureCLIProcessRunner(events: [
            .stdout(Data(catalog.utf8)),
            .exited(0)
        ])
        let provider = CodexCLIProvider(
            locator: StubCLIExecutableLocator(paths: [
                "codex": URL(fileURLWithPath: "/opt/homebrew/bin/codex")
            ]),
            runner: runner
        )

        let models = try await provider.discoverModels()

        let commands = await runner.commands
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(command.arguments, ["debug", "models"])
        XCTAssertEqual(models.map(\.id), ["gpt-6-astra"])
        XCTAssertEqual(models.first?.reasoningEfforts, ["medium"])
    }

    func testDiscoveryFailureLeavesThePickerEmptyInsteadOfInventingModels() async throws {
        let runner = FixtureCLIProcessRunner(
            events: [],
            terminalError: .launchFailed
        )
        let provider = CodexCLIProvider(
            locator: StubCLIExecutableLocator(paths: [
                "codex": URL(fileURLWithPath: "/opt/homebrew/bin/codex")
            ]),
            runner: runner
        )

        let models = try await provider.discoverModels()

        XCTAssertTrue(models.isEmpty)
    }
}
