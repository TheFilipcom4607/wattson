import Foundation
import IOKit
import IOKit.ps

/// Fires a callback whenever a USB or Thunderbolt device is attached or removed,
/// so the menu bar stays current without polling.
final class HotplugWatcher {
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard port == nil, let notifyPort = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = notifyPort
        IONotificationPortSetDispatchQueue(notifyPort, .main)

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            drain(iterator)
            guard let refcon else { return }
            Unmanaged<HotplugWatcher>.fromOpaque(refcon).takeUnretainedValue().onChange()
        }

        // IOThunderboltPort covers docks that expose no USB device of their own.
        for className in ["IOUSBHostDevice", "IOThunderboltPort"] {
            for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                guard let matching = IOServiceMatching(className) else { continue }
                var iterator: io_iterator_t = 0
                let status = IOServiceAddMatchingNotification(
                    notifyPort, type, matching, callback, context, &iterator
                )
                guard status == KERN_SUCCESS else { continue }
                // Arming the notification requires emptying the iterator once.
                drain(iterator)
                iterators.append(iterator)
            }
        }
    }

    deinit {
        iterators.forEach { IOObjectRelease($0) }
        if let port { IONotificationPortDestroy(port) }
    }
}

/// Fires the moment an adapter is attached or removed.
///
/// Without this, noticing a charger would wait for the next poll — and the
/// battery registry's own refresh can lag half a minute behind the event.
final class PowerSourceWatcher {
    private var source: CFRunLoopSource?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ refcon in
            guard let refcon else { return }
            Unmanaged<PowerSourceWatcher>.fromOpaque(refcon).takeUnretainedValue().onChange()
        }, context)?.takeRetainedValue() else { return }

        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    deinit {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }
}

/// A matching notification only re-fires once its iterator has been exhausted.
private func drain(_ iterator: io_iterator_t) {
    while case let entry = IOIteratorNext(iterator), entry != 0 {
        IOObjectRelease(entry)
    }
}
