import CoreGraphics
import ComputerAgentCore

public struct ActionPolicyContext: Equatable {
    public let stateVersion: UInt64
    private let taskProfile: ExamTaskProfile

    public var navigationAllowed: Bool {
        taskProfile.navigationAllowed
    }

    public init(stateVersion: UInt64, navigationAllowed: Bool) {
        self.stateVersion = stateVersion
        self.taskProfile = ExamTaskProfile(
            state: ExamRuntimeState(
                stateVersion: stateVersion,
                answerState: navigationAllowed ? .verified : .unanswered,
                uiPhase: .stable
            )
        )
    }

    public init(state: ExamRuntimeState) {
        self.stateVersion = state.stateVersion
        self.taskProfile = ExamTaskProfile(state: state)
    }
}

public struct ActionBatchPolicy {
    public let maxActions: Int
    public let maxWaitMilliseconds: Int
    public let maxAbsoluteScroll: Int

    public init(maxActions: Int = 12, maxWaitMilliseconds: Int = 5_000, maxAbsoluteScroll: Int = 1_400) {
        self.maxActions = maxActions
        self.maxWaitMilliseconds = maxWaitMilliseconds
        self.maxAbsoluteScroll = maxAbsoluteScroll
    }

    public func validate(_ decision: ExamDecision, screenBounds: CGRect) throws -> ValidatedBatch {
        try validate(
            decision,
            screenBounds: screenBounds,
            context: ActionPolicyContext(stateVersion: 0, navigationAllowed: true)
        )
    }

    public func validate(
        _ decision: ExamDecision,
        screenBounds: CGRect,
        context: ActionPolicyContext
    ) throws -> ValidatedBatch {
        let safetyPolicy = ComputerAgentSafetyPolicy()
        let taskProfile = computerTaskProfile
        guard safetyPolicy.validate(
            actionCount: decision.actions.count,
            profile: taskProfile
        ) == .allowed else {
            throw ActionValidationError.tooManyActions
        }

        var accepted: [ExamAction] = []
        accepted.reserveCapacity(decision.actions.count)
        var deferredProtectedBoundary = false

        for action in decision.actions {
            if action.boundary, action.kind != .finish, !context.navigationAllowed {
                guard !accepted.isEmpty else {
                    throw ActionValidationError.protectedBoundaryBeforeAnswer
                }
                deferredProtectedBoundary = true
                break
            }

            try validate(
                action,
                screenBounds: screenBounds,
                safetyPolicy: safetyPolicy,
                taskProfile: taskProfile
            )
            accepted.append(action)

            if action.boundary || action.kind == .finish {
                break
            }
        }

        let boundaryRequiresVerification = accepted.contains {
            $0.boundary && $0.kind != .finish
        }

        return ValidatedBatch(
            summary: decision.summary,
            expectsVisualChange: decision.expectsVisualChange || boundaryRequiresVerification || deferredProtectedBoundary,
            actions: accepted,
            stateVersion: context.stateVersion,
            deferredProtectedBoundary: deferredProtectedBoundary,
            expectedOutcome: expectedOutcome(
                actions: accepted,
                containsProtectedBoundary: boundaryRequiresVerification,
                screenBounds: screenBounds
            )
        )
    }

    private var computerTaskProfile: ComputerTaskProfile {
        ComputerTaskProfile(
            maxActions: maxActions,
            maxWaitMilliseconds: maxWaitMilliseconds,
            maxAbsoluteScroll: maxAbsoluteScroll
        )
    }

    private func expectedOutcome(
        actions: [ExamAction],
        containsProtectedBoundary: Bool,
        screenBounds: CGRect
    ) -> ExpectedOutcomeKind {
        if containsProtectedBoundary {
            return .navigation
        }
        if actions.contains(where: { $0.kind == .scroll }) {
            return .viewportChange
        }

        let answerActions = actions.filter { action in
            switch action.kind {
            case .moveClick, .typeText, .key:
                return !action.boundary
            case .scroll, .wait, .finish:
                return false
            }
        }
        guard !answerActions.isEmpty else {
            return .none
        }

        // Text/key mutations can alter a region far from the initial focus click, so they
        // keep whole-frame verification. Pure click answer batches can be verified against
        // the final clicked target, which is essential for small radio/checkbox mutations.
        let containsTextOrKeyMutation = answerActions.contains {
            $0.kind == .typeText || $0.kind == .key
        }
        if !containsTextOrKeyMutation,
           let click = answerActions.last(where: { $0.kind == .moveClick }),
           let x = click.x,
           let y = click.y,
           screenBounds.width > 0,
           screenBounds.height > 0 {
            let normalizedX = (x - screenBounds.minX) / screenBounds.width
            let normalizedY = (y - screenBounds.minY) / screenBounds.height
            if normalizedX.isFinite,
               normalizedY.isFinite,
               (0...1).contains(normalizedX),
               (0...1).contains(normalizedY) {
                return .answerMutationAt(
                    normalizedX: normalizedX,
                    normalizedY: normalizedY
                )
            }
        }

        return .answerMutation
    }

    private func validate(
        _ action: ExamAction,
        screenBounds: CGRect,
        safetyPolicy: ComputerAgentSafetyPolicy,
        taskProfile: ComputerTaskProfile
    ) throws {
        let bounds = ComputerSafetyBounds(
            minX: screenBounds.minX,
            minY: screenBounds.minY,
            width: screenBounds.width,
            height: screenBounds.height
        )

        let safetyAction: ComputerSafetyAction
        switch action.kind {
        case .moveClick:
            safetyAction = .moveClick(x: action.x, y: action.y)
        case .typeText:
            safetyAction = .typeText(action.text)
        case .key:
            safetyAction = .key(action.key)
        case .scroll:
            safetyAction = .scroll(amount: action.amount)
        case .wait:
            safetyAction = .wait(milliseconds: action.milliseconds)
        case .finish:
            safetyAction = .finish
        }

        switch safetyPolicy.validate(
            safetyAction,
            bounds: bounds,
            profile: taskProfile
        ) {
        case .allowed:
            break
        case .denied(.coordinateOutOfBounds):
            throw ActionValidationError.coordinateOutOfBounds
        case .denied(.waitOutOfRange):
            throw ActionValidationError.waitOutOfRange
        case .denied(.scrollOutOfRange):
            throw ActionValidationError.scrollOutOfRange
        case .denied(.tooManyActions):
            throw ActionValidationError.tooManyActions
        case .denied(.invalidActionShape):
            throw ActionValidationError.missingRequiredField(action.kind)
        case .denied(.staleState),
             .denied(.staleObservation),
             .denied(.focusMismatch),
             .denied(.cancelled):
            // Context-only denials cannot originate from action-shape validation.
            // Fail closed while preserving the legacy validation error surface.
            throw ActionValidationError.missingRequiredField(action.kind)
        }

        if action.kind == .key,
           let key = action.key,
           SupportedInputKey(rawValue: key.lowercased()) == nil {
            throw ActionValidationError.unsupportedKey(key)
        }
    }
}
