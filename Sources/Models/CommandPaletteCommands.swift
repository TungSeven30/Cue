import Foundation

// The palette's command inventory as pure data. Nothing here touches
// AppModel, AppKit, or the file system: `PaletteContext` is a value snapshot
// of the model's capability flags, and `PaletteCatalog` maps a command plus a
// context to its title, shortcut, and availability. AppModel+CommandPalette
// builds the context from the very properties the menus already read, so a
// palette row can never disagree with its menu item.

/// A keyboard shortcut as drawn in a row (glyphs) and spoken by VoiceOver.
struct PaletteShortcut: Equatable, Hashable, Sendable {
    let glyphs: String
    let spoken: String

    /// Modifiers are always written in the macOS order: ⌃ ⌥ ⇧ ⌘.
    init(
        key: String,
        spokenKey: String? = nil,
        control: Bool = false,
        option: Bool = false,
        shift: Bool = false,
        command: Bool = true
    ) {
        var glyphs = ""
        var words: [String] = []
        if control {
            glyphs += "⌃"
            words.append("Control")
        }
        if option {
            glyphs += "⌥"
            words.append("Option")
        }
        if shift {
            glyphs += "⇧"
            words.append("Shift")
        }
        if command {
            glyphs += "⌘"
            words.append("Command")
        }
        glyphs += key
        words.append(spokenKey ?? key)
        self.glyphs = glyphs
        self.spoken = words.joined(separator: " ")
    }
}

/// Whether a command can run right now. `hidden` is for commands whose
/// backing surface does not exist (no Sparkle updater outside the app), so
/// the palette never offers something it cannot do.
enum PaletteAvailability: Equatable, Sendable {
    case enabled
    case disabled(reason: String)
    case hidden

    var isEnabled: Bool { self == .enabled }
    var isHidden: Bool { self == .hidden }

    var reason: String? {
        if case .disabled(let reason) = self { return reason }
        return nil
    }
}

enum PaletteCommandID: String, CaseIterable, Hashable, Sendable {
    // File menu, in menu order.
    case primaryAction
    case addFiles
    case addFromURL
    case loadSubtitles
    case startAll
    case transcribe
    case translate
    case writeSummary
    case stopAll
    case exportSheet
    case exportTranscriptSRT
    case exportTranslationSRT
    case exportBilingualSRT
    case exportLog
    // Toolbar and job context menu.
    case retryTranscribe
    case toggleVideoPreview
    case jobSettings
    case burnIn
    case revealInFinder
    // Environment and app.
    case runDiagnostics
    case openSetupGuide
    case checkForUpdates
    case openSettings
}

/// The snapshot a command's title and availability are derived from.
/// `can…` flags are copied verbatim from AppModel; the remaining facts only
/// choose the wording of a disabled reason. Defaults describe nothing at all
/// (no job, nothing running), not the live app.
struct PaletteContext: Equatable, Sendable {
    var selectedJobTitle: String?
    var selectedJobStatus: JobStatus?
    var hasTranscript = false
    var hasTranslation = false

    var isProcessing = false
    var isGeneratingSummary = false
    var isLoadingSubtitles = false
    var isRunningDiagnostics = false
    var isTranslationReady = false
    var isSummaryReady = false
    var hasPendingWork = false
    var queuePaused = false
    var isPlayerVisible = false
    var canCheckForUpdates = false

    var canPerformPrimaryAction = false
    var canLoadSubtitles = false
    var canTranscribe = false
    var canTranslate = false
    var canGenerateSummary = false
    var canCancel = false
    var canBurnIn = false

    var primaryActionTitle = "Open Video"
    var primaryActionSymbol = "folder"
    var translationExportTitle = "Translation"
    var bilingualExportTitle = "Bilingual Captions"

    static let empty = PaletteContext()

    var hasSelectedJob: Bool { selectedJobTitle != nil }
    var isSelectedJobRunning: Bool { selectedJobStatus?.isRunning == true }
    var isSelectedJobQueued: Bool { selectedJobStatus == .queued }
}

/// Everything a row needs to know about a command that does not depend on
/// the search.
struct PaletteCommandSpec: Equatable, Sendable {
    let id: PaletteCommandID
    let title: String
    let symbol: String
    /// Where the same action lives in the app's own chrome.
    let menuPath: String
    let shortcut: PaletteShortcut?
    /// Extra words the search matches besides the title.
    let keywords: [String]
    /// Position in the empty-query suggestions; nil when never suggested.
    let suggestionRank: Int?
}

enum PaletteCatalog {
    static func spec(for id: PaletteCommandID, in context: PaletteContext) -> PaletteCommandSpec {
        func make(
            _ title: String,
            _ symbol: String,
            _ menuPath: String,
            shortcut: PaletteShortcut? = nil,
            keywords: [String],
            rank: Int? = nil
        ) -> PaletteCommandSpec {
            PaletteCommandSpec(
                id: id,
                title: title,
                symbol: symbol,
                menuPath: menuPath,
                shortcut: shortcut,
                keywords: keywords,
                suggestionRank: rank
            )
        }

        switch id {
        case .primaryAction:
            // "Next Step:" keeps this row distinct from the specific
            // Transcribe / Translate / Export commands it duplicates in effect.
            return make(
                "Next Step: \(context.primaryActionTitle)",
                context.primaryActionSymbol,
                "File menu",
                shortcut: PaletteShortcut(key: "⏎", spokenKey: "Return"),
                keywords: ["primary action", "next", "continue", "go", "toolbar button"],
                rank: 0
            )
        case .addFiles:
            return make(
                "Add Files…", "folder.badge.plus", "File menu",
                shortcut: PaletteShortcut(key: "O"),
                keywords: ["open", "import", "video", "audio", "media", "choose", "browse"],
                rank: 1
            )
        case .addFromURL:
            return make(
                "Add from URL…", "link.badge.plus", "File menu",
                shortcut: PaletteShortcut(key: "L"),
                keywords: ["download", "link", "web", "youtube", "yt-dlp", "remote", "paste"],
                rank: 2
            )
        case .loadSubtitles:
            return make(
                "Load Subtitles…", "captions.bubble", "File menu",
                shortcut: PaletteShortcut(key: "O", shift: true),
                keywords: ["srt", "vtt", "import subtitles", "captions", "sidecar", "existing"]
            )
        case .startAll:
            return make(
                "Start All", "play.circle", "File menu",
                shortcut: PaletteShortcut(key: "R", shift: true),
                keywords: ["queue", "run all", "resume", "begin", "process", "pending"],
                rank: 3
            )
        case .transcribe:
            return make(
                "Transcribe", "waveform", "File menu",
                shortcut: PaletteShortcut(key: "R"),
                keywords: ["speech", "recognize", "whisper", "run", "subtitles"]
            )
        case .translate:
            return make(
                "Translate", "character.bubble", "File menu",
                shortcut: PaletteShortcut(key: "T"),
                keywords: ["language", "convert", "subtitles"]
            )
        case .writeSummary:
            return make(
                "Write Intro Summary", "text.alignleft", "File menu",
                keywords: ["summarize", "summary", "overview", "intro", "description"]
            )
        case .stopAll:
            return make(
                "Stop All Jobs", "stop.fill", "File menu",
                shortcut: PaletteShortcut(key: ".", spokenKey: "Period"),
                keywords: ["cancel", "pause", "halt", "abort", "kill", "queue"],
                rank: 4
            )
        case .exportSheet:
            return make(
                "Export…", "square.and.arrow.up", "File menu",
                shortcut: PaletteShortcut(key: "E"),
                keywords: ["save", "subtitles", "captions", "srt", "vtt", "burn", "share", "output"],
                rank: 5
            )
        case .exportTranscriptSRT:
            return make(
                "Export Transcript SRT", "doc.plaintext", "File menu",
                keywords: ["save", "subtitles", "captions", "original", "srt"]
            )
        case .exportTranslationSRT:
            return make(
                "Export \(context.translationExportTitle) SRT", "doc.plaintext", "File menu",
                keywords: ["save", "translated", "subtitles", "captions", "srt"]
            )
        case .exportBilingualSRT:
            return make(
                "Export \(context.bilingualExportTitle) SRT", "doc.on.doc", "File menu",
                keywords: ["save", "both languages", "dual", "subtitles", "captions", "srt"]
            )
        case .exportLog:
            return make(
                "Export Log…", "doc.text.magnifyingglass", "File menu",
                keywords: ["save", "debug", "diagnostics", "text", "report"]
            )
        case .retryTranscribe:
            return make(
                "Retry Transcribe", "arrow.clockwise", "Toolbar",
                keywords: ["redo", "again", "from scratch", "re-transcribe", "restart"]
            )
        case .toggleVideoPreview:
            return make(
                context.isPlayerVisible ? "Hide Video Preview" : "Show Video Preview",
                context.isPlayerVisible ? "play.rectangle.fill" : "play.rectangle",
                "Toolbar",
                keywords: ["player", "video", "preview", "hide", "show", "toggle"]
            )
        case .jobSettings:
            return make(
                "Job Settings…", "slider.horizontal.3", "Job context menu",
                keywords: ["override", "language", "options", "per job", "model", "configure"]
            )
        case .burnIn:
            return make(
                "Burn In Video…", "film", "Job context menu",
                keywords: ["hardcode", "encode", "render", "subtitles into video", "open captions"]
            )
        case .revealInFinder:
            return make(
                "Open Destination Folder", "folder", "Job context menu",
                keywords: ["reveal", "finder", "show", "location", "where", "open folder"]
            )
        case .runDiagnostics:
            return make(
                "Check Environment", "stethoscope", "Setup",
                keywords: ["diagnostics", "recheck", "ffmpeg", "whisper", "tools", "health", "doctor"]
            )
        case .openSetupGuide:
            return make(
                "Open Setup Guide", "checklist", "Setup",
                keywords: ["install", "getting started", "requirements", "help", "missing tools"]
            )
        case .checkForUpdates:
            return make(
                "Check for Updates…", "arrow.down.circle", "Cue menu",
                keywords: ["update", "upgrade", "new version", "sparkle", "release"]
            )
        case .openSettings:
            return make(
                "Open Settings…", "gearshape", "Cue menu",
                shortcut: PaletteShortcut(key: ",", spokenKey: "Comma"),
                keywords: ["preferences", "prefs", "options", "configure", "settings"]
            )
        }
    }

    /// Every command the palette knows, in menu order, with hidden ones
    /// already dropped.
    static func specs(in context: PaletteContext) -> [PaletteCommandSpec] {
        PaletteCommandID.allCases.compactMap { id in
            availability(of: id, in: context).isHidden ? nil : spec(for: id, in: context)
        }
    }

    // MARK: - Availability

    /// The menu's own flag decides; the wording of the reason only explains a
    /// "no". A disabled row therefore always matches its disabled menu item.
    static func availability(of id: PaletteCommandID, in context: PaletteContext) -> PaletteAvailability {
        func gate(_ isOn: Bool, _ reason: @autoclosure () -> String) -> PaletteAvailability {
            isOn ? .enabled : .disabled(reason: reason())
        }

        switch id {
        case .addFiles, .addFromURL, .openSetupGuide, .openSettings:
            return .enabled
        case .checkForUpdates:
            return context.canCheckForUpdates ? .enabled : .hidden
        case .primaryAction:
            return gate(context.canPerformPrimaryAction, primaryActionReason(context))
        case .loadSubtitles:
            return gate(context.canLoadSubtitles, loadSubtitlesReason(context))
        case .startAll:
            return gate(context.hasPendingWork || context.queuePaused, "Nothing is waiting to run")
        case .transcribe, .retryTranscribe:
            return gate(context.canTranscribe, jobBusyReason(context) ?? "Not available right now")
        case .translate:
            return gate(context.canTranslate, translateReason(context))
        case .writeSummary:
            return gate(context.canGenerateSummary, summaryReason(context))
        case .stopAll:
            return gate(context.canCancel, "Nothing is running")
        case .exportSheet, .exportTranscriptSRT:
            return gate(context.hasTranscript, noTranscriptReason(context))
        case .exportTranslationSRT, .exportBilingualSRT:
            return gate(context.hasTranslation, noTranslationReason(context))
        case .exportLog, .toggleVideoPreview, .revealInFinder:
            return gate(context.hasSelectedJob, "Select a job first")
        case .jobSettings:
            // The sidebar disables this for a running job only.
            return gate(
                context.hasSelectedJob && !context.isSelectedJobRunning,
                context.hasSelectedJob ? "Settings can't change while the job runs" : "Select a job first"
            )
        case .burnIn:
            return gate(context.canBurnIn, burnInReason(context))
        case .runDiagnostics:
            return gate(!context.isRunningDiagnostics, "Already checking")
        }
    }

    // MARK: - Reasons

    private static func jobBusyReason(_ context: PaletteContext) -> String? {
        guard context.hasSelectedJob else { return "Select a job first" }
        if context.isSelectedJobRunning { return "The selected job is still running" }
        if context.isSelectedJobQueued { return "The selected job is waiting in the queue" }
        return nil
    }

    private static func noTranscriptReason(_ context: PaletteContext) -> String {
        context.hasSelectedJob ? "The selected job has no transcript yet" : "Select a job first"
    }

    private static func noTranslationReason(_ context: PaletteContext) -> String {
        context.hasSelectedJob ? "The selected job has no translation yet" : "Select a job first"
    }

    private static func primaryActionReason(_ context: PaletteContext) -> String {
        if let busy = jobBusyReason(context) { return busy }
        if context.hasTranscript, !context.hasTranslation, !context.isTranslationReady {
            return "No translation model or API key is set up yet"
        }
        return "Not available right now"
    }

    private static func loadSubtitlesReason(_ context: PaletteContext) -> String {
        if let busy = jobBusyReason(context) { return busy }
        if context.isLoadingSubtitles { return "Another subtitle file is still loading" }
        return "Not available right now"
    }

    private static func translateReason(_ context: PaletteContext) -> String {
        guard context.hasSelectedJob else { return "Select a job first" }
        if !context.hasTranscript { return "Transcribe the selected job first" }
        if let busy = jobBusyReason(context) { return busy }
        if !context.isTranslationReady { return "No translation model or API key is set up yet" }
        return "Not available right now"
    }

    private static func summaryReason(_ context: PaletteContext) -> String {
        guard context.hasSelectedJob else { return "Select a job first" }
        if !context.hasTranscript { return "Transcribe the selected job first" }
        if context.isSelectedJobRunning { return "The selected job is still running" }
        if context.isGeneratingSummary { return "A summary is already being written" }
        if !context.isSummaryReady { return "No summary model or API key is set up yet" }
        return "Not available right now"
    }

    private static func burnInReason(_ context: PaletteContext) -> String {
        guard context.hasSelectedJob else { return "Select a job first" }
        if !context.hasTranscript { return "Transcribe the selected job first" }
        if context.isProcessing || context.isSelectedJobRunning { return "Wait for running jobs to finish" }
        return "Not available right now"
    }
}
