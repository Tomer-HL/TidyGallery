//
//  DeviceSummary.swift
//  TidyGallery
//
//  A one-line description of what a set of measurements was taken on.
//
//  Numbers from a performance run are meaningless without it: "peaked at 410 MB"
//  is fine on a 8 GB Pro and fatal on an iPhone SE, and Vision throughput on an
//  A18 is not the A13's. So every diagnostics report carries the hardware
//  identifier (not the marketing name — that mapping would need a table this app
//  has no business maintaining), the OS version, and the app build.
//
//  Guarded for the macOS `CalibrationTool` target, which shares `Utilities/`.
//

import Foundation

#if canImport(UIKit)
import UIKit
#endif

enum DeviceSummary {

    /// e.g. "iPhone16,1 · iOS 18.5 · TidyGallery 1.0 (1)".
    static var current: String {
        [hardwareIdentifier, systemVersion, appVersion]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// The `uname` machine string ("iPhone16,1"), which is what actually
    /// identifies the silicon. On the Simulator this reports the *host* Mac, so
    /// it doubles as a warning that the numbers aren't from real hardware.
    static var hardwareIdentifier: String {
        var info = utsname()
        uname(&info)
        let identifier = withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: info.machine)) {
                String(validatingCString: $0) ?? ""
            }
        }
        #if targetEnvironment(simulator)
        return "Simulator (\(identifier))"
        #else
        return identifier
        #endif
    }

    static var systemVersion: String {
        #if canImport(UIKit)
        return "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #else
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion)"
        #endif
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "TidyGallery \(short) (\(build))"
    }
}
