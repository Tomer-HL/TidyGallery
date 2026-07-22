//
//  ScanScope.swift
//  TidyGallery
//
//  How much of the library a scan covers.
//
//  Analysis is the expensive part (an image load plus several Vision passes per
//  photo), and it scales linearly with the number of photos. Narrowing the time
//  window is therefore the only lever that reduces the work *proportionally* —
//  scanning three months instead of ten years does a fraction of the work rather
//  than the same work in a different order.
//
//  Note this can't be done by content category: "only scan food photos" is
//  circular, because classification is what tells us a photo contains food.
//

import Foundation

enum ScanScope: String, CaseIterable, Identifiable, Codable, Sendable {
    case lastMonth
    case threeMonths
    case year
    case allTime

    var id: String { rawValue }

    // These are plain `String`s handed to `Text(_:)` and `Menu` labels. SwiftUI
    // only localizes string *literals* written at the call site, so copy that
    // lives in a model like this one has to localize itself — otherwise it is
    // the one part of the interface that stays English forever.
    var label: String {
        switch self {
        case .lastMonth: String(localized: "Past month")
        case .threeMonths: String(localized: "Past 3 months")
        case .year: String(localized: "Past year")
        case .allTime: String(localized: "Entire library")
        }
    }

    var detail: String {
        switch self {
        case .lastMonth: String(localized: "Fastest — recent clutter only")
        case .threeMonths: String(localized: "A good balance for a quick clean-up")
        case .year: String(localized: "Most of what people actually revisit")
        case .allTime: String(localized: "Thorough, but the first scan takes a while")
        }
    }

    /// Photos created before this date are skipped. `nil` means no limit.
    func cutoffDate(from now: Date = .now) -> Date? {
        let months: Int
        switch self {
        case .lastMonth: months = 1
        case .threeMonths: months = 3
        case .year: months = 12
        case .allTime: return nil
        }
        return Calendar.current.date(byAdding: .month, value: -months, to: now)
    }
}

/// Remembers the scope between launches.
enum ScanScopeStore {

    private static let key = "tidygallery.scanScope"

    static func load() -> ScanScope {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let scope = ScanScope(rawValue: raw)
        else { return .year }          // sensible default: useful, not glacial
        return scope
    }

    static func save(_ scope: ScanScope) {
        UserDefaults.standard.set(scope.rawValue, forKey: key)
    }
}
