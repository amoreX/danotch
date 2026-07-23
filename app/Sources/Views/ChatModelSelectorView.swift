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

    private var trialUsage: TrialUsageSummary? {
        guard let status = viewModel.billingStatus,
              status.billingStatus == .trialing,
              status.canUseServerKey else { return nil }
        return status.trialUsage
    }

    var body: some View {
        Group {
            if let trialUsage {
                TrialUsageMeterView(usage: trialUsage, maxWidth: maxWidth)
            } else {
                modelSelector
            }
        }
        .onAppear {
            if trialUsage != nil {
                viewModel.loadBillingStatus()
            } else if viewModel.modelOptions.isEmpty {
                viewModel.loadProviderModels()
            }
        }
        .task(id: trialUsage != nil) {
            guard trialUsage != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                viewModel.loadBillingStatus()
                viewModel.loadScheduledTasks()
            }
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
                            Image(systemName: "check")
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

private struct TrialUsageMeterView: View {
    let usage: TrialUsageSummary
    let maxWidth: CGFloat

    private var meterColor: Color {
        if usage.dailyLimitReached { return DN.accent }
        if usage.dailyUsageFraction >= 0.9 { return DN.accent }
        if usage.dailyUsageFraction >= 0.7 { return DN.warning }
        return DN.success
    }

    private var displayedFraction: Double {
        usage.dailyLimitReached ? 1 : usage.dailyUsageFraction
    }

    private var resetLabel: String {
        usage.resetDate?.formatted(date: .omitted, time: .shortened) ?? "tomorrow"
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Text(String(format: "$%.2f", usage.dailySpendDollars))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 2)
                Text(usage.dailyLimitReached ? "LIMIT" : "/ $\(Int(usage.dailyLimitDollars))")
                    .foregroundStyle(usage.dailyLimitReached ? DN.accent : .secondary)
            }
            .font(.system(size: 8, weight: .semibold, design: .monospaced))

            GeometryReader { proxy in
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(meterColor)
                            .frame(width: proxy.size.width * displayedFraction)
                    }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 8)
        .frame(width: maxWidth, height: 26)
        .perchGlass(in: Capsule())
        .help(usage.dailyLimitReached
            ? "Daily $5 trial limit reached. Chat and scheduled tasks resume automatically at \(resetLabel)."
            : String(
                format: "Today: $%.2f of $%.2f across %d requests. Trial total: $%.2f across %d requests. Includes chat and scheduled tasks.",
                usage.dailySpendDollars,
                usage.dailyLimitDollars,
                usage.dailyRequests,
                usage.totalSpendDollars,
                usage.totalRequests
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily trial usage")
        .accessibilityValue(
            usage.dailyLimitReached
                ? "Daily limit reached. Resumes automatically at \(resetLabel)."
                : String(
                format: "$%.2f used of $%.2f",
                usage.dailySpendDollars,
                usage.dailyLimitDollars
            )
        )
    }
}
