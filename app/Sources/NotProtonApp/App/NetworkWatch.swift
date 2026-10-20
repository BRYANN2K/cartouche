import Foundation
import Network

@MainActor
final class NetworkWatch {
    private let monitor = NWPathMonitor()

    func start(_ changed: @escaping @MainActor (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in
            let offline = path.status != .satisfied
            Task { @MainActor in changed(offline) }
        }
        monitor.start(queue: DispatchQueue(label: "cartouche.network"))
    }
}
