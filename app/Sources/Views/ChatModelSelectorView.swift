import SwiftUI

struct ChatModelSelectorView: View {
    @ObservedObject var viewModel: NotchViewModel

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
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 26, height: 26)
                .perchGlass(in: Circle())
                .contentShape(.circle)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .help("Choose model")
    }
}
