import SwiftUI

struct QuickPromptView: View {
    @ObservedObject var viewModel: NotchViewModel
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            ChatModelSelectorView(viewModel: viewModel, maxWidth: 112)

            TextField("Ask Perch anything…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .focused($isFocused)
                .onSubmit { submit() }
                .layoutPriority(1)

            sendButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .perchGlass(in: Capsule())
        .contentShape(.capsule)
        .onTapGesture { isFocused = true }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isFocused = true
            }
        }
        .onChange(of: isFocused) { _, focused in
            viewModel.isChatInputActive = focused
        }
        .onChange(of: viewModel.shouldFocusChatInput) { _, shouldFocus in
            if shouldFocus {
                isFocused = true
                viewModel.shouldFocusChatInput = false
            }
        }
    }

    private var sendButton: some View {
        let enabled = !text.trimmingCharacters(in: .whitespaces).isEmpty
        return Image(systemName: "arrow.up")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .perchGlass(tint: enabled ? DN.activeAccent : nil, in: Circle())
            .opacity(enabled ? 1 : 0.55)
            .contentShape(.circle)
            .onTapGesture { if enabled { submit() } }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        text = ""
        isFocused = false
        withAnimation(DN.expandSpring) {
            viewModel.isQuickPrompt = false
        }
        viewModel.sendChat(message: trimmed)
    }
}

// MARK: - Top-bar hint pills shown beside the notch during quick prompt mode

struct QuickPromptHintBar: View {
    var body: some View {
        HStack(spacing: 8) {
            hint(key: "Enter", caption: "to send")
            hint(key: "Esc", caption: "to dismiss")
        }
    }

    private func hint(key: String, caption: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(height: 16)
                .perchGlass(in: Capsule())
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}
