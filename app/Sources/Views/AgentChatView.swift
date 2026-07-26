import SwiftUI

// MARK: - Tool Name Formatter

private func toolCompletedText(_ name: String) -> String {
    let map: [String: String] = [
        "bash_execute": "Ran command",
        "web_search": "Searched web",
        "web_fetch": "Fetched page",
        "create_scheduled_task": "Created task",
        "list_scheduled_tasks": "Listed tasks",
        "update_scheduled_task": "Updated task",
        "delete_scheduled_task": "Deleted task",
        "gmail_search": "Searched Gmail",
        "gmail_read_email": "Read email",
        "gmail_create_draft": "Created draft",
        "gmail_send": "Sent email",
        "gmail_reply": "Replied to email",
        "notion_create_page": "Created Notion page",
        "notion_search": "Searched Notion",
        "GITHUB_CREATE_AN_ISSUE": "Created issue",
        "GITHUB_GET_AN_ISSUE": "Fetched issue",
        "GITHUB_LIST_REPOSITORY_ISSUES": "Listed issues",
        "GITHUB_CREATE_A_PULL_REQUEST": "Created PR",
        "GITHUB_GET_A_PULL_REQUEST": "Fetched PR",
        "GITHUB_LIST_PULL_REQUESTS": "Listed PRs",
        "GITHUB_MERGE_A_PULL_REQUEST": "Merged PR",
        "GITHUB_LIST_COMMITS": "Listed commits",
        "GITHUB_GET_REPOSITORY_CONTENT": "Read file",
        "GITHUB_CREATE_OR_UPDATE_FILE_CONTENTS": "Updated file",
        "GITHUB_SEARCH_REPOSITORIES": "Searched repos",
        "GITHUB_LIST_REPOSITORY_WORKFLOWS": "Listed workflows",
        "GITHUB_GET_A_WORKFLOW_RUN": "Checked workflow",
        "GITHUB_SEARCH_CODE": "Searched code",
        "calendar_list_events": "Checked calendar",
        "calendar_create_event": "Created event",
    ]
    return map[name] ?? name.replacingOccurrences(of: "_", with: " ").capitalized
}

private func toolIcon(_ name: String) -> String {
    if name == "bash_execute" { return "terminal" }
    if name.hasPrefix("web") { return "globe" }
    if name.contains("scheduled") { return "clock.arrow.2.circlepath" }
    if name.hasPrefix("gmail") { return "envelope" }
    if name.hasPrefix("notion") { return "doc.text" }
    if name.hasPrefix("GITHUB") { return "chevron.left.forwardslash.chevron.right" }
    if name.hasPrefix("calendar") { return "calendar" }
    if name.hasPrefix("slack") { return "number" }
    if name.hasPrefix("drive") { return "folder" }
    return "gearshape"
}

// MARK: - Agent Chat View

struct AgentChatView: View {
    @ObservedObject var viewModel: NotchViewModel
    let taskId: String

    @State private var autoScroll = true
    @State private var messageText: String = ""
    @FocusState private var isMessageFocused: Bool

    private let bottomAnchorId = "bottom-anchor"

    private var task: SubagentTask? {
        viewModel.taskById(taskId)
    }

    var body: some View {
        VStack(spacing: 10) {
            header

            if let task = task {
                chatBody(task)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }

            inputBar
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text("Back")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .perchGlass(in: Capsule())
            .contentShape(.capsule)
            .onTapGesture {
                withAnimation(DN.transition) {
                    viewModel.viewState = .taskList
                }
            }

            if let task = task {
                Text(task.description ?? task.task)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DN.textPrimary)
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    // MARK: - Chat Body

    private func chatBody(_ task: SubagentTask) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(task.chatHistory) { msg in
                        chatBubble(msg)
                    }

                    if task.status == .running && !task.streamingText.isEmpty {
                        StreamingMessage(text: task.streamingText)
                    }

                    if task.status == .running && task.streamingText.isEmpty {
                        ThinkingBubble()
                    }

                    Color.clear.frame(height: 1).id(bottomAnchorId)
                }
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
            .smartScrollFade(20, bottomRadius: 24)
            .onReceive(NotificationCenter.default.publisher(for: NSScrollView.willStartLiveScrollNotification)) { _ in
                autoScroll = false
            }
            .onChange(of: task.chatHistory.count) { _, _ in
                autoScroll = true
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: task.streamingText) { _, _ in
                if autoScroll { scrollToBottom(proxy, animated: false) }
            }
            .onAppear { scrollToBottom(proxy, animated: false) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(bottomAnchorId, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchorId, anchor: .bottom)
        }
    }

    // MARK: - Bubbles

    @ViewBuilder
    private func chatBubble(_ msg: ChatMessage) -> some View {
        switch msg.role {
        case "user":
            UserBubble(text: msg.content)

        case "agent":
            AgentBubble(text: msg.content)

        case "tool":
            ToolBubble(msg: msg)

        case "connection_request":
            // Render for every state — the bubble's own switch handles pending,
            // connecting, approved, and denied. Suppressing approved/denied here
            // hid the terminal outcome entirely.
            connectionRequestBubble(msg)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))

        case "draft":
            if let draft = msg.draftCard {
                DraftCardView(
                    draft: draft,
                    status: msg.toolOutput ?? "pending",
                    onApprove: { viewModel.approveDraftAction(msg.id) },
                    onReject: { viewModel.rejectDraftAction(msg.id) }
                )
            }

        case "local_execution_consent":
            if let card = msg.localExecutionCard {
                LocalExecutionConsentView(
                    card: card,
                    onChooseWorkspace: {
                        viewModel.chooseExecutionWorkspace(actionID: msg.id)
                    },
                    onToggle: {
                        viewModel.toggleExecutionConfirmation(
                            actionID: msg.id,
                            confirmation: $0
                        )
                    },
                    onApprove: {
                        viewModel.approveLocalExecution(actionID: msg.id)
                    },
                    onReject: {
                        viewModel.rejectLocalExecution(actionID: msg.id)
                    }
                )
            }

        default:
            EmptyView()
        }
    }

    // MARK: - Connection Request Bubble

    private func connectionRequestBubble(_ msg: ChatMessage) -> some View {
        let appType = msg.toolName ?? ""
        let displayName = msg.toolInput ?? appType
        let reason = msg.content
        let requestId = msg.id
        let statusRaw = msg.toolOutput ?? "pending"
        let status = ConnectionRequestStatus(rawValue: statusRaw) ?? .pending

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: appIcon(appType))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DN.warning)
                Text("CONNECTION REQUIRED")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1)
                    .foregroundColor(DN.warning)
            }

            Text("Connect ").font(.system(size: 12)).foregroundColor(DN.textPrimary)
                + Text(displayName).font(.system(size: 12, weight: .semibold)).foregroundColor(DN.textPrimary)
                + Text(" to continue").font(.system(size: 12)).foregroundColor(DN.textPrimary)

            Text(reason)
                .font(.system(size: 11))
                .foregroundColor(DN.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            switch status {
            case .pending:
                HStack(spacing: 8) {
                    Text("Connect")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 26)
                        .perchGlass(tint: DN.activeAccent, in: Capsule())
                        .contentShape(.capsule)
                        .onTapGesture { viewModel.approveConnectionRequest(requestId) }

                    Text("Deny")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 26)
                        .perchGlass(in: Capsule())
                        .contentShape(.capsule)
                        .onTapGesture { viewModel.denyConnectionRequest(requestId) }
                }

            case .connecting:
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 14, height: 14)
                    Text("Connecting \(displayName)…")
                        .font(.system(size: 10))
                        .foregroundColor(DN.warning)
                }

            case .approved:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(DN.success)
                    Text("\(displayName) connected")
                        .font(.system(size: 10))
                        .foregroundColor(DN.success)
                }

            case .denied:
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(DN.textDisabled)
                    Text("Connection denied")
                        .font(.system(size: 10))
                        .foregroundColor(DN.textDisabled)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DN.warning.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DN.warning.opacity(0.25), lineWidth: 1)
        )
    }

    private func appIcon(_ appType: String) -> String {
        switch appType {
        case "gmail": return "envelope.fill"
        case "googlecalendar": return "calendar"
        case "googledocs": return "doc.text.fill"
        case "github": return "chevron.left.forwardslash.chevron.right"
        default: return "app.connected.to.app.below.fill"
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            ChatModelSelectorView(viewModel: viewModel)

            TextField(
                "Message agent",
                text: $messageText
            )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .focused($isMessageFocused)
                .onSubmit { sendMessage() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            sendButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .perchGlass(in: Capsule())
        .contentShape(.capsule)
        .onTapGesture { isMessageFocused = true }
    }

    private var sendButton: some View {
        let enabled = !messageText.trimmingCharacters(in: .whitespaces).isEmpty
        return Image(systemName: "arrow.up")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .perchGlass(tint: enabled ? DN.activeAccent : nil, in: Circle())
            .opacity(enabled ? 1.0 : 0.55)
            .contentShape(.circle)
            .onTapGesture { if enabled { sendMessage() } }
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        messageText = ""
        viewModel.sendChat(message: text, sessionId: taskId)
    }
}

private struct LocalExecutionConsentView: View {
    let card: LocalExecutionConsentCard
    let onChooseWorkspace: () -> Void
    let onToggle: (LocalConsentConfirmation) -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "lock.shield")
                    .foregroundStyle(DN.warning)
                Text("LOCAL VM EXECUTION")
                    .font(DN.label(10))
                    .foregroundStyle(DN.textPrimary)
                Spacer()
                Text(card.state.rawValue.uppercased())
                    .font(DN.label(8))
                    .foregroundStyle(statusColor)
            }
            Text(card.command.map(shellQuote).joined(separator: " "))
                .font(DN.mono(10))
                .foregroundStyle(DN.textSecondary)
                .lineLimit(4)
                .textSelection(.enabled)

            consentLine(
                icon: card.workspaceMode == "read_only" ? "lock" : "pencil",
                text: card.workspaceMode == "read_only"
                    ? "Selected workspace snapshot: read-only"
                    : "Selected workspace snapshot: read/write"
            )
            consentLine(icon: "network.slash", text: "Network: entirely unavailable")
            consentLine(
                icon: card.sensitiveFileAccess ? "doc.badge.ellipsis" : "doc",
                text: card.sensitiveFileAccess
                    ? "Sensitive file reads requested"
                    : "Sensitive files are not approved"
            )
            consentLine(
                icon: card.sensitiveDisclosure ? "exclamationmark.triangle" : "eye.slash",
                text: card.sensitiveDisclosure
                    ? "Sensitive output may leave the VM"
                    : "Sensitive output is redacted"
            )
            consentLine(
                icon: card.resultUpload ? "arrow.up.circle" : "internaldrive",
                text: card.resultUpload
                    ? "Bounded result will be uploaded"
                    : "Execution output remains on this Mac"
            )

            Button(action: onChooseWorkspace) {
                HStack {
                    Image(systemName: "folder")
                    Text(card.selectedWorkspacePath ?? "SELECT WORKSPACE…")
                        .lineLimit(1)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .font(DN.label(9))
            .foregroundStyle(DN.textPrimary)
            .padding(8)
            .background(DN.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .disabled(card.state != .pending)

            ForEach(
                LocalConsentConfirmation.allCases.filter {
                    card.requiredConfirmations.contains($0)
                },
                id: \.self
            ) { confirmation in
                Button {
                    onToggle(confirmation)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: card.confirmations.contains(confirmation)
                            ? "checkmark.square.fill"
                            : "square")
                        Text(confirmationLabel(confirmation))
                            .font(DN.body(10))
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(card.confirmations.contains(confirmation)
                    ? DN.warning
                    : DN.textSecondary)
                .disabled(card.state != .pending)
            }

            if let error = card.error {
                Text(error)
                    .font(DN.body(9))
                    .foregroundStyle(DN.accent)
            }

            if card.state == .pending {
                HStack {
                    Button("DENY", action: onReject)
                        .buttonStyle(.plain)
                        .foregroundStyle(DN.textSecondary)
                    Spacer()
                    Button("RUN ONCE", action: onApprove)
                        .buttonStyle(.plain)
                        .foregroundStyle(card.canApprove ? DN.warning : DN.textDisabled)
                        .disabled(!card.canApprove)
                }
                .font(DN.label(9))
            }
        }
        .padding(12)
        .background(DN.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(DN.borderVisible, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusColor: Color {
        switch card.state {
        case .approved: return DN.success
        case .rejected, .failed, .unavailable: return DN.accent
        default: return DN.warning
        }
    }

    private func consentLine(icon: String, text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).frame(width: 12)
            Text(text)
        }
        .font(DN.body(9))
        .foregroundStyle(DN.textSecondary)
    }

    private func confirmationLabel(_ value: LocalConsentConfirmation) -> String {
        switch value {
        case .shell: return "Approve this exact shell command once"
        case .write: return "Allow writes to the disposable snapshot"
        case .sensitiveRead: return "Allow sensitive file reads for this action"
        case .sensitiveDisclosure: return "Allow sensitive output disclosure"
        case .resultUpload: return "Allow this bounded result upload"
        }
    }

    private func shellQuote(_ value: String) -> String {
        value.contains(" ") ? "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'" : value
    }
}

// MARK: - User bubble (right-aligned glass capsule)

private struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(DN.activeAccent.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
    }
}

// MARK: - Agent bubble (full width, plain content)

private struct AgentBubble: View {
    let text: String

    var body: some View {
        MarkdownView(text: text, isFinal: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Streaming message (character-fade in)

private struct StreamingMessage: View {
    let text: String

    var body: some View {
        MarkdownView(text: text, isFinal: false)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Thinking bubble

private struct ThinkingBubble: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 3
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(.white)
                        .frame(width: 5, height: 5)
                        .opacity(phase == i ? 1 : 0.3)
                        .scaleEffect(phase == i ? 1.0 : 0.85)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: phase)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .perchGlass(in: Capsule())
    }
}

// MARK: - Tool call bubble

private struct ToolBubble: View {
    let msg: ChatMessage
    @State private var expanded = false

    private var name: String { msg.toolName ?? "tool" }
    private var hasOutput: Bool { !(msg.toolOutput?.isEmpty ?? true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: toolIcon(name))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DN.accent.opacity(0.8))
                    .frame(width: 22, height: 22)
                    .perchGlass(in: Circle())

                Text(toolCompletedText(name))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)

                if let input = msg.toolInput, !input.isEmpty {
                    Text(input)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                }

                Spacer(minLength: 0)

                if hasOutput {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.35))
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                }
            }

            if expanded, let output = msg.toolOutput, !output.isEmpty {
                Text(output)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.5))
                    .padding(.top, 4)
                    .padding(.leading, 30)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .perchGlass(in: RoundedRectangle(cornerRadius: 12))
        .contentShape(.rect(cornerRadius: 12))
        .onTapGesture {
            guard hasOutput else { return }
            withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
        }
    }
}

// MARK: - Markdown Renderer

struct MarkdownView: View {
    let text: String
    let isFinal: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum MdBlock {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String)
        case code(String)
        case divider
    }

    private func parseBlocks() -> [MdBlock] {
        var blocks: [MdBlock] = []
        let lines = text.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeLines: [String] = []

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCodeBlock {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                }
                continue
            }
            if inCodeBlock {
                codeLines.append(line)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                continue
            }

            if trimmed.hasPrefix("### ") {
                blocks.append(.heading(3, String(trimmed.dropFirst(4))))
            } else if trimmed.hasPrefix("## ") {
                blocks.append(.heading(2, String(trimmed.dropFirst(3))))
            } else if trimmed.hasPrefix("# ") {
                blocks.append(.heading(1, String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
            } else if let match = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                blocks.append(.bullet(String(trimmed[match.upperBound...])))
            } else if trimmed == "---" || trimmed == "***" {
                blocks.append(.divider)
            } else {
                if case .paragraph(let prev) = blocks.last {
                    blocks[blocks.count - 1] = .paragraph(prev + " " + trimmed)
                } else {
                    blocks.append(.paragraph(trimmed))
                }
            }
        }

        if inCodeBlock && !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }

        return blocks
    }

    @ViewBuilder
    private func renderBlock(_ block: MdBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            let size: CGFloat = level == 1 ? 16 : level == 2 ? 14 : 13
            renderInline(text)
                .font(.system(size: size, weight: .semibold, design: .default))
                .foregroundColor(DN.textDisplay)
                .padding(.top, 2)

        case .paragraph(let text):
            renderInline(text)
                .font(.system(size: 13))
                .foregroundColor(DN.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let text):
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(DN.textDisabled)
                    .frame(width: 4, height: 4)
                    .padding(.top, 7)

                renderInline(text)
                    .font(.system(size: 13))
                    .foregroundColor(DN.textPrimary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .code(let code):
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DN.textPrimary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )

        case .divider:
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func renderInline(_ text: String) -> Text {
        var result = Text("")
        var remaining = text[text.startIndex...]

        while !remaining.isEmpty {
            if remaining.hasPrefix("`"), let end = remaining.dropFirst().firstIndex(of: "`") {
                let code = remaining[remaining.index(after: remaining.startIndex)..<end]
                result = result + Text(String(code))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(DN.claudeOrange)
                remaining = remaining[remaining.index(after: end)...]
            } else if remaining.hasPrefix("**"), let end = remaining.dropFirst(2).range(of: "**") {
                let bold = remaining[remaining.index(remaining.startIndex, offsetBy: 2)..<end.lowerBound]
                result = result + Text(String(bold)).bold()
                remaining = remaining[end.upperBound...]
            } else if remaining.hasPrefix("*"), let end = remaining.dropFirst().firstIndex(of: "*") {
                let italic = remaining[remaining.index(after: remaining.startIndex)..<end]
                result = result + Text(String(italic)).italic()
                remaining = remaining[remaining.index(after: end)...]
            } else {
                if let next = remaining.firstIndex(where: { $0 == "*" || $0 == "`" }) {
                    result = result + Text(String(remaining[remaining.startIndex..<next]))
                    remaining = remaining[next...]
                } else {
                    result = result + Text(String(remaining))
                    break
                }
            }
        }

        return result
    }
}

// MARK: - Streaming Text shim (preserves callers)

struct StreamingTextView: View {
    let text: String

    var body: some View {
        StreamingMessage(text: text)
    }
}

// MARK: - Draft Card

struct DraftCardView: View {
    let draft: DraftCard
    var status: String = "pending"
    var onApprove: () -> Void = {}
    var onReject: () -> Void = {}

    private var icon: String {
        switch draft.type {
        case "gmail_draft": return "envelope"
        case "slack_message": return "number"
        default: return "doc"
        }
    }

    private var typeLabel: String {
        switch draft.type {
        case "gmail_draft": return "EMAIL DRAFT"
        case "slack_message": return "SLACK MESSAGE"
        default: return "DRAFT"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(DN.textDisabled)

                Text(typeLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1)
                    .foregroundColor(DN.textDisabled)

                Spacer()

                if let recipient = draft.recipient {
                    Text(recipient)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(DN.textDisabled)
                }
            }

            Text(draft.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DN.textPrimary)

            Text(draft.preview)
                .font(.system(size: 11))
                .foregroundColor(DN.textSecondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            draftActions
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(cornerRadius: 14)
    }

    @ViewBuilder
    private var draftActions: some View {
        switch status {
        case "pending":
            HStack(spacing: 8) {
                Spacer()
                Text("Reject")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .perchGlass(in: Capsule())
                    .contentShape(.capsule)
                    .onTapGesture { onReject() }

                Text("Approve")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .perchGlass(tint: DN.activeAccent, in: Capsule())
                    .contentShape(.capsule)
                    .onTapGesture { onApprove() }
            }
        case "executing":
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.55).frame(width: 14, height: 14)
                Text("Running…").font(.system(size: 10)).foregroundColor(DN.warning)
            }
        case "completed":
            statusLine(icon: "checkmark.circle.fill", color: DN.success, text: "Done")
        case "rejected":
            statusLine(icon: "xmark.circle.fill", color: DN.textDisabled, text: "Rejected")
        default:
            statusLine(icon: "exclamationmark.triangle.fill", color: DN.accent, text: "Failed — try again")
        }
    }

    private func statusLine(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(color)
            Text(text).font(.system(size: 10)).foregroundColor(color)
        }
    }
}
