import Foundation
import IOKit

/// Builds the connected-device tree.
///
/// USB comes straight from the IORegistry: `system_profiler SPUSBDataType`
/// returns an empty list on macOS 26, so it cannot be relied on.
/// Thunderbolt still comes from system_profiler, which reports it correctly.
enum Scanner {

    static func scan() -> ScanResult {
        var result = ScanResult()
        result.devices = usbDevices() + thunderboltDevices()
        return result
    }

    // MARK: - USB via IOKit

    private static func usbDevices() -> [DeviceNode] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        // Collect every device flat, keyed by locationID, then rebuild the tree.
        var byLocation: [Int: DeviceNode] = [:]
        var order: [Int] = []

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let properties = properties(of: service),
                  let location = (properties["locationID"] as? NSNumber)?.intValue
            else { continue }

            var node = DeviceNode(name: name(from: properties), kind: .usb)
            // The locationID is stable for as long as the device stays plugged
            // into the same port, which is exactly the identity SwiftUI wants.
            node.id = "usb-\(location)"
            node.vendor = vendor(from: properties)
            node.vendorID = (properties["idVendor"] as? NSNumber)?.intValue
            node.productID = (properties["idProduct"] as? NSNumber)?.intValue
            node.serial = (properties["USB Serial Number"] as? String)?.nilIfEmpty
            // Identity that survives a move to another port. Everything keyed on
            // history keys on this; without a serial there is nothing to key on,
            // and the port id has to stand in.
            if let vendorID = node.vendorID, let productID = node.productID, let serial = node.serial {
                node.persistentID = String(format: "%04X:%04X:%@", vendorID, productID, serial)
            }
            node.isApple = node.vendorID == 0x05AC
            node.controller = (location >> 24) & 0xFF
            // One BOS read per device, cached by location, so this costs two
            // control transfers once per device rather than twice per device
            // per scan. It answers two questions: what became of an alternate
            // mode, and how fast the device says it can go.
            let descriptors = BOSDescriptor.read(for: service, locationID: location)
            node.altModeFailure = descriptors.billboard?.summary
            node.speedCapability = descriptors.speeds
            node.typeLabel = functionLabel(for: service, properties: properties)

            if let bits = (properties["UsbLinkSpeed"] as? NSNumber)?.doubleValue, bits > 0 {
                let mbps = bits / 1_000_000
                node.speedMbps = mbps
                node.speeds = [SpeedFormat.usbLabel(mbps: mbps)]
            }
            if let bcd = (properties["bcdUSB"] as? NSNumber)?.intValue {
                node.usbSpecBCD = bcd
                node.version = SpeedFormat.usbVersion(bcd: bcd)
            }
            // Current the port has granted this device; USB rails are 5 V.
            if let mA = (properties["UsbPowerSinkAllocation"] as? NSNumber)?.doubleValue, mA > 0 {
                node.watts = mA * 5 / 1000
                node.milliamps = mA
            }
            // What the device asked for, as opposed to what it was granted. The
            // two match on everything healthy, so this is only worth a row when
            // they diverge — which is the case worth knowing about.
            node.requestedMilliamps = (properties["UsbPowerSinkCapability"] as? NSNumber)?.doubleValue
            collectDownstreamFacts(of: service, into: &node)

            byLocation[location] = node
            order.append(location)
        }

        // Anything unplugged since the last scan stops being worth remembering.
        BOSDescriptor.forget(except: Set(order))

        // A locationID encodes the port path: 0x01210000 hangs off 0x01200000.
        var roots: [DeviceNode] = []
        var childrenOf: [Int: [Int]] = [:]
        for location in order {
            if let parent = parentLocation(location), byLocation[parent] != nil {
                childrenOf[parent, default: []].append(location)
            }
        }

        func build(_ location: Int) -> DeviceNode? {
            guard var node = byLocation[location] else { return nil }
            node.children = (childrenOf[location] ?? []).sorted().compactMap(build)
            return node
        }

        for location in order.sorted() {
            let parent = parentLocation(location)
            if parent == nil || byLocation[parent!] == nil, let node = build(location) {
                roots.append(node)
            }
        }
        return roots
    }

    /// Zeroing the lowest non-zero port nibble walks one hop up the USB tree.
    private static func parentLocation(_ location: Int) -> Int? {
        for nibble in 0..<6 {
            let shift = nibble * 4
            if (location >> shift) & 0xF != 0 {
                return location & ~(0xF << shift)
            }
        }
        return nil
    }

    private static func name(from properties: [String: Any]) -> String {
        for key in ["USB Product Name", "kUSBProductString", "IORegistryEntryName"] {
            if let value = properties[key] as? String, !value.isEmpty {
                return value.replacingOccurrences(of: "_", with: "/")
            }
        }
        return "Unknown Device"
    }

    private static func vendor(from properties: [String: Any]) -> String? {
        if let vendor = properties["USB Vendor Name"] as? String, !vendor.isEmpty {
            return vendor
        }
        // Plenty of hubs ship with iManufacturer = 0 and no vendor string at all.
        if let id = (properties["idVendor"] as? NSNumber)?.intValue {
            // The hex was appended to known names too, which just added noise
            // to the common case. It is now the fallback, not a suffix.
            if let known = knownVendors[id] { return known }
            return String(format: "0x%04X", id)
        }
        return nil
    }

    /// The curated table, by numeric ID.
    ///
    /// PD Discover Identity endpoints publish a vendor ID and no name at all —
    /// a cable's chip has nowhere to put a string — so this is the only route
    /// from an e-marker to a manufacturer.
    static func vendorName(forID id: Int) -> String? { knownVendors[id] }

    /// Thunderbolt entries often carry only a hex vendor id string.
    static func vendorName(forHex raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X")
            ? String(trimmed.dropFirst(2))
            : trimmed
        guard let id = Int(digits, radix: 16), let known = knownVendors[id] else { return raw }
        return known
    }

    /// The USB-IF list runs to thousands of entries and is not redistributable
    /// as a whole, so this is the working subset: the vendors that actually turn
    /// up in docks, enclosures, hubs and peripherals, where the device's own
    /// vendor string is so often blank.
    ///
    /// The names here are the ones somebody would recognise, which is not
    /// always the registrant. A flash drive published under Phison's ID reads
    /// better as "Kingston" — the name on the casing — and several entries are
    /// deliberately that way round.
    ///
    /// That licence stops at making one up. 0x2E99 read "Anker" and belongs to
    /// Hynetek Semiconductor, who make PD controller chips; there is no Anker
    /// product behind it to justify the substitution the way there is for
    /// Kingston. It put "Cable made by: Anker" under a Baseus cable.
    private static let knownVendors: [Int: String] = [
        0x03EB: "Atmel", 0x03F0: "HP", 0x0403: "FTDI", 0x0409: "NEC",
        0x0424: "Microchip", 0x043E: "LG", 0x0451: "Texas Instruments",
        0x045E: "Microsoft", 0x0461: "Primax", 0x046D: "Logitech",
        0x0471: "Philips", 0x0483: "STMicroelectronics", 0x04A9: "Canon",
        0x04B3: "IBM", 0x04B4: "Cypress", 0x04B8: "Epson", 0x04CA: "Lite-On",
        0x04D8: "Microchip", 0x04DD: "Sharp", 0x04E8: "Samsung",
        0x04F2: "Chicony", 0x04F3: "Elan", 0x04F9: "Brother",
        0x050D: "Belkin", 0x051D: "APC", 0x054C: "Sony",
        0x055D: "Samsung Electro-Mechanics", 0x056A: "Wacom", 0x056E: "Elecom",
        0x057C: "AVM", 0x058F: "Alcor Micro", 0x059B: "Iomega",
        0x05A9: "OmniVision", 0x05AC: "Apple", 0x05C6: "Qualcomm",
        0x05DC: "Lexar", 0x05E3: "Genesys Logic", 0x0644: "TEAC",
        0x066F: "SigmaTel", 0x067B: "Prolific", 0x0699: "Tektronix",
        0x06CB: "Synaptics", 0x0718: "Imation", 0x077B: "Linksys",
        0x0781: "SanDisk", 0x07B3: "Plustek", 0x07CA: "AVerMedia",
        0x07D1: "D-Link", 0x0846: "NetGear", 0x08BB: "Texas Instruments",
        0x08E4: "Pioneer", 0x090C: "Silicon Motion", 0x0930: "Toshiba",
        0x093A: "PixArt", 0x0951: "Kingston", 0x0955: "NVIDIA",
        0x09DA: "A4Tech", 0x0A12: "Cambridge Silicon Radio", 0x0A5C: "Broadcom",
        0x0B05: "ASUS", 0x0B0E: "Jabra", 0x0B95: "ASIX", 0x0BB4: "HTC",
        0x0BC2: "Seagate", 0x0BDA: "Realtek", 0x0C45: "Microdia",
        0x0CF3: "Qualcomm Atheros", 0x0D8C: "C-Media", 0x0E0F: "VMware",
        0x0E8D: "MediaTek", 0x1004: "LG", 0x1058: "Western Digital",
        0x10C4: "Silicon Labs", 0x125F: "ADATA", 0x1235: "Focusrite",
        0x12D1: "Huawei", 0x1307: "Transcend", 0x13FE: "Kingston",
        0x1462: "MSI", 0x1509: "FIC", 0x152D: "JMicron", 0x1532: "Razer",
        0x1604: "Tascam", 0x174C: "ASMedia", 0x17E9: "DisplayLink",
        0x17EF: "Lenovo", 0x18A5: "Verbatim", 0x18D1: "Google",
        0x1A40: "Terminus Technology", 0x1A86: "QinHeng", 0x1B1C: "Corsair",
        0x1BCF: "Sunplus", 0x1D6B: "Linux Foundation", 0x1F75: "Innostor",
        0x2001: "D-Link", 0x20C2: "Diodes", 0x2109: "VIA Labs",
        // Cable and charger e-marker vendors seen in probes/. These turn up
        // only now that the chips can be read, and never as a name: a PD
        // endpoint publishes a number and nothing else.
        0x06AD: "Greatland Electronics", 0x2F16: "Shenzhen Kejinming",
        0x2188: "Sonix", 0x2207: "Rockchip", 0x2357: "TP-Link",
        0x2717: "Xiaomi", 0x28DE: "Valve", 0x2E8A: "Raspberry Pi",
        0x2E99: "Hynetek Semiconductor", 0x2ECC: "Cypress", 0x413C: "Dell", 0x8087: "Intel"
    ]

    /// What the device actually is, inferred from the drivers macOS attached to it.
    private static func functionLabel(for service: io_registry_entry_t, properties: [String: Any]) -> String? {
        // Name first. An iPhone publishes an ethernet interface whether or not
        // Personal Hotspot is on, so driver sniffing alone calls it "Ethernet".
        let name = name(from: properties)
        for (needle, label) in [("iPhone", "iPhone"), ("iPad", "iPad"),
                                ("Apple Watch", "Apple Watch"), ("AirPods", "AirPods"),
                                ("Magic Keyboard", "Keyboard"), ("Magic Mouse", "Mouse"),
                                ("Magic Trackpad", "Trackpad")] {
            if name.localizedCaseInsensitiveContains(needle) { return label }
        }

        if (properties["bDeviceClass"] as? NSNumber)?.intValue == 9 { return "Hub" }

        var found: Set<String> = []
        collectClasses(of: service, into: &found, depth: 0)

        // Ordered so the most specific description wins.
        let rules: [(String, [String])] = [
            ("Storage", ["MassStorage", "IOBlockStorageDriver", "SCSIPeripheral"]),
            ("Ethernet", ["Ethernet", "AppleUSBECM", "NCM", "RNDIS"]),
            ("Display", ["Billboard", "DisplayPort"]),
            ("Audio", ["Audio"]),
            ("Camera", ["VideoStream", "USBVDC", "AppleCam"]),
            ("Card Reader", ["CardReader"]),
            ("Input", ["HID"]),
            ("Serial", ["Serial"]),
            ("Hub", ["Hub"])
        ]
        for (label, needles) in rules {
            if found.contains(where: { name in needles.contains { name.localizedCaseInsensitiveContains($0) } }) {
                return label
            }
        }
        return nil
    }

    /// Facts that live on the drivers macOS attached below a device rather than
    /// on the device itself: a hub's downstream current pool, and a billboard's
    /// account of the alternate mode it is there to describe.
    private static func collectDownstreamFacts(of service: io_registry_entry_t, into node: inout DeviceNode, depth: Int = 0) {
        guard depth < 3 else { return }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            // Anything under a nested device describes that device, not this one.
            if IOObjectConformsTo(child, "IOUSBHostDevice") != 0 { continue }

            if let properties = properties(of: child) {
                // The pool a hub has to hand out, which is the number the tree
                // has never been able to show for the one kind of device whose
                // whole job is handing power on.
                if let pool = (properties["kUSBHubPowerSupply"] as? NSNumber)?.doubleValue, pool > 0 {
                    node.hubBudgetMilliamps = pool
                }
                // A billboard device exists solely to report an alternate mode,
                // which is why a dock publishes one at all.
                if let mode = properties["UsbBillboardCurrentMode"] as? String, !mode.isEmpty {
                    node.altMode = mode
                }
                if node.altMode == nil,
                   let modes = properties["UsbBillboardSupportedModes"] as? [String], !modes.isEmpty {
                    node.altMode = modes.joined(separator: ", ")
                }
                if let version = properties["UsbBillboardVersion"] as? String, !version.isEmpty {
                    node.altModeVersion = version
                }
            }
            collectDownstreamFacts(of: child, into: &node, depth: depth + 1)
        }
    }

    /// Gathers driver class names below a device, stopping at the next USB device.
    private static func collectClasses(of service: io_registry_entry_t, into found: inout Set<String>, depth: Int) {
        guard depth < 4 else { return }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            // Anything under a nested device belongs to that device, not this one.
            if IOObjectConformsTo(child, "IOUSBHostDevice") != 0 { continue }

            var className = [CChar](repeating: 0, count: 128)
            if IOObjectGetClass(child, &className) == KERN_SUCCESS {
                found.insert(String(cString: className))
            }
            collectClasses(of: child, into: &found, depth: depth + 1)
        }
    }

    private static func properties(of service: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS
        else { return nil }
        return unmanaged?.takeRetainedValue() as? [String: Any]
    }

    // MARK: - Thunderbolt via system_profiler

    private static func thunderboltDevices() -> [DeviceNode] {
        guard let data = run("/usr/sbin/system_profiler", ["-json", "SPThunderboltDataType"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buses = json["SPThunderboltDataType"] as? [[String: Any]]
        else { return [] }

        // Top level entries are the Mac's own controllers; real devices hang off them.
        return buses.enumerated().flatMap { index, bus in
            parseThunderbolt(bus["_items"] as? [[String: Any]] ?? [], path: "tb\(index)")
        }
    }

    /// `path` builds a stable identity out of each device's position in the
    /// tree; system_profiler gives us nothing else to key on.
    private static func parseThunderbolt(_ items: [[String: Any]], path: String) -> [DeviceNode] {
        items.enumerated().map { index, item in
            let name = (item["device_name_key"] as? String)
                ?? (item["_name"] as? String)
                ?? "Thunderbolt Device"

            var node = DeviceNode(name: name, kind: .thunderbolt)
            node.id = "\(path)-\(index)"
            node.vendor = (item["vendor_name_key"] as? String)
                ?? (item["vendor_id_key"] as? String).map(vendorName(forHex:))

            var speeds: [(String, Double)] = []
            for (key, value) in item where key.hasSuffix("_tag") {
                guard let port = value as? [String: Any] else { continue }
                if let status = port["receptacle_status_key"] as? String,
                   status.contains("no_devices_connected") { continue }
                if let speed = SpeedFormat.thunderbolt(port["current_speed_key"] as? String) {
                    speeds.append(speed)
                }
            }
            if let speed = SpeedFormat.thunderbolt(item["device_speed_key"] as? String) {
                speeds.append(speed)
            }

            var seen = Set<String>()
            let unique = speeds.sorted { $0.1 < $1.1 }.filter { seen.insert($0.0).inserted }
            node.speeds = unique.map(\.0)
            node.speedMbps = unique.map(\.1).max()
            node.typeLabel = "Thunderbolt"

            node.children = parseThunderbolt(
                item["_items"] as? [[String: Any]] ?? [],
                path: "\(path)-\(index)"
            )
            return node
        }
    }

    private static func run(_ path: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }
        // Read before waiting so a large tree cannot fill the pipe and deadlock.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}
