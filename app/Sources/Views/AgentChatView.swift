import SwiftUI

// MARK: - Tool Name Formatter

private func toolActionText(_ name: String) -> String {
    let map: [String: String] = [
        "gmail_search": "Searching Gmail",
        "gmail_read_email": "Reading email",
        "gmail_create_draft": "Creating draft",
        "gmail_send": "Sending email",
        "gmail_reply": "Replying to email",
        "notion_create_page": "Creating Notion page",
        "notion_append_block": "Updating Notion page",
        "notion_search": "Searching Notion",
        "linear_list_issues": "Fetching Linear issues",
        "linear_update_issue": "Updating Linear issue",
        "linear_add_comment": "Adding comment on Linear",
        "linear_create_issue": "Creating Linear issue",
        "calendar_list_events": "Checking calendar",
        "calendar_create_event": "Creating event",
        "slack_send_message": "Sending Slack message",
        "slack_search": "Searching Slack",
        "web_search": "Searching the web",
        "drive_search": "Searching Drive",
    ]
    return map[name] ?? name.replacingOccurrences(of: "_", with: " ").capitalized
}

private func toolCompletedText(_ name: String) -> String {
    let map: [String: String] = [
        "gmail_search": "Searched Gmail",
        "gmail_read_email": "Read email",
        "gmail_create_draft": "Created draft",
        "gmail_send": "Sent email",
        "gmail_reply": "Replied to email",
        "notion_create_page": "Created Notion page",
        "notion_append_block": "Updated Notion page",
        "notion_search": "Searched Notion",
        "linear_list_issues": "Fetched Linear issues",
        "linear_update_issue": "Updated Linear issue",
        "linear_add_comment": "Added comment on Linear",
        "linear_create_issue": "Created Linear issue",
        "calendar_list_events": "Checked calendar",
        "calendar_create_event": "Created event",
        "slack_send_message": "Sent Slack message",
        "slack_search": "Searched Slack",
        "web_search": "Searched the web",
        "drive_search": "Searched Drive",
    ]
    return map[name] ?? name.replacingOccurrences(of: "_", with: " ").capitalized
}

private func toolIcon(_ name: String) -> String {
    if name.hasPrefix("gmail") { return "envelope" }
    if name.hasPrefix("notion") { return "doc.text" }
    if name.hasPrefix("linear") { return "checklist" }
    if name.hasPrefix("calendar") { return "calendar" }
    if name.hasPrefix("slack") { return "number" }
    if name.hasPrefix("web") { return "globe" }
    if name.hasPrefix("drive") { return "folder" }
    return "gearshape"
}

// MARK: - Agent Chat View

struct AgentChatView: View {
    @ObservedObject var viewModel: NotchViewModel
    let taskId: String

    private var task: SubagentTask? {
        viewModel.taskById(taskId)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer().frame(height: DN.spaceSM)

            if let task = task {
                chatBody(task)
            }

            Spacer().frame(height: DN.spaceSM)
            inputBar
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DN.spaceSM) {
            Button(action: {
                withAnimation(DN.transition) {
                    viewModel.viewState = .taskList
                }
            }) {
                Text("<")
                    .font(DN.mono(12, weight: .medium))
                    .foregroundColor(DN.textSecondary)
            }
            .buttonStyle(.plain)

            if let task = task {
                Circle()
                    .fill(DN.statusColor(task.status))
                    .frame(width: 6, height: 6)

                Text(task.description ?? task.task)
                    .font(DN.body(12, weight: .medium))
                    .foregroundColor(DN.textPrimary)
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    // MARK: - Chat Body

    @State private var autoScroll = true
    @State private var scrollTarget: String? = nil
    private let bottomAnchorId = "bottom-anchor"

    private func chatBody(_ task: SubagentTask) -> some View {
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: DN.spaceXS) {
                    ForEach(task.chatHistory) { msg in
                        chatBubble(msg)
                    }

                    // Streaming text
                    if task.status == .running && !task.streamingText.isEmpty {
                        StreamingTextView(text: task.streamingText)
                    }

                    if task.status == .running && task.streamingText.isEmpty {
                        typingIndicator
                    }

                    Color.clear.frame(height: 1).id(bottomAnchorId)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSScrollView.willStartLiveScrollNotification)) { _ in
                autoScroll = false
            }
            .onChange(of: task.chatHistory.count) { _, _ in
                autoScroll = true
                scrollToBottom(proxy)
            }
            .onChange(of: task.streamingText) { _, _ in
                if autoScroll { scrollToBottom(proxy) }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(bottomAnchorId, anchor: .bottom)
        }
    }

    private var typingIndicator: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(DN.textDisabled)
                    .frame(width: 4, height: 4)
                    .opacity(typingDotOpacity(i))
            }
        }
        .padding(.vertical, DN.spaceSM)
        .onAppear { autoScroll = true }
    }

    @State private var typingPhase = false

    private func typingDotOpacity(_ index: Int) -> Double {
        // Simple staggered pulse
        let base = typingPhase ? 1.0 : 0.3
        switch index {
        case 0: return typingPhase ? 1.0 : 0.3
        case 1: return 0.6
        case 2: return typingPhase ? 0.3 : 1.0
        default: return base
        }
    }

    @ViewBuilder
    private func chatBubble(_ msg: ChatMessage) -> some View {
        switch msg.role {
        case "user":
            HStack {
                Spacer()
                Text(msg.content)
                    .font(DN.body(11, weight: .medium))
                    .foregroundColor(DN.textPrimary)
                    .padding(.horizontal, DN.spaceSM + DN.spaceXS)
                    .padding(.vertical, DN.spaceXS + 1)
                    .background(DN.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(DN.borderVisible, lineWidth: 1)
                    )
            }
            .padding(.vertical, DN.space2xs)

        case "agent":
            MarkdownView(text: msg.content, isFinal: true)
                .padding(.vertical, DN.spaceXS)

        case "tool":
            toolCallBubble(msg)

        case "draft":
            if let draft = msg.draftCard {
                DraftCardView(draft: draft)
            }

        default:
            EmptyView()
        }
    }

    private func toolCallBubble(_ msg: ChatMessage) -> some View {
        let name = msg.toolName ?? "tool"
        return HStack(spacing: DN.spaceXS + DN.space2xs) {
            Text("\u{2713}")
                .font(DN.mono(8, weight: .bold))
                .foregroundColor(DN.success)

            Image(systemName: toolIcon(name))
                .font(.system(size: 9, weight: .regular))
                .foregroundColor(DN.textDisabled)

            Text(toolCompletedText(name))
                .font(DN.mono(10))
                .foregroundColor(DN.textSecondary)

            if !msg.content.isEmpty {
                Text("\u{00B7}")
                    .foregroundColor(DN.textDisabled)
                Text(msg.content)
                    .font(DN.body(10))
                    .foregroundColor(DN.textDisabled)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: - Input Bar

    @State private var messageText: String = ""

    private var inputBar: some View {
        HStack(spacing: DN.spaceSM) {
            Image(systemName: "sparkle")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(DN.textDisabled)

            TextField("", text: $messageText, prompt: Text("Message agent...")
                .font(DN.body(11))
                .foregroundColor(DN.textDisabled)
            )
            .textFieldStyle(.plain)
            .font(DN.body(11))
            .foregroundColor(DN.textPrimary)
            .onSubmit { sendMessage() }

            if !messageText.isEmpty {
                Button(action: { sendMessage() }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(DN.black)
                        .frame(width: 18, height: 18)
                        .background(DN.textDisplay)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, DN.spaceSM + DN.spaceXS)
        .padding(.vertical, DN.spaceXS + 2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DN.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DN.border, lineWidth: 1)
        )
        .animation(.easeOut(duration: DN.microDuration), value: messageText.isEmpty)
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        messageText = ""
        viewModel.sendChat(message: text, sessionId: taskId)
    }
}

// MARK: - Streaming Text View

struct StreamingTextView: View {
    let text: String
    @State private var cursorVisible = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarkdownView(text: text, isFinal: true)

            // Blinking cursor
            Rectangle()
                .fill(DN.textPrimary)
                .frame(width: 1.5, height: 13)
                .opacity(cursorVisible ? 1 : 0)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DN.spaceXS)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                cursorVisible.toggle()
            }
        }
    }
}

// MARK: - Markdown Renderer

struct MarkdownView: View {
    let text: String
    let isFinal: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DN.spaceXS) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum MdBlock {
        case heading(Int, String) // level, text
        case paragraph(String)
        case bullet(String)
        case code(String) // code block content
        case divider
    }

    private func parseBlocks() -> [MdBlock] {
        var blocks: [MdBlock] = []
        let lines = text.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeLines: [String] = []

        for line in lines {
            // Code blocks
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

            // Headings
            if trimmed.hasPrefix("### ") {
                blocks.append(.heading(3, String(trimmed.dropFirst(4))))
            } else if trimmed.hasPrefix("## ") {
                blocks.append(.heading(2, String(trimmed.dropFirst(3))))
            } else if trimmed.hasPrefix("# ") {
                blocks.append(.heading(1, String(trimmed.dropFirst(2))))
            }
            // Bullets
            else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
            }
            // Numbered lists
            else if let match = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                blocks.append(.bullet(String(trimmed[match.upperBound...])))
            }
            // Divider
            else if trimmed == "---" || trimmed == "***" {
                blocks.append(.divider)
            }
            // Paragraph
            else {
                // Merge consecutive paragraph lines
                if case .paragraph(let prev) = blocks.last {
                    blocks[blocks.count - 1] = .paragraph(prev + " " + trimmed)
                } else {
                    blocks.append(.paragraph(trimmed))
                }
            }
        }

        // Close unclosed code block
        if inCodeBlock && !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }

        return blocks
    }

    @ViewBuilder
    private func renderBlock(_ block: MdBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            let size: CGFloat = level == 1 ? 14 : level == 2 ? 12 : 11
            renderInline(text)
                .font(.system(size: size, weight: .semibold, design: .default))
                .foregroundColor(DN.textDisplay)

        case .paragraph(let text):
            renderInline(text)
                .font(DN.body(isFinal ? 12 : 11))
                .foregroundColor(isFinal ? DN.textPrimary : DN.textSecondary)

        case .bullet(let text):
            HStack(alignment: .top, spacing: DN.spaceSM) {
                Text("\u{2022}")
                    .font(DN.body(12, weight: .bold))
                    .foregroundColor(DN.textDisabled)
                    .frame(width: 8)

                renderInline(text)
                    .font(DN.body(isFinal ? 12 : 11))
                    .foregroundColor(isFinal ? DN.textPrimary : DN.textSecondary)
            }

        case .code(let code):
            Text(code)
                .font(DN.mono(10))
                .foregroundColor(DN.textPrimary)
                .padding(DN.spaceSM)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DN.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(DN.border, lineWidth: 1)
                )

        case .divider:
            Rectangle()
                .fill(DN.border)
                .frame(height: 1)
                .padding(.vertical, DN.space2xs)
        }
    }

    private func renderInline(_ text: String) -> Text {
        // Parse inline markdown: **bold**, *italic*, `code`
        var result = Text("")
        var remaining = text[text.startIndex...]

        while !remaining.isEmpty {
            // Inline code: `...`
            if remaining.hasPrefix("`"), let end = remaining.dropFirst().firstIndex(of: "`") {
                let code = remaining[remaining.index(after: remaining.startIndex)..<end]
                result = result + Text(String(code))
                    .font(DN.mono(11))
                    .foregroundColor(Color(hex: 0xD97757))
                remaining = remaining[remaining.index(after: end)...]
            }
            // Bold: **...**
            else if remaining.hasPrefix("**"), let end = remaining.dropFirst(2).range(of: "**") {
                let bold = remaining[remaining.index(remaining.startIndex, offsetBy: 2)..<end.lowerBound]
                result = result + Text(String(bold)).bold()
                remaining = remaining[end.upperBound...]
            }
            // Italic: *...*
            else if remaining.hasPrefix("*"), let end = remaining.dropFirst().firstIndex(of: "*") {
                let italic = remaining[remaining.index(after: remaining.startIndex)..<end]
                result = result + Text(String(italic)).italic()
                remaining = remaining[remaining.index(after: end)...]
            }
            // Plain text until next marker
            else {
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

// MARK: - Draft Card

struct DraftCardView: View {
    let draft: DraftCard

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
        VStack(alignment: .leading, spacing: DN.spaceSM) {
            // Header
            HStack(spacing: DN.spaceSM) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(DN.textDisabled)

                Text(typeLabel)
                    .font(DN.label(9))
                    .tracking(1)
                    .foregroundColor(DN.textDisabled)

                Spacer()

                if let recipient = draft.recipient {
                    Text(recipient)
                        .font(DN.mono(10))
                        .foregroundColor(DN.textDisabled)
                }
            }

            // Title — secondary prominence
            Text(draft.title)
                .font(DN.body(12, weight: .medium))
                .foregroundColor(DN.textPrimary)

            // Preview
            Text(draft.preview)
                .font(DN.body(11))
                .foregroundColor(DN.textSecondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            // Actions
            HStack(spacing: DN.spaceSM) {
                Spacer()

                Button(action: {}) {
                    Text("REJECT")
                        .font(DN.label(10))
                        .tracking(0.8)
                        .foregroundColor(DN.accent)
                        .padding(.horizontal, DN.spaceMD)
                        .padding(.vertical, DN.spaceXS + DN.space2xs)
                        .overlay(
                            RoundedRectangle(cornerRadius: 999)
                                .stroke(DN.accent.opacity(0.4), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button(action: {}) {
                    Text("APPROVE")
                        .font(DN.label(10))
                        .tracking(0.8)
                        .foregroundColor(DN.black)
                        .padding(.horizontal, DN.spaceMD)
                        .padding(.vertical, DN.spaceXS + DN.space2xs)
                        .background(DN.textDisplay)
                        .clipShape(RoundedRectangle(cornerRadius: 999))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DN.spaceSM + DN.spaceXS)
        .background(DN.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(DN.border, lineWidth: 1)
        )
    }
}
