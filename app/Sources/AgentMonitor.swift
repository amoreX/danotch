import Foundation
import SwiftUI
import AppKit
import Darwin

class AgentMonitor: ObservableObject {
    @Published var agents: [DetectedAgent] = []

    var groupedAgents: [AgentGroup] {
        let grouped = Dictionary(grouping: agents, by: { $0.type })
        return AgentType.allCases.compactMap { type in
            guard let list = grouped[type], !list.isEmpty else { return nil }
            return AgentGroup(id: type.rawValue, type: type, agents: list)
        }
    }

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let detected = Self.scanAgents()
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.2)) {
                    self?.agents = detected
                }
            }
        }
    }

    // MARK: - Activate App

    func activateAgent(_ agent: DetectedAgent) {
        switch agent.type {
        case .claudeCode:
            let termApps = ["com.mitchellh.ghostty", "com.googlecode.iterm2", "net.kovidgoyal.kitty", "com.apple.Terminal"]
            activateApp(bundleIds: termApps, names: [])
        default:
            break
        }
    }

    private func activateApp(bundleIds: [String], names: [String]) {
        for bid in bundleIds {
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }) {
                app.activate()
                return
            }
        }
        for name in names {
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
                app.activate()
                return
            }
        }
    }

    // MARK: - Process Scanning

    private static func scanAgents() -> [DetectedAgent] {
        let lines = runPS()
        var agents: [DetectedAgent] = []
        var seenTypes: Set<String> = []

        for line in lines {
            guard let parsed = parsePSLine(line) else { continue }

            // Claude Code
            if parsed.command.contains("/claude") && parsed.args.contains("--session-id") {
                let sessionId = extractFlag(from: parsed.args, flag: "--session-id")
                let key = "claude-\(parsed.pid)"
                if !seenTypes.contains(key) {
                    seenTypes.insert(key)
                    agents.append(DetectedAgent(
                        id: key, type: .claudeCode, pid: parsed.pid,
                        status: parsed.cpu > 1.0 ? .running : .idle,
                        cpu: parsed.cpu, memMB: parsed.memMB, elapsed: parsed.elapsed,
                        workingDirectory: nil, sessionInfo: sessionId,
                        appPath: nil, lastPrompt: nil, lastActivityTime: nil, liveState: .idle, liveDetail: nil
                    ))
                }
            }

        }

        // Enrich Claude Code sessions with cwd, project name, and last prompt
        enrichClaudeSessions(&agents)

        // Sort by most recently active first (stable within same time)
        return agents.sorted { a, b in
            let aTime = a.lastActivityTime ?? .distantPast
            let bTime = b.lastActivityTime ?? .distantPast
            if aTime != bTime { return aTime > bTime }
            return a.pid < b.pid
        }
    }

    // MARK: - Claude Code Session Enrichment

    private static func enrichClaudeSessions(_ agents: inout [DetectedAgent]) {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let sessionsDir = claudeDir.appendingPathComponent("sessions")
        let projectsDir = claudeDir.appendingPathComponent("projects")

        for i in agents.indices where agents[i].type == .claudeCode {
            let pid = agents[i].pid

            // Read session file: ~/.claude/sessions/{pid}.json
            let sessionFile = sessionsDir.appendingPathComponent("\(pid).json")
            var cwd: String?
            var sessionId: String?

            if let data = try? Data(contentsOf: sessionFile),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                cwd = json["cwd"] as? String
                sessionId = json["sessionId"] as? String
            }

            // Fallback: get cwd via lsof if not in session file
            if cwd == nil {
                cwd = getCwd(pid: pid)
            }

            let projectName = cwd?.components(separatedBy: "/").last

            // Read last prompt, activity time, and live state from conversation JSONL
            var lastPrompt: String?
            var lastActivityTime: Date?
            var liveState: AgentLiveState = .idle
            var liveDetail: String?
            if let sid = sessionId ?? agents[i].sessionInfo {
                let result = readSessionState(projectsDir: projectsDir, sessionId: sid)
                lastPrompt = result.prompt
                lastActivityTime = result.modTime
                liveState = result.liveState
                liveDetail = result.liveDetail

                // If CPU is near zero, the process isn't actually doing anything —
                // override stale JSONL state to waitingForUser
                if agents[i].cpu < 0.5 && liveState != .idle && liveState != .waitingForUser {
                    liveState = .waitingForUser
                    liveDetail = nil
                }
            }

            agents[i] = DetectedAgent(
                id: agents[i].id, type: agents[i].type, pid: agents[i].pid,
                status: agents[i].status, cpu: agents[i].cpu,
                memMB: agents[i].memMB, elapsed: agents[i].elapsed,
                workingDirectory: cwd,
                sessionInfo: projectName,
                appPath: agents[i].appPath,
                lastPrompt: lastPrompt,
                lastActivityTime: lastActivityTime,
                liveState: liveState,
                liveDetail: liveDetail
            )
        }
    }

    struct SessionState {
        let prompt: String?
        let modTime: Date?
        let liveState: AgentLiveState
        let liveDetail: String?
    }

    private static func readSessionState(projectsDir: URL, sessionId: String) -> SessionState {
        let empty = SessionState(prompt: nil, modTime: nil, liveState: .idle, liveDetail: nil)
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil
        ) else { return empty }

        for dir in projectDirs {
            let jsonlFile = dir.appendingPathComponent("\(sessionId).jsonl")
            guard FileManager.default.fileExists(atPath: jsonlFile.path) else { continue }

            let modTime = (try? FileManager.default.attributesOfItem(atPath: jsonlFile.path))?[.modificationDate] as? Date

            guard let handle = try? FileHandle(forReadingFrom: jsonlFile) else { continue }
            let fileSize = handle.seekToEndOfFile()
            let readSize: UInt64 = min(fileSize, 200_000)
            handle.seek(toFileOffset: fileSize - readSize)
            let tailData = handle.readDataToEndOfFile()
            handle.closeFile()

            guard let tail = String(data: tailData, encoding: .utf8) else { continue }
            let lines = tail.components(separatedBy: "\n")

            // Determine live state and detail from the last few entries
            let (liveState, liveDetail) = parseLiveState(from: lines)

            // Find last user prompt (search in reverse)
            var prompt: String?
            for line in lines.reversed() {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["type"] as? String == "user",
                      let msg = json["message"] as? [String: Any],
                      let content = msg["content"] else { continue }

                if let text = content as? String {
                    prompt = cleanPrompt(text)
                    break
                }
                if let blocks = content as? [[String: Any]] {
                    for block in blocks {
                        if block["type"] as? String == "text",
                           let text = block["text"] as? String {
                            prompt = cleanPrompt(text)
                            break
                        }
                    }
                    if prompt != nil { break }
                }
            }

            return SessionState(prompt: prompt, modTime: modTime, liveState: liveState, liveDetail: liveDetail)
        }
        return empty
    }

    private static func parseLiveState(from lines: [String]) -> (AgentLiveState, String?) {
        // Walk backwards through the last entries to determine current state
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let type = json["type"] as? String ?? ""

            switch type {
            case "assistant":
                let msg = json["message"] as? [String: Any] ?? [:]
                let stopReason = msg["stop_reason"] as? String

                if stopReason == "end_turn" {
                    return (.waitingForUser, nil)
                }

                // Check content for tool_use, thinking, or text
                if let content = msg["content"] as? [[String: Any]] {
                    for block in content.reversed() {
                        let blockType = block["type"] as? String ?? ""
                        if blockType == "tool_use" {
                            let toolName = block["name"] as? String ?? "tool"
                            let detail = extractToolDetail(name: toolName, input: block["input"] as? [String: Any] ?? [:])
                            return (.toolUse(toolName), detail)
                        }
                        if blockType == "thinking" {
                            return (.thinking, nil)
                        }
                        if blockType == "text" {
                            if stopReason == nil {
                                let text = block["text"] as? String ?? ""
                                let snippet = String(text.replacingOccurrences(of: "\n", with: " ")
                                    .trimmingCharacters(in: .whitespaces).suffix(100))
                                return (.responding, snippet.isEmpty ? nil : snippet)
                            }
                        }
                    }
                }

                if stopReason == "tool_use" {
                    return (.toolUse("tool"), nil)
                }
                if stopReason == nil {
                    return (.responding, nil)
                }
                return (.waitingForUser, nil)

            case "user":
                // Distinguish real user messages from tool_result entries
                // Tool results are type:"user" but have tool_result content blocks, not text
                let msg = json["message"] as? [String: Any] ?? [:]
                if let content = msg["content"] as? [[String: Any]] {
                    let hasToolResult = content.contains { $0["type"] as? String == "tool_result" }
                    if hasToolResult {
                        // This is a tool result, not a real user message — agent is processing
                        return (.responding, nil)
                    }
                }
                // Real user message — agent is thinking
                return (.thinking, nil)

            default:
                continue
            }
        }
        return (.idle, nil)
    }

    private static func extractToolDetail(name: String, input: [String: Any]) -> String? {
        switch name {
        case "Bash":
            if let cmd = input["command"] as? String {
                let clean = cmd.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                return String(clean.prefix(80))
            }
        case "Read":
            return input["file_path"] as? String
        case "Write":
            return input["file_path"] as? String
        case "Edit":
            return input["file_path"] as? String
        case "Grep":
            if let pattern = input["pattern"] as? String {
                return "pattern: \(pattern)"
            }
        case "Glob":
            return input["pattern"] as? String
        case "Agent":
            return input["description"] as? String
        case "WebSearch":
            return input["query"] as? String
        case "WebFetch":
            return input["url"] as? String
        default:
            break
        }
        return nil
    }

    private static func cleanPrompt(_ raw: String) -> String? {
        var text = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove image references
        let imagePattern = "\\[Image[^\\]]*\\]"
        text = text.replacingOccurrences(of: imagePattern, with: "", options: .regularExpression)

        // Remove system tags
        let tagPattern = "<[^>]+>"
        text = text.replacingOccurrences(of: tagPattern, with: "", options: .regularExpression)

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.isEmpty { return nil }

        // Truncate
        if text.count > 120 {
            text = String(text.prefix(117)) + "..."
        }
        return text
    }

    // MARK: - Shell Helpers
    //
    // NOTE: this used to spawn `/bin/ps` every 3s (see git history). Each subprocess
    // spawn on macOS triggers a Gatekeeper/codesign check via syspolicyd, and doing
    // that every 3 seconds forever measurably hammered syspolicyd/launchservicesd
    // and caused system-wide keyboard input lag. Replaced with a native
    // sysctl(KERN_PROC_ALL) + sysctl(KERN_PROCARGS2) scan — no subprocess, no
    // Gatekeeper check, same data.

    private static func runPS() -> [String] {
        guard let pids = listAllPIDs() else { return [] }
        var lines: [String] = []
        lines.reserveCapacity(pids.count)
        for pid in pids {
            guard let info = procInfo(pid: pid), let args = procArgs(pid: pid) else { continue }
            // Mirror the old `ps -eo pid,pcpu,rss,etime,args` column shape so
            // parsePSLine below keeps working unmodified.
            lines.append("\(pid) \(info.cpu) \(info.rssKB) \(info.etime) \(args)")
        }
        return lines
    }

    private static func listAllPIDs() -> [pid_t]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }

        let count = size / MemoryLayout<kinfo_proc>.size
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        var actualSize = size
        guard sysctl(&mib, UInt32(mib.count), &procs, &actualSize, nil, 0) == 0 else { return nil }

        let actualCount = actualSize / MemoryLayout<kinfo_proc>.size
        return procs.prefix(actualCount).map { $0.kp_proc.p_pid }
    }

    private struct ProcMetrics {
        let cpu: String   // formatted like ps's %CPU column
        let rssKB: Int
        let etime: String
    }

    private static var startTimeCache: [pid_t: Date] = [:]

    /// Best-effort CPU%/RSS/elapsed via proc_pidinfo (TASK_BASIC_INFO-equivalent).
    /// We don't need ps-grade precision here — this only feeds a UI status dot
    /// (idle vs running), so approximations are fine.
    private static func procInfo(pid: pid_t) -> ProcMetrics? {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rptr in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rptr)
            }
        }
        guard result == 0 else { return nil }

        let rssKB = Int(usage.ri_resident_size / 1024)

        var kp = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, UInt32(mib.count), &kp, &size, nil, 0) == 0 else { return nil }

        let startSeconds = TimeInterval(kp.kp_proc.p_starttime.tv_sec)
        let startDate = Date(timeIntervalSince1970: startSeconds)
        let elapsedSeconds = max(0, Date().timeIntervalSince(startDate))
        let etime = formatEtimeRaw(elapsedSeconds)

        // Approximate %CPU from total CPU time / wall-clock elapsed since start.
        let cpuSeconds = Double(usage.ri_user_time + usage.ri_system_time) / 1_000_000_000.0
        let cpuPct = elapsedSeconds > 0 ? min(100.0, (cpuSeconds / elapsedSeconds) * 100.0) : 0
        let cpuStr = String(format: "%.1f", cpuPct)

        return ProcMetrics(cpu: cpuStr, rssKB: rssKB, etime: etime)
    }

    /// Formats seconds into ps's `etime` raw shape (`[[dd-]hh:]mm:ss`) so
    /// formatElapsed(_:) downstream doesn't need to change.
    private static func formatEtimeRaw(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let s = total % 60
        let m = (total / 60) % 60
        let h = (total / 3600) % 24
        let d = total / 86400
        if d > 0 { return "\(d)-\(String(format: "%02d", h)):\(String(format: "%02d", m)):\(String(format: "%02d", s))" }
        if h > 0 { return "\(h):\(String(format: "%02d", m)):\(String(format: "%02d", s))" }
        return "\(m):\(String(format: "%02d", s))"
    }

    /// Reads argv for a pid via sysctl(KERN_PROCARGS2) — same info `ps ... args`
    /// exposes, no subprocess required.
    private static func procArgs(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

        // Layout: Int32 argc, then argv[0] (executable path), NUL-padded,
        // then argv[1...] each NUL-terminated.
        guard buffer.count >= MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }

        var offset = MemoryLayout<Int32>.size
        func readCString() -> String? {
            guard offset < buffer.count else { return nil }
            let start = offset
            while offset < buffer.count, buffer[offset] != 0 { offset += 1 }
            let str = String(bytes: buffer[start..<offset], encoding: .utf8)
            // Skip the NUL and any padding NULs before the next string.
            while offset < buffer.count, buffer[offset] == 0 { offset += 1 }
            return str
        }

        guard let execPath = readCString() else { return nil }
        var args: [String] = [execPath]
        var i: Int32 = 0
        while i < argc, let arg = readCString() {
            args.append(arg)
            i += 1
        }
        return args.joined(separator: " ")
    }

    private struct PSLine {
        let pid: Int32
        let cpu: Double
        let memMB: Double
        let elapsed: String
        let command: String
        let args: String
    }

    private static func parsePSLine(_ line: String) -> PSLine? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 5 else { return nil }
        guard let pid = Int32(parts[0]),
              let cpu = Double(parts[1]),
              let rssKB = Double(parts[2]) else { return nil }

        return PSLine(
            pid: pid, cpu: cpu, memMB: rssKB / 1024.0,
            elapsed: formatElapsed(parts[3]),
            command: parts[4],
            args: parts[4...].joined(separator: " ")
        )
    }

    private static func extractFlag(from args: String, flag: String) -> String? {
        let parts = args.components(separatedBy: .whitespaces)
        guard let idx = parts.firstIndex(of: flag), idx + 1 < parts.count else { return nil }
        return parts[idx + 1]
    }

    private static func formatElapsed(_ raw: String) -> String {
        let parts = raw.components(separatedBy: ":")
        if parts.count == 3 {
            let hourPart = parts[0]
            if hourPart.contains("-") {
                let dp = hourPart.components(separatedBy: "-")
                return "\(dp[0])d \(dp[1])h"
            }
            if let h = Int(hourPart), h > 0 {
                return "\(h)h \(parts[1])m"
            }
            return "\(parts[1])m \(parts[2])s"
        } else if parts.count == 2 {
            return "\(parts[0])m \(parts[1])s"
        }
        return raw
    }

    /// Native replacement for the old `lsof -a -p {pid} -d cwd -Fn` subprocess.
    /// Uses libproc's PROC_PIDVNODEPATHINFO, same info lsof reports, no spawn.
    private static func getCwd(pid: Int32) -> String? {
        var vnodeInfo = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = withUnsafeMutablePointer(to: &vnodeInfo) { ptr -> Int32 in
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, ptr, size)
        }
        guard result == size else { return nil }

        let cwdPathBytes = withUnsafePointer(to: vnodeInfo.pvi_cdir.vip_path) { ptr -> [UInt8] in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(MAXPATHLEN)) { buf in
                Array(UnsafeBufferPointer(start: buf, count: Int(MAXPATHLEN)))
            }
        }
        guard let nulIdx = cwdPathBytes.firstIndex(of: 0) else {
            return String(bytes: cwdPathBytes, encoding: .utf8)
        }
        return String(bytes: cwdPathBytes[..<nulIdx], encoding: .utf8)
    }
}
