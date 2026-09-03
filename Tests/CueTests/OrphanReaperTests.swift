import Foundation
import Testing
@testable import Cue

@Suite struct OrphanReaperTests {
    // ps -axo pid=,ppid=,command= output: pid, parent pid, then the command.
    @Test func matchesBackendPythonAndItsFfmpegChild() {
        let ps = """
              123     1 /opt/homebrew/bin/python3 /var/folders/t5/xx/T/cue_backend.py --job a
              456     1 ffmpeg -y -i /Volumes/Media/movie.mp4 -vn /var/folders/t5/xx/T/cue_abc12/audio.wav
              789     1 /usr/local/bin/node /Users/x/server.js
            """
        #expect(OrphanReaper.orphanPIDs(inPSOutput: ps) == [123, 456])
    }

    @Test func matchesLegacyWhisperDeskPrefixes() {
        let ps = "  42     1 ffmpeg -i in.mp4 /var/folders/t5/xx/T/whisperdesk_old_/audio.wav"
        #expect(OrphanReaper.orphanPIDs(inPSOutput: ps) == [42])
    }

    @Test func matchesBurnInTempDir() {
        let ps = "  77     1 ffmpeg -i movie.mkv -vf subtitles=/var/folders/t5/xx/T/cue-burnin-abc/subs.ass out.mp4"
        #expect(OrphanReaper.orphanPIDs(inPSOutput: ps) == [77])
    }

    // Homebrew's yt-dlp is a Python script, so ps shows the interpreter
    // (often version-suffixed) with the yt-dlp path and Cue's staging folder
    // among its arguments.
    @Test func matchesOrphanedYtDlpDownloads() {
        let ps = """
              91     1 /opt/homebrew/Cellar/python@3.13/3.13.2/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python /opt/homebrew/bin/yt-dlp --no-playlist -o /Users/x/Movies/Cue Downloads/.cue-download-ABC/%(title).150B.%(ext)s https://example.com/watch?v=1
              92     1 python3.13 /opt/homebrew/bin/yt-dlp -o /Users/x/Movies/Cue Downloads/.cue-download-DEF/%(title).150B.%(ext)s https://example.com/2
            """
        #expect(OrphanReaper.orphanPIDs(inPSOutput: ps) == [91, 92])
    }

    // A worker whose parent is still alive belongs to another running Cue —
    // the CLI beside the GUI, or a second instance — and must be left alone.
    @Test func ignoresWorkersWhoseParentIsAlive() {
        let ps = """
              123  4242 /opt/homebrew/bin/python3 /var/folders/t5/xx/T/cue_backend.py --job a
              456   123 ffmpeg -y -i /Volumes/Media/movie.mp4 -vn /var/folders/t5/xx/T/cue_abc12/audio.wav
            """
        #expect(OrphanReaper.orphanPIDs(inPSOutput: ps).isEmpty)
    }

    @Test func ignoresUnrelatedProcessesEvenWithMarkers() {
        // A non-worker binary mentioning our marker (e.g. an editor with the
        // script open, or grep itself) must never be killed.
        let ps = """
              11     1 /usr/bin/vim /var/folders/t5/xx/T/cue_backend.py
              12     1 grep cue_backend.py
              13     1 /Applications/Cue.app/Contents/MacOS/Cue
            """
        #expect(OrphanReaper.orphanPIDs(inPSOutput: ps).isEmpty)
    }

    @Test func ignoresWorkerBinariesDoingUnrelatedWork() {
        let ps = """
              21     1 ffmpeg -i /Users/x/personal.mp4 out.mp4
              22     1 /opt/homebrew/bin/python3 /Users/x/script.py
            """
        #expect(OrphanReaper.orphanPIDs(inPSOutput: ps).isEmpty)
    }
}
