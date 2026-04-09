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

// MARK: - Glass cell modifier

private struct GlassCell: ViewModifier {
    var cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(DN.surface.opacity(0.55))
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.04), Color.white.opacity(0.01)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.1), Color.white.opacity(0.03)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
    }
}

private extension View {
    func glassCell(cornerRadius: CGFloat = 10) -> some View {
        modifier(GlassCell(cornerRadius: cornerRadius))
    }
}

// MARK: - Stats Panel (Bento Grid)

struct StatsPanel: View {
    @ObservedObject var viewModel: NotchViewModel
    var monitor: SystemStatsMonitor { viewModel.statsMonitor }

    private let gap: CGFloat = 5

    var body: some View {
        VStack(spacing: gap) {
            // Row 1: CPU + RAM arc gauges
            HStack(spacing: gap) {
                ArcGaugeCell(
                    label: "CPU",
                    value: monitor.cpuUsage, maxValue: 100,
                    displayValue: String(format: "%.0f", monitor.cpuUsage),
                    unit: "%", color: cpuColor,
                    history: monitor.cpuHistory
                )

                ArcGaugeCell(
                    label: "RAM",
                    value: monitor.ramPercent, maxValue: 100,
                    displayValue: fmtGB(monitor.ramUsed),
                    unit: "/ \(fmtGB(monitor.ramTotal))",
                    color: ramColor, history: nil
                )
            }

            // Row 2: Network (compact) + Disk
            HStack(spacing: gap) {
                // Network combined
                VStack(spacing: 0) {
                    netRow(direction: "\u{2193}", label: "DOWN", value: fmtBytes(monitor.netDown),
                           color: DN.success, history: monitor.netDownHistory)

                    Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
                        .padding(.horizontal, DN.spaceSM)

                    netRow(direction: "\u{2191}", label: "UP", value: fmtBytes(monitor.netUp),
                           color: DN.warning, history: monitor.netUpHistory)
                }
                .frame(maxHeight: .infinity)
                .glassCell()

                // Disk
                VStack(alignment: .leading, spacing: DN.spaceXS) {
                    Text("DISK")
                        .font(DN.label(7))
                        .tracking(1.2)
                        .foregroundColor(DN.textDisabled)

                    Spacer()

                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.06), lineWidth: 3)
                            .frame(width: 36, height: 36)
                        Circle()
                            .trim(from: 0, to: monitor.diskPercent / 100)
                            .stroke(diskColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .frame(width: 36, height: 36)
                            .rotationEffect(.degrees(-90))
                        Text(String(format: "%.0f", monitor.diskPercent))
                            .font(DN.mono(9, weight: .medium))
                            .foregroundColor(DN.textPrimary)
                    }
                    .frame(maxWidth: .infinity)

                    Spacer()

                    Text("\(fmtGB(monitor.diskUsed))/\(fmtGB(monitor.diskTotal)) GB")
                        .font(DN.mono(7))
                        .foregroundColor(DN.textDisabled)
                }
                .padding(DN.spaceSM)
                .frame(maxHeight: .infinity)
                .frame(width: 100)
                .glassCell()
            }

            // Row 3: Proc (clickable) + Uptime
            HStack(spacing: gap) {
                Button(action: {
                    monitor.refreshProcesses()
                    withAnimation(DN.transition) {
                        viewModel.viewState = .processList
                    }
                }) {
                    HStack(spacing: DN.spaceSM) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("PROCESSES")
                                .font(DN.label(7))
                                .tracking(1.2)
                                .foregroundColor(DN.textDisabled)
                            Text("\(monitor.processCount)")
                                .font(DN.display(22))
                                .foregroundColor(DN.textDisplay)
                        }
                        Spacer()
                        HStack(alignment: .bottom, spacing: 2) {
                            ForEach(0..<min(5, monitor.processes.count), id: \.self) { i in
                                let pct = min(monitor.processes[i].cpu / 20, 1)
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(pct > 0.5 ? DN.warning : DN.textSecondary.opacity(0.5))
                                    .frame(width: 4, height: max(4, CGFloat(pct) * 30))
                            }
                        }
                        .frame(height: 30)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(DN.textDisabled)
                    }
                    .padding(DN.spaceSM)
                    .frame(maxHeight: .infinity)
                    .glassCell()
                }
                .buttonStyle(.plain)

                VStack(spacing: DN.spaceXS) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundColor(DN.textDisabled)
                    Text(monitor.uptimeString)
                        .font(DN.mono(12, weight: .medium))
                        .foregroundColor(DN.textPrimary)
                    Text("UPTIME")
                        .font(DN.label(6))
                        .tracking(1)
                        .foregroundColor(DN.textDisabled)
                }
                .frame(maxHeight: .infinity)
                .frame(width: 80)
                .glassCell()
            }
        }
    }

    private func netRow(direction: String, label: String, value: String,
                        color: Color, history: [Double]) -> some View {
        HStack(spacing: DN.spaceXS) {
            Text(direction)
                .font(DN.mono(9, weight: .bold))
                .foregroundColor(color)
                .frame(width: 12)

            Text(label)
                .font(DN.label(7))
                .tracking(1)
                .foregroundColor(DN.textDisabled)

            SparklineGraph(
                data: history,
                maxValue: max(history.max() ?? 1, 1),
                color: color
            )
            .frame(height: 16)

            Text(value)
                .font(DN.mono(9, weight: .medium))
                .foregroundColor(color)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, DN.spaceSM)
        .padding(.vertical, 6)
    }

    private var cpuColor: Color {
        if monitor.cpuUsage > 80 { return DN.accent }
        if monitor.cpuUsage > 50 { return DN.warning }
        return DN.success
    }

    private var ramColor: Color {
        if monitor.ramPercent > 85 { return DN.accent }
        if monitor.ramPercent > 60 { return DN.warning }
        return DN.success
    }

    private var diskColor: Color {
        if monitor.diskPercent > 90 { return DN.accent }
        if monitor.diskPercent > 75 { return DN.warning }
        return DN.textSecondary
    }
}

// MARK: - Process List Panel

struct ProcessListPanel: View {
    @ObservedObject var viewModel: NotchViewModel
    var monitor: SystemStatsMonitor { viewModel.statsMonitor }
    @State private var selectedPid: Int32? = nil
    @State private var sortBy: SortField = .cpu

    enum SortField { case cpu, mem, name }

    private var sortedProcesses: [ProcessInfo_] {
        switch sortBy {
        case .cpu:  return monitor.processes.sorted { $0.cpu > $1.cpu }
        case .mem:  return monitor.processes.sorted { $0.memMB > $1.memMB }
        case .name: return monitor.processes.sorted { $0.name.lowercased() < $1.name.lowercased() }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header + column headers combined
            HStack(spacing: DN.spaceSM) {
                Button(action: {
                    withAnimation(DN.transition) { viewModel.viewState = .stats }
                }) {
                    Text("<")
                        .font(DN.mono(12, weight: .medium))
                        .foregroundColor(DN.textSecondary)
                }
                .buttonStyle(.plain)

                Text("PROCESSES")
                    .font(DN.label(9))
                    .tracking(1.5)
                    .foregroundColor(DN.textSecondary)

                Text("\(monitor.processes.count)")
                    .font(DN.mono(9))
                    .foregroundColor(DN.textDisabled)

                Spacer()

                sortHeader("CPU", field: .cpu, width: 42)
                sortHeader("MEM", field: .mem, width: 38)

                Button(action: { monitor.refreshProcesses() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(DN.textDisabled)
                }
                .buttonStyle(.plain)
                .frame(width: 20)
            }
            .padding(.horizontal, DN.spaceXS)

            Rectangle().fill(DN.border).frame(height: 1)
                .padding(.top, DN.spaceXS)

            // Process list
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(sortedProcesses) { proc in
                        processRow(proc)
                    }
                }
            }
        }
        .onAppear { monitor.refreshProcesses() }
    }

    private func sortHeader(_ title: String, field: SortField, width: CGFloat?) -> some View {
        Button(action: {
            withAnimation(.easeOut(duration: 0.15)) { sortBy = field }
        }) {
            HStack(spacing: 2) {
                Text(title)
                    .font(DN.label(7))
                    .tracking(1)
                    .foregroundColor(sortBy == field ? DN.textPrimary : DN.textDisabled)
                if sortBy == field {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 5, weight: .bold))
                        .foregroundColor(DN.textPrimary)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: .trailing)
    }

    private func processRow(_ proc: ProcessInfo_) -> some View {
        let isSelected = selectedPid == proc.pid
        let cpuHigh = proc.cpu > 50

        return Button(action: {
            withAnimation(.easeOut(duration: 0.15)) {
                selectedPid = isSelected ? nil : proc.pid
            }
        }) {
            VStack(spacing: 0) {
                HStack(spacing: DN.spaceSM) {
                    // App icon
                    ProcessIconView(path: proc.path)
                        .frame(width: 18, height: 18)

                    // Name + PID
                    VStack(alignment: .leading, spacing: 0) {
                        Text(proc.name)
                            .font(DN.body(11, weight: .medium))
                            .foregroundColor(cpuHigh ? DN.warning : DN.textPrimary)
                            .lineLimit(1)
                        if isSelected {
                            Text("PID \(proc.pid)")
                                .font(DN.mono(8))
                                .foregroundColor(DN.textDisabled)
                        }
                    }

                    Spacer()

                    // CPU
                    Text(proc.cpu < 0.1 ? "0" : String(format: "%.1f", proc.cpu))
                        .font(DN.mono(10, weight: proc.cpu > 10 ? .bold : .regular))
                        .foregroundColor(cpuHigh ? DN.warning : DN.textSecondary)
                        .frame(width: 42, alignment: .trailing)

                    // Memory (MB)
                    Text(proc.memMB < 1 ? "<1" : String(format: "%.0f", proc.memMB))
                        .font(DN.mono(10))
                        .foregroundColor(DN.textSecondary)
                        .frame(width: 38, alignment: .trailing)

                    // Force quit
                    if isSelected {
                        Button(action: { monitor.forceKillProcess(pid: proc.pid) }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(DN.accent)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 20)
                    } else {
                        Color.clear.frame(width: 20)
                    }
                }
                .padding(.horizontal, DN.spaceSM)
                .padding(.vertical, isSelected ? 5 : 3)
                .background(isSelected ? DN.surface : .clear)

                Rectangle().fill(DN.border.opacity(0.4)).frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
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
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(DN.border)
                .overlay(
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 9))
                        .foregroundColor(DN.textDisabled)
                )
        }
    }

    private func resolveIcon() -> NSImage? {
        guard let path = path else { return nil }

        // Try to find .app bundle by walking up from binary path
        let components = path.components(separatedBy: "/")
        for (i, comp) in components.enumerated() {
            if comp.hasSuffix(".app") {
                let appPath = components[0...i].joined(separator: "/")
                let icon = NSWorkspace.shared.icon(forFile: appPath)
                if icon.size.width > 0 { return icon }
            }
        }

        // Fallback: icon for the binary itself
        if FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }

        return nil
    }
}

// MARK: - Arc Gauge Cell (segmented tick style)

private struct ArcGaugeCell: View {
    let label: String
    let value: Double
    let maxValue: Double
    let displayValue: String
    let unit: String
    let color: Color
    let history: [Double]?

    @State private var pulse = false
    private var fraction: Double { min(value / max(maxValue, 0.001), 1) }
    private let totalTicks = 36

    var body: some View {
        ZStack {
            // Background sparkline
            if let history = history {
                MiniSparkline(data: history, color: color)
                    .opacity(0.15)
            }

            VStack(spacing: 0) {
                HStack {
                    Text(label)
                        .font(DN.label(8))
                        .tracking(1.5)
                        .foregroundColor(DN.textDisabled)
                    Spacer()
                    // Live value badge
                    Text(String(format: "%.1f", value))
                        .font(DN.mono(8))
                        .foregroundColor(color.opacity(pulse ? 1 : 0.5))
                        .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)
                }

                Spacer()

                // Segmented arc gauge
                ZStack {
                    SegmentedArc(totalTicks: totalTicks, filledTicks: Int(fraction * Double(totalTicks)),
                                 activeColor: color, inactiveColor: Color.white.opacity(0.06))
                        .frame(width: 60, height: 60)
                        .animation(.easeOut(duration: 0.5), value: fraction)

                    VStack(spacing: -1) {
                        Text(displayValue)
                            .font(DN.display(18))
                            .foregroundColor(DN.textDisplay)
                        Text(unit)
                            .font(DN.label(6))
                            .tracking(0.5)
                            .foregroundColor(DN.textDisabled)
                    }
                }

                Spacer()
            }
            .padding(DN.spaceSM)
        }
        .frame(maxHeight: .infinity)
        .glassCell()
        .onAppear { pulse = true }
    }
}

// MARK: - Segmented Arc (tick marks)

private struct SegmentedArc: View {
    let totalTicks: Int
    let filledTicks: Int
    let activeColor: Color
    let inactiveColor: Color

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = min(geo.size.width, geo.size.height) / 2
            let startDeg: Double = 135
            let sweepDeg: Double = 270
            let gap: Double = sweepDeg / Double(totalTicks)

            ZStack {
                ForEach(0..<totalTicks, id: \.self) { i in
                    let angle = Angle(degrees: startDeg + Double(i) * gap)
                    let innerR = radius - 6
                    let outerR = radius
                    let isFilled = i < filledTicks
                    let isHot = isFilled && i >= filledTicks - 3 && filledTicks > 3

                    Path { path in
                        let cos = Darwin.cos(angle.radians)
                        let sin = Darwin.sin(angle.radians)
                        path.move(to: CGPoint(
                            x: center.x + innerR * cos,
                            y: center.y + innerR * sin
                        ))
                        path.addLine(to: CGPoint(
                            x: center.x + outerR * cos,
                            y: center.y + outerR * sin
                        ))
                    }
                    .stroke(
                        isFilled ? activeColor.opacity(isHot ? 1 : 0.7) : inactiveColor,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                }
            }
        }
    }
}

// MARK: - Mini Sparkline (background fill)

private struct MiniSparkline: View {
    let data: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            guard data.count > 1 else { return AnyView(EmptyView()) }

            let maxVal = max(data.max() ?? 1, 1)
            let step = w / CGFloat(data.count - 1)
            let points: [CGPoint] = data.enumerated().map { i, val in
                CGPoint(x: CGFloat(i) * step,
                        y: h - (CGFloat(min(val, maxVal) / maxVal) * h * 0.5))
            }

            return AnyView(
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h))
                    for pt in points { path.addLine(to: pt) }
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [color.opacity(0.1), color.opacity(0.01)],
                    startPoint: .top, endPoint: .bottom
                ))
            )
        }
    }
}

// MARK: - Stepped Sparkline (retro oscilloscope style)

private struct SparklineGraph: View {
    let data: [Double]
    let maxValue: Double
    let color: Color

    @State private var livePulse = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            guard data.count > 1 else { return AnyView(EmptyView()) }

            let step = w / CGFloat(data.count - 1)
            let clampedMax = max(maxValue, 0.001)
            let points: [CGPoint] = data.enumerated().map { i, val in
                CGPoint(x: CGFloat(i) * step,
                        y: h - (CGFloat(min(val, clampedMax) / clampedMax) * h))
            }

            return AnyView(
                ZStack {
                    // Horizontal grid lines (faint)
                    ForEach(1..<4, id: \.self) { i in
                        Path { path in
                            let y = h * CGFloat(i) / 4
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: w, y: y))
                        }
                        .stroke(color.opacity(0.06), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    }

                    // Stepped fill (bar chart style)
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: h))
                        for (i, pt) in points.enumerated() {
                            let barW = step
                            let x = CGFloat(i) * step
                            path.addLine(to: CGPoint(x: x, y: pt.y))
                            path.addLine(to: CGPoint(x: x + barW, y: pt.y))
                        }
                        path.addLine(to: CGPoint(x: w, y: h))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(
                        colors: [color.opacity(0.18), color.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom
                    ))

                    // Stepped line (sharp edges, no smooth curves)
                    Path { path in
                        for (i, pt) in points.enumerated() {
                            let x = CGFloat(i) * step
                            if i == 0 {
                                path.move(to: CGPoint(x: x, y: pt.y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: pt.y))
                            }
                            path.addLine(to: CGPoint(x: x + step, y: pt.y))
                        }
                    }
                    .stroke(color.opacity(0.7), lineWidth: 1)

                    // Glow on last point
                    if let last = points.last {
                        Circle()
                            .fill(color)
                            .frame(width: 4, height: 4)
                            .position(last)
                            .shadow(color: color.opacity(0.6), radius: 4)
                        Circle()
                            .fill(color.opacity(livePulse ? 0.3 : 0))
                            .frame(width: 10, height: 10)
                            .position(last)
                            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: livePulse)
                    }
                }
                .onAppear { livePulse = true }
            )
        }
    }
}
