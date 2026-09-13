import SwiftUI

struct ProviderSelectorView: View {
    @Bindable var viewModel: ProviderViewModel

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(viewModel.snapshot.providers) { provider in
                    Button {
                        Task { await viewModel.selectProvider(provider.id) }
                    } label: {
                        if provider.id == viewModel.snapshot.selection.providerID {
                            Label(provider.displayName, systemImage: "checkmark")
                        } else {
                            Text(provider.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                    Text(viewModel.selectedProvider?.displayName ?? "Provider")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05))
                .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .help("Model provider")

            Menu {
                Button {
                    Task { await viewModel.selectModel("default") }
                } label: {
                    if viewModel.selectedModelID == "default" {
                        Label("Default", systemImage: "checkmark")
                    } else {
                        Text("Default")
                    }
                }

                if let provider = viewModel.selectedProvider, !provider.models.isEmpty {
                    Divider()
                    ForEach(provider.models) { model in
                        Button {
                            Task { await viewModel.selectModel(model.id) }
                        } label: {
                            if model.id == viewModel.selectedModelID {
                                Label(model.displayName, systemImage: "checkmark")
                            } else {
                                Text(model.displayName)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(modelLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05))
                .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .help("Model")
        }
    }

    private var modelLabel: String {
        guard viewModel.selectedModelID != "default" else { return "Default" }
        if let model = viewModel.selectedProvider?.models.first(where: {
            $0.id == viewModel.selectedModelID
        }) {
            return model.displayName
        }
        return viewModel.selectedModelID
    }
}
