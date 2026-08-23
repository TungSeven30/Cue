import Foundation
import Testing
@testable import Cue

struct YtDlpInstallerTests {
    @Test func argumentsInstallYtDlpThroughBrew() {
        let arguments = YtDlpInstaller.makeArguments()
        #expect(arguments == ["install", "yt-dlp"])
    }

    @Test func findsHomebrewInAnInjectedLocation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-brew-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let brew = directory.appendingPathComponent("brew")
        try Data("#!/bin/sh\n".utf8).write(to: brew)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)

        // A non-executable file must not count as a usable Homebrew.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: brew.path)
        #expect(YtDlpInstaller.homebrewURL(searchPaths: [brew.path]) == nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        #expect(YtDlpInstaller.homebrewURL(searchPaths: [brew.path])?.path == brew.path)
    }

    @Test func missingHomebrewIsNil() {
        #expect(YtDlpInstaller.homebrewURL(searchPaths: []) == nil)
        #expect(YtDlpInstaller.homebrewURL(searchPaths: ["/cue/no/such/brew"]) == nil)
    }

    @Test func classifiesThePhasesBrewPrints() {
        #expect(YtDlpInstaller.progressDetail(from: "==> Auto-updating Homebrew…") == "Updating Homebrew…")
        #expect(YtDlpInstaller.progressDetail(from: "==> Downloading https://ghcr.io/…") == "Downloading yt-dlp…")
        #expect(YtDlpInstaller.progressDetail(from: "==> Fetching yt-dlp") == "Downloading yt-dlp…")
        #expect(YtDlpInstaller.progressDetail(from: "==> Pouring yt-dlp--2026.bottle.tar.gz") == "Unpacking yt-dlp…")
        #expect(YtDlpInstaller.progressDetail(from: "==> Installing yt-dlp") == "Installing yt-dlp…")
    }

    @Test func unclassifiedLinesPassThroughAndBlankLinesDrop() {
        #expect(YtDlpInstaller.progressDetail(from: "python@3.12 3.12.4") == "python@3.12 3.12.4")
        #expect(YtDlpInstaller.progressDetail(from: "  ==> Caveats  ") == "Caveats")
        #expect(YtDlpInstaller.progressDetail(from: "") == nil)
        #expect(YtDlpInstaller.progressDetail(from: "   ") == nil)
    }
}
