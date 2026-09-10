import SwiftUI

struct RuntimeDashboardView: View {
    @Bindable var taskRuntimeViewModel: TaskRuntimeViewModel
    @Bindable var approvalViewModel: ApprovalViewModel
    @Bindable var timelineProjection: TimelineProjection

    let authorityMode: AuthorityMode
    let projectionError: String?
    let onClose: () -> Void

    @State private var commandErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Runtime")
                    .font(.title3.weight(.semibold))

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close runtime dashboard")
            }

            runtimeSection
            controlsSection
            approvalsSection
            timelineSection
        }
        .padding(16)
        .frame(maxWidth: 560, maxHeight: 620)
        .liquidGlassSurface(cornerRadius: 18)
        .accessibilityIdentifier("v2.runtime.dashboard")
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Runtime")
                .font(.headline)

            HStack {
                Label("Authority", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(authorityMode.rawValue)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
            }

            HStack(alignment: .firstTextBaseline) {
                Label("Status", systemImage: "waveform.path.ecg")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(taskRuntimeViewModel.statusText)
                    .font(.caption)
                    .multilineTextAlignment(.trailing)
            }

            if let projectionError, !projectionError.isEmpty {
                Label(projectionError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Controls")
                .font(.headline)

            HStack(spacing: 8) {
                Button("Pause") {
                    runCommand { try await taskRuntimeViewModel.pause() }
                }
                .disabled(!taskRuntimeViewModel.canPause)

                Button("Resume") {
                    runCommand { try await taskRuntimeViewModel.resume() }
                }
                .disabled(!taskRuntimeViewModel.canResume)

                Button("Cancel") {
                    runCommand { try await taskRuntimeViewModel.cancel() }
                }
                .disabled(!taskRuntimeViewModel.canCancel)
            }
            .controlSize(.small)

            if !taskRuntimeViewModel.hasActiveGoal {
                Text("Autonomous runtime not configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let commandErrorMessage {
                Text(commandErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var approvalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pending Approvals")
                    .font(.headline)
                Spacer()
                Text("\(approvalViewModel.pendingCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if approvalViewModel.pending.isEmpty {
                Text("No pending approvals")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(approvalViewModel.pending) { approval in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(approval.summary)
                            .font(.subheadline.weight(.medium))

                        approvalMetadata(approval)

                        HStack(spacing: 8) {
                            Button("Approve") {
                                runCommand {
                                    try await approvalViewModel.approve(approval.invocationID)
                                }
                            }

                            Button("Deny") {
                                runCommand {
                                    try await approvalViewModel.deny(approval.invocationID)
                                }
                            }
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity Timeline")
                .font(.headline)

            if timelineProjection.items.isEmpty {
                Text("No runtime activity yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(timelineProjection.items.reversed()) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: timelineIcon(for: item.state))
                                    .foregroundStyle(timelineForeground(for: item.state))
                                    .frame(width: 16)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.summary)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                    Text(item.state.rawValue)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func approvalMetadata(_ approval: ApprovalPresentation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let tool = approval.tool {
                Text("Tool: \(tool)")
            }
            if let provider = approval.provider {
                Text("Provider: \(provider)")
            }
            if let risk = approval.risk {
                Text("Risk: \(risk)")
            }
            if let effect = approval.effect {
                Text("Effect: \(effect)")
            }
            if let destination = approval.destination {
                Text("Destination: \(destination)")
            }
            if let credentialScope = approval.credentialScope {
                Text("Scope: \(credentialScope)")
            }
            if let mutationStatus = approval.mutationStatus {
                Text("Mutation: \(mutationStatus)")
            }
            if let approvalReason = approval.approvalReason {
                Text("Reason: \(approvalReason)")
            }
            if approval.tainted {
                Text("Tainted input")
            }
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    private func runCommand(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await operation()
                commandErrorMessage = nil
            } catch {
                commandErrorMessage = "Command failed: \(error.localizedDescription)"
            }
        }
    }

    private func timelineIcon(for state: TimelineItemState) -> String {
        switch state {
        case .running: return "circle.dotted"
        case .executed: return "bolt.circle"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func timelineForeground(for state: TimelineItemState) -> Color {
        switch state {
        case .running: return .secondary
        case .executed: return .blue
        case .succeeded: return .green
        case .failed: return .red
        }
    }
}
