import AppKit
import ColorSync
import WallpaperMacCore

/// Captures the hardware identity of an `NSScreen`.
///
/// Phase 1 only records identities; the topology reducer will start driving the
/// runtime in a later phase. `CGDisplayCreateUUIDFromDisplayID` lives in
/// ColorSync and returns an unmanaged `CFUUID`.
enum DisplayIdentityProvider {
    static func identity(for screen: NSScreen) -> DisplayIdentity {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let displayID = number?.uint32Value ?? 0
        let frame = screen.frame
        let scale = max(screen.backingScaleFactor, 1)
        let pixelsWide = CGDisplayPixelsWide(displayID)
        let pixelsHigh = CGDisplayPixelsHigh(displayID)

        return DisplayIdentity(
            uuid: uuidString(for: displayID),
            cgDisplayID: displayID,
            vendorNumber: nonzero(CGDisplayVendorNumber(displayID)),
            modelNumber: nonzero(CGDisplayModelNumber(displayID)),
            serialNumber: nonzero(CGDisplaySerialNumber(displayID)),
            localizedName: screen.localizedName,
            geometry: DisplayGeometry(
                originX: Double(frame.origin.x),
                originY: Double(frame.origin.y),
                width: Double(frame.width),
                height: Double(frame.height),
                pixelWidth: pixelsWide > 0 ? Int(pixelsWide) : Int((frame.width * scale).rounded()),
                pixelHeight: pixelsHigh > 0 ? Int(pixelsHigh) : Int((frame.height * scale).rounded())
            ),
            isBuiltIn: CGDisplayIsBuiltin(displayID) != 0
        )
    }

    private static func uuidString(for displayID: CGDirectDisplayID) -> String? {
        guard displayID != 0, let unmanaged = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return nil
        }
        return CFUUIDCreateString(nil, unmanaged.takeRetainedValue()) as String
    }

    /// Display APIs report zero for unknown values; zero must not be treated as
    /// a matchable hardware attribute.
    private static func nonzero(_ value: UInt32) -> UInt32? {
        value == 0 ? nil : value
    }
}
