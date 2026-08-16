import Darwin
import Dispatch
import Foundation

final class FileSystemWatcher {
    typealias Event = DispatchSource.FileSystemEvent

    private let url: URL
    private let handler: (Event) -> Void
    private let queue = DispatchQueue(label: "dev.margin.filesystem-watcher", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var pendingDelivery: DispatchWorkItem?

    init(url: URL, handler: @escaping (Event) -> Void) {
        self.url = url
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() {
        guard source == nil else { return }

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let events = source?.data else { return }
            self.scheduleDelivery(of: events)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        pendingDelivery?.cancel()
        pendingDelivery = nil
        source?.cancel()
        source = nil
    }

    private func scheduleDelivery(of events: Event) {
        pendingDelivery?.cancel()
        let handler = self.handler
        let delivery = DispatchWorkItem {
            DispatchQueue.main.async {
                handler(events)
            }
        }
        pendingDelivery = delivery
        queue.asyncAfter(deadline: .now() + .milliseconds(180), execute: delivery)
    }
}
