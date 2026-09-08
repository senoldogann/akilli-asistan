import CoreGraphics
import Darwin

struct ChromeWindowCandidate: Equatable {
    let windowID: CGWindowID
    let processID: pid_t
    let frame: CGRect
}

struct ChromeWindowSelectionPolicy {
    func select(
        _ candidates: [ChromeWindowCandidate],
        focusedProcessID: pid_t?,
        focusedFrame: CGRect?
    ) -> ChromeWindowCandidate? {
        guard !candidates.isEmpty else { return nil }

        let processCandidates: [ChromeWindowCandidate]
        if let focusedProcessID {
            let matching = candidates.filter { $0.processID == focusedProcessID }
            processCandidates = matching.isEmpty ? candidates : matching
        } else {
            processCandidates = candidates
        }

        if let focusedFrame, !focusedFrame.isNull, !focusedFrame.isEmpty {
            return processCandidates.max {
                overlapScore($0.frame, focusedFrame) < overlapScore($1.frame, focusedFrame)
            }
        }

        return processCandidates.max { area($0.frame) < area($1.frame) }
    }

    private func overlapScore(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let intersectionArea = area(intersection)
        let unionArea = area(lhs) + area(rhs) - intersectionArea
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }

    private func area(_ rect: CGRect) -> CGFloat {
        max(0, rect.width) * max(0, rect.height)
    }
}
