import AppKit
import AVKit
import Combine
import Darwin
import SwiftUI
@testable import Cue

private actor FixtureDiagnostics: EnvironmentDiagnosing {
    func run(translationAPIKey: String, translationProvider: TranslationProvider, selectedBackend: WhisperBackend) async -> [EnvironmentDiagnostic] { [] }
}

/// Links the current Cue objects and actual ContentView, replacing only the
/// entry point. Never shipped in Cue.app. No Keychain, updater, or orphan sweep.
@main
struct CueAuditHarness: App {
    @StateObject private var model: AppModel
    private let started = DispatchTime.now().uptimeNanoseconds
    private let root: URL
    private let measure: Bool

    init() {
        let data = try! Data(contentsOf: Bundle.main.url(forResource: "Fixture", withExtension: "plist")!)
        let configuration = try! PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: String]
        root = URL(fileURLWithPath: configuration["root"]!)
        measure = CommandLine.arguments.contains("--measure")
        precondition(Bundle.main.bundleIdentifier == "org.codex.CueAuditHarness", "Refusing to run in the production bundle")
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "autoStartAddedJobs")
        defaults.set(false, forKey: "followPlayback")
        defaults.set(true, forKey: "isPlayerVisible")
        defaults.set(280.0, forKey: "playerHeight")
        let settings = AppSettingsStore(defaults: defaults, readSecret: { _ in nil }, writeSecret: { _, _ in false })
        settings.sourceLanguage = "ja"
        settings.translationTargetLanguage = "Vietnamese"
        let store = JobStore(baseURL: root.appendingPathComponent("history"))
        var job = TranscriptionJob(sourceURL: URL(fileURLWithPath: configuration["media"]!), settings: settings)
        job.status = .translationComplete
        job.progress = JobProgress(stage: .complete, detail: "Japanese → Vietnamese", fraction: 1)
        job.transcriptSegments = (0..<45).map {
            TranscriptionSegment(id: $0 + 1, start: Double($0 * 2), end: Double($0 * 2) + 1.8,
                text: ["今日はとてもいい天気ですね。", "一緒に散歩に行きましょう。", "この景色は本当に美しいです。"][$0 % 3])
        }
        job.translatedSegments = job.transcriptSegments.enumerated().map { offset, cue in
            TranscriptionSegment(id: cue.id, start: cue.start, end: cue.end,
                text: ["Hôm nay thời tiết thật đẹp.", "Chúng ta cùng đi dạo nhé.", "Phong cảnh ở đây thật sự rất đẹp."][offset % 3])
        }
        job.log = "Synthetic Japanese → Vietnamese audit fixture. No inference or network requests.\n"
        store.saveJob(job)
        let ledger = WatchFolderLedger(baseURL: root.appendingPathComponent("history"))
        _model = StateObject(wrappedValue: AppModel(settings: settings, jobStore: store, watchLedger: ledger, diagnosticsService: FixtureDiagnostics()))
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Cue Audit", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1080, minHeight: 720)
                .task {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    guard measure else { return }
                    await recordMeasurements()
                }
        }
        .defaultSize(width: 1200, height: 860)
        .commands {
            CommandMenu("Audit Appearance") {
                Button("Light") { NSApp.appearance = NSAppearance(named: .aqua) }
                Button("Dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
                Button("High Contrast Light") { NSApp.appearance = NSAppearance(named: .accessibilityHighContrastAqua) }
                Button("High Contrast Dark") { NSApp.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua) }
            }
        }
    }

    @MainActor
    private func recordMeasurements() async {
        func milliseconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6 }
        let appeared = milliseconds()
        while model.isHydratingJobs { try? await Task.sleep(for: .milliseconds(1)) }
        model.playerController.player.isMuted = true
        // These markers describe model/view lifecycle, never first pixels.
        while model.playerController.overlayText.isEmpty && milliseconds() < 10_000 {
            try? await Task.sleep(for: .milliseconds(1))
        }
        let overlayReady = model.playerController.overlayText.isEmpty ? nil : milliseconds()
        try? await Task.sleep(for: .seconds(2))
        var idle: [Double] = []
        for _ in 0..<5 {
            idle.append(Self.footprintMiB())
            try? await Task.sleep(for: .milliseconds(200))
        }
        model.playerController.player.play()
        var samples: [[String: Double]] = []
        var priorCPU = Self.cpuSeconds()
        var priorTime = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<20 {
            try? await Task.sleep(for: .seconds(1))
            let now = DispatchTime.now().uptimeNanoseconds
            let cpu = Self.cpuSeconds()
            samples.append(["footprintMiB": Self.footprintMiB(), "cpuPercent": (cpu - priorCPU) / (Double(now - priorTime) / 1e9) * 100])
            priorCPU = cpu
            priorTime = now
        }
        model.playerController.player.pause()
        let values: [String: Any] = [
            "viewAppearedMs": appeared, "overlayModelReadyMs": overlayReady as Any? ?? NSNull(),
            "idleFootprintMiB": idle, "playbackSamples": samples,
            "mediaTimeSeconds": model.playerController.player.currentTime().seconds,
            "minimumRefreshInterval": NSScreen.main?.minimumRefreshInterval as Any? ?? NSNull(),
            "maximumRefreshInterval": NSScreen.main?.maximumRefreshInterval as Any? ?? NSNull(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("metrics.json"), options: .atomic)
        }
        NSApplication.shared.terminate(nil)
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    private static func footprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
