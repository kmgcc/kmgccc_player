//
//  DisplayHDRCapability.swift
//  myPlayer2
//
//  Conservative display capability detection for HDR visualizations.
//
//  EDR headroom alone is not enough to identify an XDR / HDR display: some
//  ordinary SDR panels expose a small amount of EDR headroom as well. Apple
//  reference EDR and an explicit HDR declaration in the display metadata are
//  therefore required before the app selects its HDR visual treatment.
//

import AppKit
import CoreGraphics
import Foundation
import IOKit
import SwiftUI

// MARK: - Data model

enum HDRDisplayCapability: Equatable {
    case sdr
    case edrOnly
    case trueHDR
}

struct HDRDisplayInfo: Equatable {
    let capability: HDRDisplayCapability
    let maximumPotentialEDR: CGFloat
    let maximumCurrentEDR: CGFloat
    let maximumReferenceEDR: CGFloat
    let reason: String

    var allowsHDRHighlight: Bool { capability == .trueHDR }

    static let unsupported = HDRDisplayInfo(
        capability: .sdr,
        maximumPotentialEDR: 1,
        maximumCurrentEDR: 1,
        maximumReferenceEDR: 0,
        reason: "no screen"
    )
}

/// Detects whether an `NSScreen` is safe for the app's HDR visualization
/// palette. Detection is intentionally conservative: an ambiguous display
/// uses the existing SDR palette and standard compositor path.
enum DisplayHDRCapability {

    private nonisolated static let lock = NSLock()
    /// The EDID/static capability result is stable until the screen topology
    /// changes. The lock keeps this cache safe for notification-driven calls.
    private nonisolated(unsafe) static var capabilityCache: [CGDirectDisplayID: Bool] = [:]

    nonisolated static func invalidateCache() {
        lock.lock()
        capabilityCache.removeAll()
        lock.unlock()
    }

    @MainActor
    static func evaluate(screen: NSScreen?) -> HDRDisplayInfo {
        guard let screen else { return .unsupported }

        let potential = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
        let current = screen.maximumExtendedDynamicRangeColorComponentValue
        let reference = screen.maximumReferenceExtendedDynamicRangeColorComponentValue

        func result(_ capability: HDRDisplayCapability, reason: String) -> HDRDisplayInfo {
            HDRDisplayInfo(
                capability: capability,
                maximumPotentialEDR: potential,
                maximumCurrentEDR: current,
                maximumReferenceEDR: reference,
                reason: reason
            )
        }

        // Reference EDR is the system's strong signal for Apple XDR / Pro
        // Display XDR-class panels.
        if reference.isFinite, reference > 1 {
            return result(.trueHDR, reason: "reference EDR display")
        }

        guard potential.isFinite, potential > 1 else {
            return result(.sdr, reason: "no EDR support")
        }

        guard let displayID = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID else {
            return result(.edrOnly, reason: "no display identifier")
        }

        if hasDeclaredHDR(displayID: displayID) {
            return result(.trueHDR, reason: "display declares HDR metadata")
        }
        return result(.edrOnly, reason: "EDR without reliable HDR declaration")
    }

    /// Exposed for unit tests so the metadata policy can be verified without
    /// requiring a physical HDR display.
    nonisolated static func hasHDRStaticMetadata(in edid: [UInt8]) -> Bool {
        guard edid.count >= 128 else { return false }
        guard edid.prefix(128).reduce(0, &+) & 0xFF == 0 else { return false }

        let extensionCount = Int(edid[126])
        var offset = 128
        for _ in 0..<extensionCount {
            guard offset + 128 <= edid.count else { break }
            let block = Array(edid[offset..<(offset + 128)])
            if block.reduce(0, &+) & 0xFF == 0,
               block[0] == 0x02,
               parseCTA861Extension(block) {
                return true
            }
            offset += 128
        }
        return false
    }

    private nonisolated static func hasDeclaredHDR(displayID: CGDirectDisplayID) -> Bool {
        lock.lock()
        if let cached = capabilityCache[displayID] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let declared: Bool
        if let attributes = copySystemHDRAttributes(displayID: displayID) {
            declared = hasAnyHDRFlag(attributes)
        } else {
            declared = copyLegacyEDID(displayID: displayID).map {
                hasHDRStaticMetadata(in: $0)
            } ?? false
        }

        lock.lock()
        capabilityCache[displayID] = declared
        lock.unlock()
        return declared
    }

    private nonisolated static func copySystemHDRAttributes(
        displayID: CGDirectDisplayID
    ) -> [String: Any]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleCLCD2"),
            &iterator
        ) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service,
                &properties,
                kCFAllocatorDefault,
                0
            ) == KERN_SUCCESS,
                let dictionary = properties?.takeRetainedValue() as? [String: Any],
                let attributes = dictionary["DisplayAttributes"] as? [String: Any],
                let product = attributes["ProductAttributes"] as? [String: Any],
                productMatches(product, displayID: displayID) else {
                continue
            }
            return attributes
        }
        return nil
    }

    private nonisolated static func hasAnyHDRFlag(_ attributes: [String: Any]) -> Bool {
        [
            "SupportsPQEOTF",
            "SupportsHLGEOTF",
            "SupportsHDRGammaEOTF",
            "SupportsHDRStaticMetadataType1"
        ].contains { key in
            (attributes[key] as? NSNumber)?.boolValue == true
        }
    }

    private nonisolated static func productMatches(
        _ product: [String: Any],
        displayID: CGDirectDisplayID
    ) -> Bool {
        func value(_ key: String) -> UInt32? {
            (product[key] as? NSNumber)?.uint32Value
        }

        guard value("LegacyManufacturerID") == CGDisplayVendorNumber(displayID),
              value("ProductID") == CGDisplayModelNumber(displayID) else {
            return false
        }
        if let serial = value("SerialNumber"), serial != 0 {
            return CGDisplaySerialNumber(displayID) == serial
        }
        return true
    }

    private nonisolated static func copyLegacyEDID(displayID: CGDirectDisplayID) -> [UInt8]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iterator
        ) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let vendor = CGDisplayVendorNumber(displayID)
        let product = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            // 0x04 is the historical value for the preferred display
            // configuration dictionary and remains available on current SDKs.
            let preferredConfiguration: UInt32 = 0x04
            guard let properties = IODisplayCreateInfoDictionary(
                service,
                preferredConfiguration
            )?.takeRetainedValue() as? [String: Any],
                let serviceVendor = properties[kDisplayVendorID] as? UInt32,
                let serviceProduct = properties[kDisplayProductID] as? UInt32,
                serviceVendor == vendor,
                serviceProduct == product else {
                continue
            }

            if let serviceSerial = properties[kDisplaySerialNumber] as? UInt32,
               serial != 0,
               serviceSerial != 0,
               serviceSerial != serial {
                continue
            }
            if let data = properties["IODisplayEDID"] as? Data {
                return Array(data)
            }
        }
        return nil
    }

    private nonisolated static func parseCTA861Extension(_ block: [UInt8]) -> Bool {
        guard block.count >= 128 else { return false }
        let dtdStart = Int(block[2] & 0x7F)
        let dataEnd = dtdStart == 0 ? 127 : min(dtdStart, 127)

        var index = 4
        while index < dataEnd {
            let header = block[index]
            let length = Int(header & 0x1F)
            let tag = header >> 5
            guard length > 0, index + 1 + length < 128 else { break }
            let payload = Array(block[(index + 1)...(index + length)])

            if tag == 0x07, payload.count >= 3, payload[0] == 0x06 {
                let eotfFlags = payload[1]
                // Traditional HDR gamma, PQ/ST2084, and HLG.
                if eotfFlags & 0x02 != 0 || eotfFlags & 0x04 != 0 || eotfFlags & 0x08 != 0 {
                    return true
                }
            }
            index += length + 1
        }
        return false
    }
}

// MARK: - Window screen bridge

/// Supplies the capability of the screen currently hosting an AppKit view.
/// It is intentionally event-driven so SwiftUI color policy is refreshed when
/// a window moves between displays without polling on the rendering path.
@MainActor
struct HDRDisplayCapabilityReader: NSViewRepresentable {
    @Binding var info: HDRDisplayInfo

    init(info: Binding<HDRDisplayInfo>) {
        self._info = info
    }

    func makeNSView(context: Context) -> HDRDisplayCapabilityReaderView {
        let view = HDRDisplayCapabilityReaderView()
        view.onChange = { [binding = $info] newInfo in
            binding.wrappedValue = newInfo
        }
        return view
    }

    func updateNSView(_ nsView: HDRDisplayCapabilityReaderView, context: Context) {
        nsView.onChange = { [binding = $info] newInfo in
            binding.wrappedValue = newInfo
        }
        nsView.refresh()
    }
}

@MainActor
final class HDRDisplayCapabilityReaderView: NSView {
    var onChange: ((HDRDisplayInfo) -> Void)?

    private weak var observedWindow: NSWindow?
    private var lastInfo: HDRDisplayInfo?

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installObserversIfNeeded()
        refresh()
    }

    func refresh() {
        let screen = window?.screen ?? NSScreen.main
        let newInfo = DisplayHDRCapability.evaluate(screen: screen)
        guard lastInfo != newInfo else { return }
        lastInfo = newInfo
        onChange?(newInfo)
    }

    private func installObserversIfNeeded() {
        guard observedWindow !== window else { return }
        uninstallObservers()

        guard let window else { return }
        observedWindow = window
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleScreenChange(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(handleScreenChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func uninstallObservers() {
        let center = NotificationCenter.default
        if let observedWindow {
            center.removeObserver(
                self,
                name: NSWindow.didChangeScreenNotification,
                object: observedWindow
            )
        }
        center.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        observedWindow = nil
    }

    @objc
    private func handleScreenChange(_ notification: Notification) {
        if notification.name == NSApplication.didChangeScreenParametersNotification {
            DisplayHDRCapability.invalidateCache()
        }
        refresh()
    }
}
