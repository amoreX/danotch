import Foundation

struct LocalConversationRecord: Codable, Identifiable {
    let id: String
    var title: String
    var task: String
    var status: TaskStatus
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var toolCallsCount: Int
    var messages: [ChatMessage]
}

final class LocalConversationStore {
    // All reads/writes go through this serial queue. `upsert` is a
    // read-modify-write over the whole file and gets called synchronously from
    // the main actor on every tool_start/tool_result/text_flush/done WebSocket
    // event — during a busy agent run that's a full JSON decode+encode+disk
    // write on the main thread multiple times a second, which shows up as UI
    // stutter. Moving it to a background serial queue keeps the writes
    // ordered (no lost updates) without blocking the UI thread.
    private let ioQueue = DispatchQueue(label: "engineering.super.Perch.conversationstore", qos: .utility)

    private struct StoreFile: Codable {
        var conversations: [LocalConversationRecord]
    }

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let accountDataStore: AccountDataStore
    private var activeUserID: String?
    private var generation = 0

    init(accountDataStore: AccountDataStore = AccountDataStore()) {
        self.accountDataStore = accountDataStore
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func activate(userID: String?) {
        ioQueue.sync {
            activeUserID = userID
            generation += 1
        }
    }

    func loadAll() -> [LocalConversationRecord] {
        guard let url = currentStoreURL(),
              let data = try? Data(contentsOf: url),
              let file = try? decoder.decode(StoreFile.self, from: data) else {
            return []
        }
        return file.conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(id: String) -> LocalConversationRecord? {
        loadAll().first { $0.id == id }
    }

    /// Queues the read-modify-write on a background serial queue so callers
    /// (main actor) don't block on disk I/O. Writes for the same store are
    /// strictly ordered since they all funnel through `ioQueue`.
    func upsert(_ record: LocalConversationRecord) {
        let scheduledGeneration = ioQueue.sync { generation }
        ioQueue.async { [self] in
            guard scheduledGeneration == generation, activeUserID != nil else { return }
            var records = loadAll()
            if let idx = records.firstIndex(where: { $0.id == record.id }) {
                records[idx] = record
            } else {
                records.append(record)
            }
            save(records)
        }
    }

    func markInProgressInterrupted() {
        ioQueue.sync { [self] in
            guard activeUserID != nil else { return }
            var records = loadAll()
            var changed = false
            let now = Date()

            for idx in records.indices where records[idx].status.isInProgress {
                records[idx].status = .cancelled
                records[idx].updatedAt = now
                records[idx].completedAt = now
                records[idx].messages.append(ChatMessage(
                    id: UUID().uuidString,
                    role: "agent",
                    content: "Conversation interrupted because the app quit.",
                    toolName: nil,
                    draftCard: nil,
                    timestamp: now
                ))
                changed = true
            }

            if changed {
                save(records)
            }
        }
    }

    private func save(_ records: [LocalConversationRecord]) {
        do {
            guard let url = currentStoreURL() else { return }
            let file = StoreFile(conversations: records.sorted { $0.updatedAt > $1.updatedAt })
            let data = try encoder.encode(file)
            try accountDataStore.writeSecurely(data, to: url)
        } catch {
            print("[Perch] LocalConversationStore save failed: \(error.localizedDescription)")
        }
    }

    private func currentStoreURL() -> URL? {
        guard let activeUserID else { return nil }
        return try? accountDataStore.conversationsURL(for: activeUserID)
    }
}

private extension TaskStatus {
    var isInProgress: Bool {
        self == .running || self == .pending || self == .awaitingApproval
    }
}
