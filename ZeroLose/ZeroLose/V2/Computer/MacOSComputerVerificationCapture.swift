import CoreGraphics
import Foundation
import ScreenCaptureKit

nonisolated protocol ComputerObservationMetadataProviding: Sendable {
    func latestPresentationMetadata() async -> MacOSComputerObservationPresentationMetadata?
}

nonisolated protocol ComputerVerificationStateRefreshing:
    ComputerMutationStateRefreshing,
    ComputerObservationMetadataProviding
{}

extension MacOSComputerObservationProvider: ComputerVerificationStateRefreshing {}

nonisolated protocol ComputerVerificationCapturing: Sendable {
    func capture(
        metadata: MacOSComputerObservationPresentationMetadata
    ) async throws -> ComputerVerificationFrame
}

enum MacOSComputerVerificationCaptureError: Error, Sendable, Equatable {
    case windowUnavailable
    case invalidFrame
}

struct ScreenCaptureKitComputerVerificationCapturer: ComputerVerificationCapturing {
    func capture(
        metadata: MacOSComputerObservationPresentationMetadata
    ) async throws -> ComputerVerificationFrame {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let window = content.windows.first(where: {
            $0.windowID == metadata.windowID
                && $0.owningApplication?.processID == metadata.processID
        }) else {
            throw MacOSComputerVerificationCaptureError.windowUnavailable
        }

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width))
        configuration.height = max(1, Int(window.frame.height))
        configuration.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        guard image.width > 0, image.height > 0 else {
            throw MacOSComputerVerificationCaptureError.invalidFrame
        }

        return ComputerVerificationFrame(
            state: ComputerMutationState(
                stateVersion: metadata.stateVersion,
                observationID: metadata.observationID
            ),
            processID: metadata.processID,
            windowID: metadata.windowID,
            provenance: metadata.provenance,
            tainted: metadata.tainted,
            confidence: metadata.confidence,
            image: image
        )
    }
}
