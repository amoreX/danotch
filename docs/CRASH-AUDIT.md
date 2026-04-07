# Danotch App — Crash & Stability Audit

**Date**: 2026-04-07  
**Symptom**: App crashes when switching between views quickly

---

## CRITICAL (Will Crash)

### 1. Force Unwrap on Task Lookup — `NotchViewModel.swift:322`

```swift
let taskId = tasks.first(where: { $0.threadId == threadId || $0.id == threadId })!.id
```

**Why it crashes**: When switching views fast, `tasks` array may be mid-mutation from a WebSocket event or haven't loaded yet. If `first(where:)` returns `nil`, the `!` crashes immediately.

**Fix**: Use `guard let` or optional chaining.

---

### 2. Missing `deinit` in NotchViewModel — `NotchViewModel.swift:144-145`

```swift
private var clockTimer: Timer?    // fires every 1s
private var shimmerTimer: Timer?  // fires every 4s
```

**Why it crashes**: `NotchViewModel` has **no `deinit`**. These timers never get invalidated. If the ViewModel is deallocated while timers are live, the closure fires on freed memory. Even with `[weak self]`, the timer object itself leaks.

**Fix**: Add `deinit { clockTimer?.invalidate(); shimmerTimer?.invalidate() }`.

---

### 3. Global Event Monitor Leaked — `DotGridView.swift:88`

```swift
NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
    self?.globalPosition = NSEvent.mouseLocation
}
```

**Why it crashes**: The return value (the monitor token) is **never stored**, so it can never be removed. The `deinit` on line 115 only removes the local monitor. This leaks an event monitor every time `DotGridView` is recreated — which happens on every expand/collapse cycle. Accumulates rapidly.

**Fix**: Store in a second property, remove in `deinit`.

---

### 4. NotificationCenter Observer Never Removed — `NotchWindow.swift:88-93`

```swift
NotificationCenter.default.addObserver(
    self,
    selector: #selector(screenChanged),
    name: NSApplication.didChangeScreenParametersNotification,
    object: nil
)
```

**Why it crashes**: The `deinit` on line 266 removes event monitors but **never calls `NotificationCenter.default.removeObserver(self)`**. If screen parameters change after controller dealloc, the selector dispatches to a dangling pointer → `EXC_BAD_ACCESS`.

**Fix**: Add `NotificationCenter.default.removeObserver(self)` to `deinit`.

---

## HIGH (Likely Contributes to Crashes)

### 5. Division by Zero — `NotchViewModel.swift:231`

```swift
return task.activitySteps[shimmerStep % task.activitySteps.count]
```

**Risk**: If `activitySteps` is empty (count == 0), modulo by zero crashes. There's a guard above checking `!task.activitySteps.isEmpty`, but if the array is mutated between the guard and this line by a concurrent WebSocket update, it's a race.

**Fix**: Re-check count at point of use or copy the array first.

---

### 6. Force Unwrap on URLs — `NotchViewModel.swift` (7 locations)

```
Line 272: URL(string: "http://localhost:3001/api/threads")!
Line 327: URL(string: "http://localhost:3001/api/threads/\(threadId)")!
Line 410: URL(string: "http://localhost:3001/api/notifications")!
Line 444: URL(string: "http://localhost:3001/api/notifications/unread-count")!
Line 464: URL(string: "http://localhost:3001/api/notifications/\(id)/read")!
Line 478: URL(string: "http://localhost:3001/api/notifications/read-all")!
Line 495: URL(string: "http://localhost:3001/api/scheduled")!
```

**Risk**: These are hardcoded and currently valid, so they won't crash *today*. But if any URL string becomes malformed (e.g., a `threadId` or `id` contains spaces or special chars), `URL(string:)` returns nil and `!` crashes.

**Fix**: Use `guard let url = URL(string: ...)` or a helper.

---

### 7. NSScreen Array Access — `NotchShellView.swift:8`

```swift
private var screen: NSScreen { NSScreen.main ?? NSScreen.screens[0] }
```

**Risk**: If `NSScreen.main` is nil AND `NSScreen.screens` is empty (e.g., headless context or display disconnect), `[0]` crashes. Rare but possible.

**Fix**: `NSScreen.main ?? NSScreen.screens.first ?? <fallback>`.

---

## MEDIUM (Contributes to Instability)

### 8. Pipe Read Order in AgentMonitor — `AgentMonitor.swift:406-420`

```swift
let data = pipe.fileHandleForReading.readDataToEndOfFile()
process.waitUntilExit()
```

**Note from CLAUDE.md**: The project docs explicitly warn about this pattern — "always read pipe data before calling `waitUntilExit()`". The current code does this correctly. However, `readDataToEndOfFile()` is a blocking call on a background thread. If the `ps` command hangs or produces massive output, this thread blocks indefinitely.

**Recommendation**: Add a timeout or use async file handle reading.

---

### 9. Non-Atomic @Published Array Mutations — `StatsPanel.swift:57-62`

```swift
cpuHistory.append(cpuUsage)
if cpuHistory.count > 40 { cpuHistory.removeFirst() }
netDownHistory.append(netDown)
if netDownHistory.count > 40 { netDownHistory.removeFirst() }
```

**Risk**: Multiple `@Published` array mutations in sequence. SwiftUI may re-render the view between the `append` and `removeFirst`, seeing 41 elements momentarily. Won't crash but causes visual glitches and unnecessary renders.

**Fix**: Build new arrays, assign once.

---

### 10. BatteryView Timer in @State — `NotchShellView.swift:346-350`

```swift
@State private var timer: Timer?
// ...
timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
    DispatchQueue.main.async { updateBattery() }
}
```

**Risk**: `@State` in a nested struct view. If the parent re-renders and recreates `BatteryView`, the old timer may not get invalidated if `onDisappear` doesn't fire (which happens during rapid SwiftUI recomposition).

**Fix**: Move to an `ObservableObject` or use `.task` modifier with cancellation.

---

## LOW (Code Quality / Future Risk)

### 11. Double `[weak self]` Captures

In `NotchViewModel.swift:204-208` and `212-218`:

```swift
clockTimer = Timer.scheduledTimer(...) { [weak self] _ in
    DispatchQueue.main.async { [weak self] in  // redundant
```

The inner `[weak self]` is redundant — the outer one already ensures self is optional. Not a crash risk, just noise.

---

### 12. `parts` Array Access in AgentMonitor — `AgentMonitor.swift:435+`

```swift
guard let pid = Int32(parts[0]),
      let cpu = Double(parts[1]),
      let rssKB = Double(parts[2]) else { return nil }
let elapsed = parts[3]
let fullPath = parts[4...].joined(separator: " ")
```

The `guard` checks count >= 5 before this, so it's safe. But the split between guarded indices (0-2) and directly accessed indices (3-4) is fragile.

---

## Root Cause of "Crashes When Switching Fast"

The most likely crash sequence:

1. **User expands notch** → `DotGridView` created → leaks a global event monitor
2. **User switches to Stats** → `SystemStatsMonitor.sample()` starts
3. **User quickly switches to Agents** → Stats view deallocated mid-sample
4. **User taps a thread** → `loadThread()` hits line 322 force unwrap on potentially empty `tasks`
5. **Meanwhile**: leaked DotGridView monitors accumulate, clockTimer/shimmerTimer from ViewModel fire on stale state

The combination of **leaked monitors + missing deinit timers + force unwrap on line 322** creates a situation where rapid switching accumulates stale callbacks that eventually hit freed memory or nil values.

---

## Priority Fix Order

| Priority | Fix | Impact | Effort |
|----------|-----|--------|--------|
| P0 | Add `deinit` to `NotchViewModel` (invalidate timers) | Stops timer-related crashes | 2 min |
| P0 | Fix force unwrap on line 322 (`tasks.first!`) | Stops array crash | 2 min |
| P0 | Store + remove global monitor in `DotGridView` | Stops monitor leak accumulation | 5 min |
| P1 | Add `removeObserver(self)` to `NotchWindow.deinit` | Prevents screen-change crash | 1 min |
| P1 | Guard URL force unwraps (7 locations) | Prevents edge-case crashes | 10 min |
| P2 | Fix `NSScreen.screens[0]` to use `.first` | Prevents headless crash | 1 min |
| P2 | Re-check `activitySteps.count` at point of use | Prevents race condition | 2 min |
| P3 | Non-atomic array mutations in StatsPanel | Reduces visual glitches | 5 min |
| P3 | BatteryView timer lifecycle | Prevents timer leak | 5 min |
