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
    private static let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".danotch")
    private static let storeFile = configDir.appendingPathComponent("conversations.json")

    // All reads/writes go through this serial queue. `upsert` is a
    // read-modify-write over the whole file and gets called synchronously from
    // the main actor on every tool_start/tool_result/text_flush/done WebSocket
    // event — during a busy agent run that's a full JSON decode+encode+disk
    // write on the main thread multiple times a second, which shows up as UI
    // stutter. Moving it to a background serial queue keeps the writes
    // ordered (no lost updates) without blocking the UI thread.
    private static let ioQueue = DispatchQueue(label: "com.danotch.conversationstore", qos: .utility)

    private struct StoreFile: Codable {
        var conversations: [LocalConversationRecord]
    }

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadAll() -> [LocalConversationRecord] {
        guard let data = try? Data(contentsOf: Self.storeFile),
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
        Self.ioQueue.async { [self] in
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
        Self.ioQueue.sync { [self] in
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
            try FileManager.default.createDirectory(at: Self.configDir, withIntermediateDirectories: true, attributes: nil)
            let file = StoreFile(conversations: records.sorted { $0.updatedAt > $1.updatedAt })
            let data = try encoder.encode(file)
            try data.write(to: Self.storeFile, options: [.atomic])
        } catch {
            print("[Perch] LocalConversationStore save failed: \(error.localizedDescription)")
        }
    }
}

private extension TaskStatus {
    var isInProgress: Bool {
        self == .running || self == .pending || self == .awaitingApproval
    }
}
