import Combine
import Foundation

/// Reconciles the desired watch-folder configuration with live services and
/// owns their observation lifetimes. AppModel supplies the domain-specific
/// callbacks when each service is constructed.
@MainActor
final class WatchFolderCoordinator {
    private let makeService: (UUID) -> WatchFolderService
    private let onServiceChange: () -> Void
    private var serviceObservers: [UUID: AnyCancellable] = [:]
    private(set) var services: [UUID: WatchFolderService] = [:]

    init(makeService: @escaping (UUID) -> WatchFolderService, onServiceChange: @escaping () -> Void) {
        self.makeService = makeService
        self.onServiceChange = onServiceChange
    }

    func sync(folders: [WatchFolder]) {
        let wanted = Dictionary(
            uniqueKeysWithValues:
                folders
                .filter { $0.enabled && !$0.path.isEmpty }
                .map { ($0.id, $0) }
        )

        for (id, service) in services where wanted[id] == nil {
            service.stop()
            services[id] = nil
            serviceObservers[id] = nil
        }
        for (id, folder) in wanted {
            if let existing = services[id] {
                if existing.watchedPath != folder.path {
                    existing.start(path: folder.path)
                }
            } else {
                let service = makeService(id)
                serviceObservers[id] = service.objectWillChange.sink { [onServiceChange] _ in
                    onServiceChange()
                }
                services[id] = service
                service.start(path: folder.path)
            }
        }
        onServiceChange()
    }

    func stopAll() {
        for service in services.values {
            service.stop()
        }
        services.removeAll()
        serviceObservers.removeAll()
        onServiceChange()
    }
}
