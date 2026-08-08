import Foundation
import Testing
@testable import Cue

@MainActor
struct WatchFolderCoordinatorTests {
    @Test func syncStartsRestartsAndStopsExactlyTheDesiredServices() throws {
        let firstPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-watch-coordinator-\(UUID().uuidString)", isDirectory: true)
        let secondPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-watch-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: firstPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondPath, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: firstPath)
            try? FileManager.default.removeItem(at: secondPath)
        }
        var folder = WatchFolder(path: firstPath.path)
        var changeCount = 0
        let coordinator = WatchFolderCoordinator(
            makeService: { _ in WatchFolderService() },
            onServiceChange: { changeCount += 1 }
        )

        coordinator.sync(folders: [folder])
        #expect(coordinator.services[folder.id]?.watchedPath == firstPath.path)

        folder.path = secondPath.path
        coordinator.sync(folders: [folder])
        #expect(coordinator.services[folder.id]?.watchedPath == secondPath.path)

        folder.enabled = false
        coordinator.sync(folders: [folder])
        #expect(coordinator.services.isEmpty)
        #expect(changeCount >= 3)
    }
}
