import Foundation
import ApplicationServices
import CoreGraphics
import Darwin
import ExamPilotCore

@main
struct ExamPilotMain {
    static func main() async {
        let options: CLIOptions
        do {
            options = try CLIOptions(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            fputs("ExamPilot: \(error.localizedDescription)\n\n\(CLIOptions.usage)\n", stderr)
            Darwin.exit(2)
        }

        if options.showHelp {
            print(CLIOptions.usage)
            return
        }

        let environment = ProcessInfo.processInfo.environment
        guard let apiKey = environment["OPENAI_API_KEY"], !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fputs("ExamPilot: OPENAI_API_KEY is required.\n", stderr)
            Darwin.exit(2)
        }

        if !CGPreflightScreenCaptureAccess() {
            print("ExamPilot needs Screen Recording permission to see the visible Chrome exam window.")
            guard CGRequestScreenCaptureAccess() else {
                fputs("ExamPilot: Screen Recording permission was not granted.\n", stderr)
                Darwin.exit(3)
            }
        }

        if !options.dryRun && !AXIsProcessTrusted() {
            fputs(
                "ExamPilot: Accessibility permission is required for live mouse/keyboard input. Enable the executable/Terminal in System Settings > Privacy & Security > Accessibility, then run again.\n",
                stderr
            )
            Darwin.exit(3)
        }

        let stopController = StopController()
        signal(SIGINT, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
        signalSource.setEventHandler {
            stopController.requestStop()
            fputs("\nExamPilot: stop requested; no new physical action will start.\n", stderr)
        }
        signalSource.resume()

        let model = options.model
            ?? environment["EXAMPILOT_MODEL"]
            ?? "gpt-5.6-sol"

        print("ExamPilot starting")
        print("  mode: \(options.dryRun ? "dry-run" : "live")")
        print("  model: \(model)")
        print("  target: focused Chrome window (largest visible Chrome fallback)")
        print("  stop: Ctrl-C")

        let capture = ScreenCaptureService()
        let input = NativeInputDriver()
        let executor = ActionBatchExecutor(driver: input)
        let vision = OpenAIResponsesVisionAgent(apiKey: apiKey, model: model)
        let focusService = ChromeInputFocusService()
        let loop = ExamLoop(
            capture: capture,
            visionAgent: vision,
            executor: executor,
            dryRun: options.dryRun,
            maxCycles: options.maxCycles,
            prepareForInput: { frame in
                try await focusService.focus(frame: frame)
            },
            shouldStop: { stopController.isStopped }
        )

        let result = await loop.run()
        signalSource.cancel()

        switch result {
        case .finished(let cycles):
            print("ExamPilot finished successfully after \(cycles) observation cycle(s).")
        case .dryRunPlanned(let summary, let actionCount):
            print("Dry-run plan: \(summary) [\(actionCount) action(s)]")
        case .stopped(let cycles):
            print("ExamPilot stopped after \(cycles) observation cycle(s).")
        case .nonProgress(let cycles):
            fputs("ExamPilot stopped after \(cycles) cycles because the UI did not change across three consecutive expected-change batches.\n", stderr)
            Darwin.exit(4)
        case .maxCycles(let cycles):
            fputs("ExamPilot stopped at the configured limit of \(cycles) cycles.\n", stderr)
            Darwin.exit(4)
        case .failed(let cycles, let message):
            fputs("ExamPilot failed after \(cycles) cycle(s): \(message)\n", stderr)
            Darwin.exit(1)
        }
    }
}

private final class StopController {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func requestStop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

private struct CLIOptions {
    var dryRun = false
    var model: String?
    var maxCycles = 200
    var showHelp = false

    static let usage = """
    Usage: exampilot [options]

      --dry-run             Observe and plan one action batch without posting physical input.
      --model MODEL         Override EXAMPILOT_MODEL (default: gpt-5.6-sol).
      --max-cycles N        Stop after N observation cycles (default: 200).
      -h, --help            Show this help.

    Environment:
      OPENAI_API_KEY        Required. Never printed by ExamPilot.
      EXAMPILOT_MODEL       Optional model override.
    """

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--dry-run":
                dryRun = true
            case "--model":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw CLIError.missingValue("--model")
                }
                model = arguments[index]
            case "--max-cycles":
                index += 1
                guard index < arguments.count,
                      let value = Int(arguments[index]),
                      (1...2_000).contains(value) else {
                    throw CLIError.invalidValue("--max-cycles must be an integer from 1 to 2000")
                }
                maxCycles = value
            case "-h", "--help":
                showHelp = true
            default:
                throw CLIError.unknownOption(arguments[index])
            }
            index += 1
        }
    }
}

private enum CLIError: Error, LocalizedError {
    case missingValue(String)
    case invalidValue(String)
    case unknownOption(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let option): return "Missing value for \(option)."
        case .invalidValue(let message): return message
        case .unknownOption(let option): return "Unknown option: \(option)"
        }
    }
}
