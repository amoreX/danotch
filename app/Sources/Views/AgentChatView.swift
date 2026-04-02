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

    private func chatBody(_ task: SubagentTask) -> some View {
        let lastAgentMsgId = task.chatHistory.last(where: { $0.role == "agent" })?.id

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: DN.spaceXS) {
                ForEach(task.chatHistory) { msg in
                    chatBubble(msg, isFinalResponse: msg.id == lastAgentMsgId)
                }

                if task.status == .running {
                    liveActivityBar(task)
                }
            }
        }
    }

    private func liveActivityBar(_ task: SubagentTask) -> some View {
        HStack(spacing: DN.spaceSM) {
            // Mechanical dots
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(DN.warning)
                        .frame(width: 3, height: 3)
                }
            }

            Text(viewModel.activityText(for: task).uppercased())
                .font(DN.label(9))
                .tracking(0.6)
                .foregroundColor(DN.warning.opacity(0.7))
                .lineLimit(1)
        }
        .padding(.vertical, DN.spaceXS)
        .padding(.horizontal, DN.spaceSM)
        .background(DN.surface)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(DN.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func chatBubble(_ msg: ChatMessage, isFinalResponse: Bool) -> some View {
        switch msg.role {
        case "agent":
            if isFinalResponse {
                Text(msg.content)
                    .font(DN.body(12, weight: .medium))
                    .foregroundColor(DN.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, DN.spaceXS)
            } else {
                Text(msg.content)
                    .font(DN.body(11))
                    .foregroundColor(DN.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, DN.space2xs)
            }

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

    private var inputBar: some View {
        HStack(spacing: DN.spaceSM) {
            Text("MESSAGE AGENT...")
                .font(DN.label(9))
                .tracking(0.6)
                .foregroundColor(DN.textDisabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.up")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DN.textDisabled)
                .frame(width: 20, height: 20)
                .overlay(
                    Circle().stroke(DN.borderVisible, lineWidth: 1)
                )
        }
        .padding(.horizontal, DN.spaceSM + DN.spaceXS)
        .padding(.vertical, DN.spaceSM)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(DN.border, lineWidth: 1)
        )
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
