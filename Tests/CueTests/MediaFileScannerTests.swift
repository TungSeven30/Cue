import Foundation
import Testing
@testable import Cue

@Suite struct MediaFileScannerTests {
    /// Builds: root/{a.mkv, MOVIE.MP4, notes.txt, .hidden.mp4, show/{ep2.mp4, ep1.mp4, partial.mp4.part}, show/extras/{clip.mov}, .hiddendir/{secret.mp4}}
    private func makeFixtureTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-\(UUID().uuidString)", isDirectory: true)
        let show = root.appendingPathComponent("show", isDirectory: true)
        let extras = show.appendingPathComponent("extras", isDirectory: true)
        let hiddenDir = root.appendingPathComponent(".hiddendir", isDirectory: true)
        for dir in [root, show, extras, hiddenDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for name in ["a.mkv", "MOVIE.MP4", "notes.txt", ".hidden.mp4"] {
            FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: Data())
        }
        for name in ["ep2.mp4", "ep1.mp4", "partial.mp4.part"] {
            FileManager.default.createFile(atPath: show.appendingPathComponent(name).path, contents: Data())
        }
        FileManager.default.createFile(atPath: extras.appendingPathComponent("clip.mov").path, contents: Data())
        FileManager.default.createFile(atPath: hiddenDir.appendingPathComponent("secret.mp4").path, contents: Data())
        return root
    }

    @Test func collectsOnlyMediaRecursivelySorted() throws {
        let root = try makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let found = MediaFileTypes.collectMediaFiles(under: root)
        // Assert full relative paths, not lastPathComponent — the sorted
        // order across directories is part of the contract.
        let rootComponents = root.standardizedFileURL.pathComponents
        let relative = found.map { url -> String in
            let fileComponents = url.standardizedFileURL.pathComponents
            return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
        }
        #expect(relative == ["a.mkv", "MOVIE.MP4", "show/ep1.mp4", "show/ep2.mp4", "show/extras/clip.mov"])
    }

    @Test func emptyOrNonMediaFolderYieldsNothing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: root.appendingPathComponent("readme.md").path, contents: Data())
        #expect(MediaFileTypes.collectMediaFiles(under: root).isEmpty)
        #expect(MediaFileTypes.expandForAdd(urls: [root]).count == 0)
    }

    @Test func expandForAddMixesFilesAndFoldersInOrder() throws {
        let root = try makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let loose = root.appendingPathComponent("a.mkv")
        let folder = root.appendingPathComponent("show", isDirectory: true)
        let expanded = MediaFileTypes.expandForAdd(urls: [loose, folder])
        let names = expanded.map(\.lastPathComponent)
        #expect(names == ["a.mkv", "ep1.mp4", "ep2.mp4", "clip.mov"])
    }
}
