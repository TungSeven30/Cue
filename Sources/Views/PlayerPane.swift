import AVKit
import SwiftUI

/// Owns the AVPlayer and tracks which subtitle segment is under the
/// playhead. Publishes only on segment boundaries (not every time tick), so
/// observing views re-render a few times per minute, not 4x per second.
@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var activeSegmentID: Int?
    @Published private(set) var overlayText = ""

    private var segments: [TranscriptionSegment] = []
    private var currentURL: URL?
    private var timeObserver: Any?

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                self?.refresh(at: seconds)
            }
        }
    }

    deinit {
        // The controller currently lives for the app's lifetime (owned by
        // AppModel), but AVFoundation raises if a player deallocates with a
        // live observer, so remove it defensively.
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
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
        // The binary search below requires ordering by start time; backends
        // emit segments in order today, but nothing in the Swift layer
        // enforces it.
        let isSorted = zip(newSegments, newSegments.dropFirst()).allSatisfy { $0.start <= $1.start }
        segments = isSorted ? newSegments : newSegments.sorted { $0.start < $1.start }
        refresh(at: player.currentTime().seconds)
    }

    func seek(to seconds: Double) {
        player.seek(
            to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
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
        guard time.isFinite else { return }
        let segment = Self.segment(at: time, in: segments)
        if segment?.id != activeSegmentID {
            activeSegmentID = segment?.id
        }
        let text = segment?.text ?? ""
        if text != overlayText {
            overlayText = text
        }
    }

    /// Binary search for the segment whose [start, end) contains `time`.
    /// A seek to a segment's exact start can materialize a hair before it
    /// (CMTime rounding), so probe slightly ahead of the playhead.
    private static func segment(at time: Double, in segments: [TranscriptionSegment]) -> TranscriptionSegment? {
        let probe = time + 0.15
        var low = 0
        var high = segments.count - 1
        var candidate: TranscriptionSegment?
        while low <= high {
            let mid = (low + high) / 2
            if segments[mid].start <= probe {
                candidate = segments[mid]
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let candidate, time < candidate.end + 0.25 else { return nil }
        return candidate
    }
}

/// AppKit-backed player view. The SwiftUI `VideoPlayer` wrapper crashes at
/// metadata-initialization time in SwiftPM-built apps on macOS 26, so embed
/// AVKit's AVPlayerView directly.
private struct PlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}

/// Video preview with the current subtitle rendered over the picture.
struct PlayerPane: View {
    @ObservedObject var controller: PlayerController

    var body: some View {
        ZStack(alignment: .bottom) {
            PlayerViewRepresentable(player: controller.player)
            if !controller.overlayText.isEmpty {
                Text(controller.overlayText)
                    .font(.system(size: 16, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.bottom, 56)
                    .padding(.horizontal, 24)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
