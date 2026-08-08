import Foundation

/// Classifies job source paths against mounted volumes so the queue can wait
/// for an unplugged disk or dropped NAS share instead of failing jobs.
/// Deliberately checks only the mount table — never stat on the source path,
/// which can block for minutes on a stale SMB mount.
enum SourceVolume {
    /// "/Volumes/Media/movie.mkv" → "Media"; nil for internal-disk paths.
    static func volumeName(forPath path: String) -> String? {
        let components = path.split(separator: "/")
        guard components.count >= 2, components[0] == "Volumes" else { return nil }
        return String(components[1])
    }

    /// Internal-disk paths are always available; /Volumes paths need their
    /// volume in the mount table.
    static func isAvailable(path: String, mountedVolumeNames: Set<String>) -> Bool {
        guard let volume = volumeName(forPath: path) else { return true }
        return mountedVolumeNames.contains(volume)
    }

    /// Names currently under /Volumes (external disks and network shares).
    static func mountedVolumeNames() -> Set<String> {
        let urls =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: nil,
                options: [.skipHiddenVolumes]
            ) ?? []
        return Set(urls.compactMap { volumeName(forPath: $0.path) })
    }
}
