import SwiftUI

struct ChatModelSelectorView: View {
    @ObservedObject var viewModel: NotchViewModel
    var maxWidth: CGFloat = 128

    private var selectedModel: ProviderModelOption? {
        viewModel.modelOptions.first { $0.id == viewModel.settings.selectedDefaultModel }
    }

    private var providerLabel: String {
        switch viewModel.activeModelProvider {
        case "openrouter": return "OR"
        case "openai": return "OA"
        case "anthropic": return "AN"
        default: return viewModel.activeModelProvider.prefix(2).uppercased()
        }
    }

    var body: some View {
        modelSelector
        .onAppear {
            // Provider state in the daemon is authoritative. Refresh it before
            // presenting models so a newly saved DeepSeek/OpenAI configuration
            // cannot briefly fall back to Anthropic.
            viewModel.loadProviderConfigs()
        }
    }

    private var modelSelector: some View {
        Menu {
            if viewModel.isLoadingModels {
                Text("Loading models...")
            }

            if let error = viewModel.modelListError, !error.isEmpty {
                Text(error)
            }

            ForEach(viewModel.modelOptions) { model in
                Button {
                    viewModel.selectModel(model.id)
                } label: {
                    HStack {
                        if model.id == viewModel.settings.selectedDefaultModel {
                            Image(systemName: "checkmark")
                        }
                        Text(model.displayName)
                        if let context = model.contextLength {
                            Text("\(context / 1000)k")
                        }
                    }
                }
            }

            Divider()

            Button("Refresh models") {
                viewModel.loadProviderModels()
            }
        } label: {
            HStack(spacing: 5) {
                Text(providerLabel)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(DN.activeAccent)
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(
                        Capsule()
                            .fill(DN.activeAccent.opacity(0.16))
                    )

                Text(shortName(selectedModel?.displayName ?? viewModel.settings.selectedDefaultModel))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DN.success)

                if viewModel.isLoadingModels {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.55)
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .frame(width: maxWidth, height: 26)
            .perchGlass(in: Capsule())
            .contentShape(.capsule)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func shortName(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "anthropic/", with: "")
            .replacingOccurrences(of: "openai/", with: "")
            .replacingOccurrences(of: "google/", with: "")
            .replacingOccurrences(of: "Claude ", with: "")
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "-latest", with: "")
    }
}
