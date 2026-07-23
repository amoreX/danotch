import SwiftUI
import Darwin

// MARK: - System Stats Monitor

class SystemStatsMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0
    @Published var ramUsed: Double = 0
    @Published var ramTotal: Double = 0
    @Published var netUp: Double = 0
    @Published var netDown: Double = 0
    @Published var diskUsed: Double = 0
    @Published var diskTotal: Double = 0
    @Published var processCount: Int = 0
    @Published var uptime: TimeInterval = 0
    @Published var processes: [ProcessInfo_] = []

    @Published var cpuHistory: [Double] = Array(repeating: 0, count: 40)
    @Published var netDownHistory: [Double] = Array(repeating: 0, count: 40)
    @Published var netUpHistory: [Double] = Array(repeating: 0, count: 40)

    private var timer: Timer?
    private var prevNetIn: UInt64 = 0
    private var prevNetOut: UInt64 = 0
    private var firstSample = true

    init() {
        sample()
        refreshProcesses()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.sample() }
        }
    }

    deinit { timer?.invalidate() }

    private func sample() {
        cpuUsage = readCPU()
        let (used, total) = readMemory()
        ramUsed = used
        ramTotal = total
        let (inBytes, outBytes) = readNetwork()
        if !firstSample {
            netDown = Double(inBytes.subtractingReportingOverflow(prevNetIn).partialValue) / 2.0
            netUp = Double(outBytes.subtractingReportingOverflow(prevNetOut).partialValue) / 2.0
        }
        prevNetIn = inBytes
        prevNetOut = outBytes
        firstSample = false

        let (dU, dT) = readDisk()
        diskUsed = dU
        diskTotal = dT
        processCount = readProcessCount()
        uptime = ProcessInfo.processInfo.systemUptime

        cpuHistory.append(cpuUsage)
        if cpuHistory.count > 40 { cpuHistory.removeFirst() }
        netDownHistory.append(netDown)
        if netDownHistory.count > 40 { netDownHistory.removeFirst() }
        netUpHistory.append(netUp)
        if netUpHistory.count > 40 { netUpHistory.removeFirst() }
    }

    func refreshProcesses() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let procs = Self.readProcessList()
            DispatchQueue.main.async { self?.processes = procs }
        }
    }

    func killProcess(pid: Int32) {
        kill(pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshProcesses()
        }
    }

    func forceKillProcess(pid: Int32) {
        kill(pid, SIGKILL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshProcesses()
        }
    }

    var ramPercent: Double { ramTotal > 0 ? (ramUsed / ramTotal) * 100 : 0 }
    var diskPercent: Double { diskTotal > 0 ? (diskUsed / diskTotal) * 100 : 0 }

    var uptimeString: String {
        let h = Int(uptime) / 3600
        let m = (Int(uptime) % 3600) / 60
        if h > 24 { return "\(h / 24)d \(h % 24)h" }
        return "\(h)h \(m)m"
    }

    // MARK: - CPU

    private var prevCPUInfo: host_cpu_load_info?

    private func readCPU() -> Double {
        var numCPU: natural_t = 0
        var cpuInfoPtr: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
            &numCPU, &cpuInfoPtr, &numCPUInfo
        )
        guard result == KERN_SUCCESS, let cpuInfo = cpuInfoPtr else { return 0 }

        var totalUser: Int32 = 0, totalSystem: Int32 = 0, totalIdle: Int32 = 0, totalNice: Int32 = 0
        for i in 0..<Int(numCPU) {
            let base = Int(CPU_STATE_MAX) * i
            totalUser   += cpuInfo[base + Int(CPU_STATE_USER)]
            totalSystem += cpuInfo[base + Int(CPU_STATE_SYSTEM)]
            totalIdle   += cpuInfo[base + Int(CPU_STATE_IDLE)]
            totalNice   += cpuInfo[base + Int(CPU_STATE_NICE)]
        }

        let current = host_cpu_load_info(
            cpu_ticks: (UInt32(totalUser), UInt32(totalSystem), UInt32(totalIdle), UInt32(totalNice))
        )
        defer { prevCPUInfo = current }

        guard let prev = prevCPUInfo else {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<Int32>.size))
            return 0
        }

        let userDiff  = Double(current.cpu_ticks.0 - prev.cpu_ticks.0)
        let sysDiff   = Double(current.cpu_ticks.1 - prev.cpu_ticks.1)
        let idleDiff  = Double(current.cpu_ticks.2 - prev.cpu_ticks.2)
        let niceDiff  = Double(current.cpu_ticks.3 - prev.cpu_ticks.3)
        let totalDiff = userDiff + sysDiff + idleDiff + niceDiff

        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<Int32>.size))

        guard totalDiff > 0 else { return 0 }
        return ((userDiff + sysDiff + niceDiff) / totalDiff) * 100
    }

    // MARK: - Memory

    private func readMemory() -> (used: Double, total: Double) {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &size)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }

        let pageSize = Double(vm_kernel_page_size)
        let used = Double(stats.active_count) * pageSize
            + Double(stats.wire_count) * pageSize
            + Double(stats.compressor_page_count) * pageSize
        return (used, Double(ProcessInfo.processInfo.physicalMemory))
    }

    // MARK: - Network

    private func readNetwork() -> (inBytes: UInt64, outBytes: UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }

        var totalIn: UInt64 = 0, totalOut: UInt64 = 0
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = current {
            let name = String(cString: ifa.pointee.ifa_name)
            if ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) &&
               (name.hasPrefix("en") || name.hasPrefix("utun") || name.hasPrefix("pdp_ip")) {
                if let data = ifa.pointee.ifa_data {
                    let nd = data.assumingMemoryBound(to: if_data.self).pointee
                    totalIn += UInt64(nd.ifi_ibytes)
                    totalOut += UInt64(nd.ifi_obytes)
                }
            }
            current = ifa.pointee.ifa_next
        }
        return (totalIn, totalOut)
    }

    // MARK: - Disk

    private func readDisk() -> (used: Double, total: Double) {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/") else { return (0, 0) }
        let total = (attrs[.systemSize] as? NSNumber)?.doubleValue ?? 0
        let free = (attrs[.systemFreeSize] as? NSNumber)?.doubleValue ?? 0
        return (total - free, total)
    }

    // MARK: - Process Count

    private func readProcessCount() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0
        sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0)
        return size / MemoryLayout<kinfo_proc>.size
    }

    // MARK: - Process List via ps

    static func readProcessList() -> [ProcessInfo_] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid,pcpu,rss,comm", "-r"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return [] }

        // Read before wait to avoid pipe buffer deadlock
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var results: [ProcessInfo_] = []
        for line in output.components(separatedBy: "\n").dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Parse: PID  %CPU  RSS  COMM (comm can contain spaces)
            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 4 else { continue }
            guard let pid = Int32(parts[0]),
                  let cpu = Double(parts[1]),
                  let rssKB = Double(parts[2]) else { continue }

            let fullPath = parts[3...].joined(separator: " ")
            let name = fullPath.components(separatedBy: "/").last ?? fullPath
            let memMB = rssKB / 1024.0

            if cpu < 0.1 && memMB < 5 { continue }

            results.append(ProcessInfo_(
                pid: pid,
                name: String(name),
                cpu: cpu,
                memMB: memMB,
                path: fullPath
            ))
        }
        return Array(results.prefix(50))
    }
}

// MARK: - Process Info Model

struct ProcessInfo_: Identifiable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    let cpu: Double
    let memMB: Double
    let path: String?
}

// MARK: - Formatting

func fmtBytes(_ bytes: Double) -> String {
    if bytes < 1024 { return String(format: "%.0f B/s", bytes) }
    if bytes < 1024 * 1024 { return String(format: "%.1f KB/s", bytes / 1024) }
    return String(format: "%.1f MB/s", bytes / 1024 / 1024)
}

private func fmtGB(_ bytes: Double) -> String {
    String(format: "%.1f", bytes / (1024 * 1024 * 1024))
}

// MARK: - Stats Panel (Bento Grid)

struct StatsPanel: View {
    @ObservedObject var viewModel: NotchViewModel
    var monitor: SystemStatsMonitor { viewModel.statsMonitor }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    statGauge(
                        title: "CPU",
                        value: monitor.cpuUsage / 100,
                        primary: "\(Int(monitor.cpuUsage))%",
                        secondary: "of capacity",
                        symbol: "cpu.fill",
                        tint: tintFor(monitor.cpuUsage, warnAt: 50, dangerAt: 80)
                    )
                    statGauge(
                        title: "Memory",
                        value: monitor.ramPercent / 100,
                        primary: fmtGB(monitor.ramUsed),
                        secondary: "of \(fmtGB(monitor.ramTotal)) GB",
                        symbol: "memorychip.fill",
                        tint: tintFor(monitor.ramPercent, warnAt: 60, dangerAt: 85)
                    )
                }

                statRow(title: "Network", symbol: "network") {
                    networkLine(symbol: "arrow.down", label: "Down",
                                value: fmtBytes(monitor.netDown) + "/s", tint: .green)
                    Divider().background(Color.white.opacity(0.06))
                    networkLine(symbol: "arrow.up", label: "Up",
                                value: fmtBytes(monitor.netUp) + "/s", tint: .blue)
                }

                HStack(spacing: 12) {
                    statGauge(
                        title: "Storage",
                        value: monitor.diskPercent / 100,
                        primary: "\(Int(monitor.diskPercent))%",
                        secondary: "\(fmtGB(monitor.diskUsed))/\(fmtGB(monitor.diskTotal)) GB",
                        symbol: "internaldrive.fill",
                        tint: tintFor(monitor.diskPercent, warnAt: 75, dangerAt: 90)
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Uptime", systemImage: "clock")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(monitor.uptimeString)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .glassCell(cornerRadius: 18)
                }

                Button {
                    monitor.refreshProcesses()
                    withAnimation(DN.transition) {
                        viewModel.viewState = .processList
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Processes")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("\(monitor.processCount) running")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                    .glassCell(cornerRadius: 18)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
        .scrollIndicators(.never)
        .smartScrollFade(28, bottomRadius: 28)
    }

    // MARK: - Tile builders

    private func statGauge(
        title: String,
        value: Double,
        primary: String,
        secondary: String,
        symbol: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                Circle()
                    .trim(from: 0, to: min(max(value, 0), 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: value)

                Text(primary)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            .frame(width: 84, height: 84)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)

            Text(secondary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCell(cornerRadius: 18)
    }

    private func statRow<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            VStack(spacing: 4) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCell(cornerRadius: 18)
    }

    private func networkLine(symbol: String, label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
    }

    private func tintFor(_ pct: Double, warnAt: Double, dangerAt: Double) -> Color {
        if pct >= dangerAt { return .red }
        if pct >= warnAt { return .yellow }
        return .green
    }
}

// MARK: - Process List Panel

struct ProcessListPanel: View {
    @ObservedObject var viewModel: NotchViewModel
    var monitor: SystemStatsMonitor { viewModel.statsMonitor }
    @State private var selectedPid: Int32? = nil
    @State private var sortBy: SortField = .cpu

    enum SortField: String, CaseIterable, Identifiable {
        case cpu = "CPU", mem = "Memory", name = "Name"
        var id: String { rawValue }
    }

    private var sortedProcesses: [ProcessInfo_] {
        switch sortBy {
        case .cpu:  return monitor.processes.sorted { $0.cpu > $1.cpu }
        case .mem:  return monitor.processes.sorted { $0.memMB > $1.memMB }
        case .name: return monitor.processes.sorted { $0.name.lowercased() < $1.name.lowercased() }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(SortField.allCases) { field in
                    sortPill(field)
                }
                Spacer()
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 22)
                    .perchGlass(in: Capsule())
                    .contentShape(.capsule)
                    .onTapGesture { monitor.refreshProcesses() }
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(sortedProcesses.enumerated()), id: \.element.id) { idx, proc in
                        processRow(proc)
                        if idx < sortedProcesses.count - 1 {
                            Divider().background(Color.white.opacity(0.05))
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity)
                .contentCard(cornerRadius: 18)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.never)
            .smartScrollFade(28, bottomRadius: 28)
        }
        .onAppear { monitor.refreshProcesses() }
    }

    private func sortPill(_ field: SortField) -> some View {
        let active = sortBy == field
        return Text(field.rawValue)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 22)
            .perchGlass(tint: active ? DN.activeAccent : nil, in: Capsule())
            .contentShape(.capsule)
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.15)) { sortBy = field }
            }
    }

    private func processRow(_ proc: ProcessInfo_) -> some View {
        let isSelected = selectedPid == proc.pid
        let cpuTint = procTint(proc.cpu, warnAt: 25, dangerAt: 60)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProcessIconView(path: proc.path)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(proc.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if isSelected {
                        Text("PID \(proc.pid)")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 8)

                metric(value: String(format: "%.1f", proc.cpu), unit: "%",
                       tint: proc.cpu > 25 ? cpuTint : .secondary)
                    .frame(width: 56, alignment: .trailing)

                metric(value: String(format: "%.0f", proc.memMB), unit: "MB",
                       tint: .secondary)
                    .frame(width: 60, alignment: .trailing)
            }
            .padding(.vertical, isSelected ? 8 : 6)
            .padding(.horizontal, 10)
            .contentShape(.rect)
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.15)) {
                    selectedPid = isSelected ? nil : proc.pid
                }
            }

            if isSelected {
                HStack {
                    Spacer()
                    Text("Force Quit")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 22)
                        .perchGlass(tint: .red, in: Capsule())
                        .contentShape(.capsule)
                        .onTapGesture { monitor.forceKillProcess(pid: proc.pid) }
                }
                .padding(.bottom, 8)
                .padding(.horizontal, 10)
                .transition(.opacity)
            }
        }
    }

    private func metric(value: String, unit: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(unit)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func procTint(_ pct: Double, warnAt: Double, dangerAt: Double) -> Color {
        if pct >= dangerAt { return .red }
        if pct >= warnAt { return .yellow }
        return .green
    }
}

// MARK: - Process Icon View

private struct ProcessIconView: View {
    let path: String?

    var body: some View {
        if let nsImage = resolveIcon() {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                )
        }
    }

    private func resolveIcon() -> NSImage? {
        guard let path = path else { return nil }
        let components = path.components(separatedBy: "/")
        for (i, comp) in components.enumerated() {
            if comp.hasSuffix(".app") {
                let appPath = components[0...i].joined(separator: "/")
                let icon = NSWorkspace.shared.icon(forFile: appPath)
                if icon.size.width > 0 { return icon }
            }
        }
        if FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return nil
    }
}
