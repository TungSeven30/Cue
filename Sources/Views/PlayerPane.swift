import AVKit
import SwiftUI

/// Owns the AVPlayer and tracks which subtitle segment is under the
/// playhead. Publishes only on segment boundaries (not every time tick), so
/// observing views re-render a few times per minute, not 4x per second.
@MainActor
final class PlayerController: ObservableObject {
    private final class TimeObserverLifetime: @unchecked Sendable {
        let player: AVPlayer
        var token: Any?
        var boundaryToken: Any?

        init(player: AVPlayer) {
            self.player = player
        }

        deinit {
            if let token {
                player.removeTimeObserver(token)
            }
            if let boundaryToken {
                player.removeTimeObserver(boundaryToken)
            }
        }
    }

    let player: AVPlayer
    @Published private(set) var activeSegmentID: Int?
    @Published private(set) var overlayText = ""

    private var segments: [TranscriptionSegment] = []
    private var maximumEnds: [Double] = []
    private var currentURL: URL?
    private let timeObserverLifetime: TimeObserverLifetime

    init() {
        let player = AVPlayer()
        let lifetime = TimeObserverLifetime(player: player)
        self.player = player
        timeObserverLifetime = lifetime
        lifetime.token = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh(at: self.player.currentTime().seconds)
            }
        }
    }

    func load(url: URL) {
        guard url != currentURL else { return }
        currentURL = url
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        activeSegmentID = nil
        overlayText = ""
    }

    /// The segments the overlay and highlight follow — the original
    /// transcript or the translation, depending on the visible tab.
    func updateSegments(_ newSegments: [TranscriptionSegment]) {
        // The same array instance as last time (a re-render, not a change):
        // nothing to sort or refresh.
        if newSegments.count == segments.count,
            newSegments.withUnsafeBufferPointer({ new in
                segments.withUnsafeBufferPointer { $0.baseAddress == new.baseAddress }
            })
        {
            return
        }
        // The binary search below requires ordering by start time; backends
        // emit segments in order today, but nothing in the Swift layer
        // enforces it.
        let isSorted = zip(newSegments, newSegments.dropFirst()).allSatisfy { $0.start <= $1.start }
        segments = isSorted ? newSegments : newSegments.sorted { $0.start < $1.start }
        var maximumEnd = -Double.infinity
        maximumEnds = segments.map {
            maximumEnd = max(maximumEnd, $0.end)
            return maximumEnd
        }
        if let token = timeObserverLifetime.boundaryToken {
            player.removeTimeObserver(token)
            timeObserverLifetime.boundaryToken = nil
        }
        // Let the media clock trigger cue transitions. The periodic observer
        // remains a fallback for native scrubbing, not the timing authority.
        let boundaries = Set(segments.flatMap { [$0.start, $0.end] })
            .filter { $0.isFinite && $0 >= 0 }.sorted()
        if !boundaries.isEmpty {
            timeObserverLifetime.boundaryToken = player.addBoundaryTimeObserver(
                forTimes: boundaries.map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 1_000_000)) },
                queue: .main
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refresh(at: self.player.currentTime().seconds)
                }
            }
        }
        refresh(at: player.currentTime().seconds)
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let seconds = max(0, seconds)
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 1_000_000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        // The periodic observer does not reliably fire for a seek while
        // paused, so update the highlight and overlay right away.
        refresh(at: seconds)
    }

    func pause() {
        player.pause()
    }

    private func refresh(at time: Double) {
        let segment = time.isFinite ? segment(at: time) : nil
        if segment?.id != activeSegmentID {
            activeSegmentID = segment?.id
        }
        let text = segment?.text ?? ""
        if text != overlayText {
            overlayText = text
        }
    }

    /// Binary search for the segment whose [start, end) contains `time`.
    /// Prefer the latest-starting active cue, then recover a longer cue when
    /// a shorter overlapping cue ends. Prefix maxima bound the backward scan.
    private func segment(at time: Double) -> TranscriptionSegment? {
        var low = 0
        var high = segments.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if segments[mid].start <= time {
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        while high >= 0, maximumEnds[high] > time {
            if time < segments[high].end { return segments[high] }
            high -= 1
        }
        return nil
    }
}

/// Subtitle text drawn over the video. Lives inside AVPlayerView's
/// contentOverlayView so it follows the player into native full screen;
/// a plain SwiftUI sibling would stay behind in the window.
private struct SubtitleOverlay: View {
    @ObservedObject var controller: PlayerController

    var body: some View {
        GeometryReader { proxy in
            VStack {
                Spacer()
                if !controller.overlayText.isEmpty {
                    Text(controller.overlayText)
                        // Scale with the video: 16pt reads fine in the
                        // preview pane but vanishes on a full 27" screen.
                        .font(.system(size: max(16, proxy.size.height * 0.035), weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                        .padding(.bottom, 56)
                        .padding(.horizontal, 24)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .allowsHitTesting(false)
    }
}

/// NSHostingView that never claims clicks, so the playback controls under
/// the subtitle overlay keep working.
private final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// AppKit-backed player view. The SwiftUI `VideoPlayer` wrapper crashes at
/// metadata-initialization time in SwiftPM-built apps on macOS 26, so embed
/// AVKit's AVPlayerView directly.
private struct PlayerViewRepresentable: NSViewRepresentable {
    let controller: PlayerController

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = controller.player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        if let overlay = view.contentOverlayView {
            let host = PassThroughHostingView(rootView: SubtitleOverlay(controller: controller))
            host.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                host.topAnchor.constraint(equalTo: overlay.topAnchor),
                host.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            ])
        }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== controller.player {
            view.player = controller.player
        }
    }
}

/// Video preview; the subtitle overlay rides inside the player view so it
/// survives the native full-screen presentation.
struct PlayerPane: View {
    @ObservedObject var controller: PlayerController

    var body: some View {
        PlayerViewRepresentable(controller: controller)
            .frame(maxWidth: .infinity)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
