import Darwin
import Dispatch
import Foundation

final class FileSystemWatcher {
    typealias Event = DispatchSource.FileSystemEvent

    private let url: URL
    private let handler: (Event) -> Void
    private let descriptorOpener: (String) -> Int32
    private let queue = DispatchQueue(label: "dev.margin.filesystem-watcher", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var pendingDelivery: DispatchWorkItem?
    private var isStarting = false
    private var startGeneration = 0

    init(
        url: URL,
        descriptorOpener: @escaping (String) -> Int32 = {
            open($0, O_EVTONLY | O_NONBLOCK)
        },
        handler: @escaping (Event) -> Void
    ) {
        self.url = url
        self.descriptorOpener = descriptorOpener
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() {
        guard source == nil, !isStarting else { return }
        isStarting = true
        startGeneration += 1
        let generation = startGeneration
        let path = url.path
        let opener = descriptorOpener

        // File-provider and network-backed directories are allowed to block in
        // `open(2)`, even for event-only descriptors. Never make document
        // interaction wait for an optional change watcher.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let descriptor = opener(path)
            DispatchQueue.main.async {
                guard let self else {
                    if descriptor >= 0 { close(descriptor) }
                    return
                }
                self.isStarting = false
                guard descriptor >= 0,
                      self.startGeneration == generation,
                      self.source == nil else {
                    if descriptor >= 0 { close(descriptor) }
                    return
                }
                self.installSource(descriptor: descriptor)
            }
        }
    }

    private func installSource(descriptor: Int32) {
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
        startGeneration += 1
        isStarting = false
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
