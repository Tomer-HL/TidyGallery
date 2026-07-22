//
//  ActionableSelection.swift
//  TidyGallery
//
//  The rule that decides which selected photos an action may actually touch.
//
//  Why this is its own file
//  -----------------------
//  It was three characters of set arithmetic inside a SwiftUI view, which is to
//  say it was untestable and easy to forget. A safety audit found the version
//  without it: `AssetCleanupScreen` kept `selected` as a flat `Set` of ids
//  alongside a separately-derived `displayed` list, and nothing reconciled the
//  two. Three ways they drift apart, none of which require the user to do
//  anything wrong:
//
//    * The age filter hides selected photos while leaving them selected.
//    * The big-file size floor is only enforced once sizes have loaded, so a
//      photo tapped before the measurement lands can vanish a moment later —
//      no user action at all.
//    * The display limit caps the list, and re-sorting changes which items
//      fall inside the cap.
//
//  In each case the delete button counted, and `deleteAssets` received, photos
//  the user could no longer see. For an app whose first promise is that nothing
//  is deleted without explicit confirmation, deleting something the user cannot
//  even see is the worst failure available — so the rule that prevents it
//  deserves a name, a test, and somewhere to write down why it exists.
//
//  Deliberately pure: no Photos, no SwiftUI, no actor isolation. It is set
//  arithmetic, and it should be provable without a device.
//

import Foundation

/// Restricts a selection to what the user can currently see.
enum ActionableSelection {

    /// The subset of `selected` that appears in `displayed`.
    ///
    /// Intersection rather than pruning the stored selection is a deliberate
    /// choice. Filtering a photo away and bringing it back restores its
    /// selection, which is what people expect; and because the rule is applied
    /// at the point of use rather than on every state change, there is no
    /// `onChange` handler to forget when a future filter is added. The stored
    /// set stays the user's intent — this is that intent restricted to what is
    /// on screen.
    ///
    /// - Parameters:
    ///   - selected: every id the user has checked, including ones now hidden.
    ///   - displayed: ids currently visible, in display order.
    /// - Returns: ids that are both selected and visible.
    static func resolve<ID: Hashable>(selected: Set<ID>, displayed: some Sequence<ID>) -> Set<ID> {
        selected.intersection(displayed)
    }

    /// Whether every visible item is selected.
    ///
    /// Kept here beside `resolve` because the naive version of this — comparing
    /// `selected.count` to `displayed.count` — compares a count that can
    /// include off-screen items against one that cannot, and so could report
    /// "everything is selected" while visible photos sat unselected.
    ///
    /// An empty list is **not** "all selected": there is nothing to act on, and
    /// answering `true` would offer the user a Deselect All that does nothing.
    static func allVisibleSelected<ID: Hashable>(
        selected: Set<ID>,
        displayed: some Collection<ID>
    ) -> Bool {
        guard !displayed.isEmpty else { return false }
        return resolve(selected: selected, displayed: displayed).count == displayed.count
    }
}
