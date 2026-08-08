import Foundation
import Testing
@testable import Cue

@Suite struct SourceVolumeTests {
    @Test func extractsVolumeNameFromExternalPaths() {
        #expect(SourceVolume.volumeName(forPath: "/Volumes/Media/Films/movie.mkv") == "Media")
        #expect(SourceVolume.volumeName(forPath: "/Volumes/My NAS/x.mp4") == "My NAS")
    }

    @Test func internalPathsHaveNoVolumeAndAreAlwaysAvailable() {
        #expect(SourceVolume.volumeName(forPath: "/Users/x/Movies/a.mp4") == nil)
        #expect(SourceVolume.isAvailable(path: "/Users/x/Movies/a.mp4", mountedVolumeNames: []))
    }

    @Test func bareVolumesRootIsNotAVolume() {
        #expect(SourceVolume.volumeName(forPath: "/Volumes") == nil)
    }

    @Test func availabilityTracksTheMountTable() {
        #expect(SourceVolume.isAvailable(path: "/Volumes/Media/a.mkv", mountedVolumeNames: ["Media"]))
        #expect(!SourceVolume.isAvailable(path: "/Volumes/Media/a.mkv", mountedVolumeNames: ["Backup"]))
        #expect(!SourceVolume.isAvailable(path: "/Volumes/Media/a.mkv", mountedVolumeNames: []))
    }
}
