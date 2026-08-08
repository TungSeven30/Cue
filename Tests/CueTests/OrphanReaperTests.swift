import Foundation
import Testing
@testable import Cue

@Suite struct OrphanReaperTests {
    @Test func matchesBackendPythonAndItsFfmpegChild() {
        let ps = """
          123 /opt/homebrew/bin/python3 /var/folders/t5/xx/T/cue_backend.py --job a
          456 ffmpeg -y -i /Volumes/Media/movie.mp4 -vn /var/folders/t5/xx/T/cue_abc12/audio.wav
          789 /usr/local/bin/node /Users/x/server.js
        """
        #expect(OrphanReaper.orphanPIDs(inPSOutput: ps) == [123, 456])
    }

    @Test func matchesLegacyWhisperDeskPrefixes() {
        let ps = "  42 ffmpeg -i in.mp4 /var/folders/t5/xx/T/whisperdesk_old_/audio.wav"
        #expect(OrphanReaper.orphanPIDs(inPSOutput: ps) == [42])
    }

    @Test func matchesBurnInTempDir() {
        let ps = "  77 ffmpeg -i movie.mkv -vf subtitles=/var/folders/t5/xx/T/cue-burnin-abc/subs.ass out.mp4"
        #expect(OrphanReaper.orphanPIDs(inPSOutput: ps) == [77])
    }

    @Test func ignoresUnrelatedProcessesEvenWithMarkers() {
        // A non-worker binary mentioning our marker (e.g. an editor with the
        // script open, or grep itself) must never be killed.
        let ps = """
          11 /usr/bin/vim /var/folders/t5/xx/T/cue_backend.py
          12 grep cue_backend.py
          13 /Applications/Cue.app/Contents/MacOS/Cue
        """
        #expect(OrphanReaper.orphanPIDs(inPSOutput: ps).isEmpty)
    }

    @Test func ignoresWorkerBinariesDoingUnrelatedWork() {
        let ps = """
          21 ffmpeg -i /Users/x/personal.mp4 out.mp4
          22 /opt/homebrew/bin/python3 /Users/x/script.py
        """
        #expect(OrphanReaper.orphanPIDs(inPSOutput: ps).isEmpty)
    }
}
