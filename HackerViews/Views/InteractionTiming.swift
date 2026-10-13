#if os(macOS) && DEBUG
import AppKit
import QuartzCore

/// Times an interaction in the running app, such as a section switch
/// (`section.switch`) or opening the note editor (`note.open`), and writes it
/// to the debug performance trace with the caller's fields, all in
/// milliseconds from the timestamp of the input that made it (`input` names
/// its kind):
///
/// - `actionMs`: the app handles the input.
/// - `commitMs`: the end of the switch's own work, the first run of busy
///   main-thread passes after the action (its view update, layout and
///   commit); `cpuMs` is the main thread's CPU time from the action to then.
/// - `frameMs`: the target time of the first display refresh at or after
///   that, when the change is expected on screen.
/// - `settledMs`: the end of the last main-thread pass that did measurable
///   work within the observation window, which includes toolbar animation
///   and anything else the switch set off; `busyPasses` and `busyCpuMs` count
///   those passes and their CPU time.
@MainActor final class InteractionTiming: NSObject {
    private static var current: InteractionTiming?
    /// A pass that uses less main-thread CPU than this counts as idle.
    private static let busyThreshold = 0.25
    private static let window = 0.8

    private let event: String
    private let fields: [String: Any]
    private let input: CFTimeInterval
    private let inputKind: String
    private let action = CACurrentMediaTime()
    private let actionCPU = InteractionTiming.threadCPU()
    private var observer: CFRunLoopObserver?
    private var displayLink: CADisplayLink?
    private var commit: CFTimeInterval?
    private var commitCPU = 0.0
    private var firstBurstOver = false
    private var refreshes: [CFTimeInterval] = []
    private var lastPassCPU: Double
    private var settled: CFTimeInterval
    private var busyPasses = 0
    private var busyCPU = 0.0

    /// Times from an AppKit event.
    static func begin(_ event: String, _ fields: [String: Any], input: NSEvent?, view: NSView?) {
        let kind: String
        switch input?.type {
        case .leftMouseDown?: kind = "mouseDown"
        case .leftMouseUp?: kind = "mouseUp"
        case .keyDown?: kind = "keyDown"
        case nil: kind = "none"
        default: kind = "other"
        }
        begin(event, fields, input: input?.timestamp ?? CACurrentMediaTime(), inputKind: kind, view: view)
    }

    /// Times from a wall-clock time, such as a page event's, in seconds since 1970.
    static func begin(_ event: String, _ fields: [String: Any], since1970: Double, inputKind: String, view: NSView?) {
        let input = CACurrentMediaTime() - (Date().timeIntervalSince1970 - since1970)
        begin(event, fields, input: input, inputKind: inputKind, view: view)
    }

    private static func begin(_ event: String, _ fields: [String: Any], input: CFTimeInterval, inputKind: String, view: NSView?) {
        current?.finish()
        let timing = InteractionTiming(event: event, fields: fields, input: input, inputKind: inputKind)
        current = timing
        timing.start(view: view)
    }

    private init(event: String, fields: [String: Any], input: CFTimeInterval, inputKind: String) {
        self.event = event; self.fields = fields; self.input = input; self.inputKind = inputKind
        lastPassCPU = actionCPU
        settled = action
    }

    private static func threadCPU() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }

    private func start(view: NSView?) {
        // Runs after Core Animation's commit observer in each pass.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.pass() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        if let view {
            let link = view.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.window) { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    private func pass() {
        let now = CACurrentMediaTime(), cpu = Self.threadCPU()
        let used = cpu - lastPassCPU
        lastPassCPU = cpu
        if used >= Self.busyThreshold {
            busyPasses += 1; busyCPU += used; settled = now
            if !firstBurstOver { commit = now; commitCPU = cpu - actionCPU }
        } else if commit != nil {
            firstBurstOver = true
        } else if !firstBurstOver {
            // Too little work to count as busy: the first pass stands in.
            commit = now; commitCPU = cpu - actionCPU; firstBurstOver = true
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        if refreshes.count < 240 { refreshes.append(link.targetTimestamp) }
    }

    private func finish() {
        guard observer != nil || displayLink != nil else { return }
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        displayLink?.invalidate(); displayLink = nil
        if Self.current === self { Self.current = nil }
        func ms(_ time: CFTimeInterval?) -> Double { time.map { ($0 - input) * 1000 } ?? -1 }
        let frame = commit.flatMap { commit in refreshes.first { $0 >= commit } }
        ReaderTrace.event(event, fields.merging([
            "input": inputKind,
            "actionMs": ms(action), "commitMs": ms(commit), "cpuMs": commitCPU,
            "frameMs": ms(frame), "settledMs": ms(settled),
            "busyPasses": busyPasses, "busyCpuMs": busyCPU,
        ]) { _, timing in timing })
    }
}
#endif
