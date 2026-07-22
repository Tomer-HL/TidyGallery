//
//  AssetCleanupScreen.swift
//  TidyGallery
//
//  One reusable grid screen for every "flat list" cleanup category: screenshots,
//  large videos, big files, screen recordings, and possibly-blurry singles.
//  There is no best-shot logic here — that lives in `ReviewScreen`. Deletion
//  routes through the single safe `PhotoLibraryService.deleteAssets` path, which
//  also triggers the system's own confirmation sheet.
//
//  Pre-selection: this header used to claim "NOTHING is pre-selected". That was
//  true when it was written and is not true now — `Recommended cleanup` and
//  `Exact duplicates` both open with `initiallySelected` covering every item
//  (see `CleanupHomeView`). It is worth being accurate about, because a
//  maintainer who believes nothing is pre-checked won't think to protect the
//  pre-checked path, which is precisely the one where a mis-scoped selection
//  turns into a deletion the user never made.
//
//  Two rules hold the safety of this screen together, both worth reading before
//  touching anything here:
//    • `actionableSelection` — never act on a photo that isn't on screen.
//    • `pendingDeletion` — delete exactly the set the confirmation named.
//

import SwiftUI

struct AssetCleanupScreen: View {
    let category: CleanupCategory
    /// Called after a successful deletion so the coordinator can reconcile the
    /// home counts and other category screens immediately.
    var onDeleted: ([PhotoAsset.ID]) -> Void
    /// Called when the user chooses to keep items permanently ("never suggest
    /// these again"). `nil` hides the action.
    var onIgnore: (([PhotoAsset.ID]) -> Void)?

    @State private var assets: [PhotoAsset]
    @Environment(\.photoLibrary) private var library

    @State private var selected: Set<PhotoAsset.ID>
    @State private var sizes: [PhotoAsset.ID: Int64] = [:]
    @State private var showConfirm = false
    /// The exact ids the confirmation dialog is asking about, frozen when it
    /// opens.
    ///
    /// Without this, the dialog's count and `performDelete` were two separate
    /// evaluations of `actionableSelection` at two different moments. They agree
    /// today only because `sizes` is the one input that can still change while
    /// the dialog is up, and no category currently sets `minDisplayBytes`. That
    /// is a coincidence of configuration, not a guarantee — and "you delete
    /// exactly what you confirmed" should not rest on one.
    @State private var pendingDeletion: [PhotoAsset.ID] = []
    @State private var isDeleting = false
    @State private var banner: String?
    @State private var sortOrder: CleanupSortOrder
    @State private var ageFilter: CleanupAgeFilter = .all
    @State private var isExporting = false
    /// The photo whose score breakdown is open, if any. Built only on demand —
    /// tiles never compute an explanation.
    @State private var explaining: PhotoAsset?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: Theme.Spacing.s)]

    init(
        category: CleanupCategory,
        assets: [PhotoAsset],
        initiallySelected: Set<PhotoAsset.ID> = [],
        onDeleted: @escaping ([PhotoAsset.ID]) -> Void = { _ in },
        onIgnore: (([PhotoAsset.ID]) -> Void)? = nil
    ) {
        self.category = category
        self.onDeleted = onDeleted
        self.onIgnore = onIgnore
        _assets = State(initialValue: assets)
        // Start from the ordering that suits the category (size-ranked ones open
        // largest-first), but the user can override it from the toolbar.
        _sortOrder = State(initialValue: category.sortsBySizeDescending ? .largest : .newest)
        // Recommended cleanup pre-checks its items; other categories start empty.
        _selected = State(initialValue: initiallySelected.intersection(assets.map(\.id)))
    }

    // MARK: Derived display list

    /// The assets actually shown: an optional size floor (applied once sizes are
    /// measured), then optionally sorted largest-file-first, then capped to the
    /// category's display limit.
    private var displayed: [PhotoAsset] {
        var list = assets
        // Size floor — only enforced once we've measured sizes, so nothing is
        // hidden while the measurement is still in flight.
        if let floor = category.minDisplayBytes, !sizes.isEmpty {
            list = list.filter { (sizes[$0.id] ?? 0) >= floor }
        }
        if ageFilter != .all {
            list = list.filter { ageFilter.matches($0.creationDate) }
        }
        list = sorted(list)
        if let limit = category.displayLimit {
            list = Array(list.prefix(limit))
        }
        return list
    }

    /// What any action will actually touch: the selection restricted to what is
    /// currently on screen. See `ActionableSelection` for why this exists and
    /// what went wrong without it — every count and every action in this file
    /// must come from here, never from `selected` directly.
    private var actionableSelection: Set<PhotoAsset.ID> {
        ActionableSelection.resolve(selected: selected, displayed: displayed.map(\.id))
    }

    /// How many photos any action will affect. Every count shown to the user
    /// must come from here, never from `selected.count`.
    private var actionableCount: Int { actionableSelection.count }

    /// Applies the chosen order. Size-based orders fall back to date until the
    /// measurement lands, so the grid never looks arbitrarily shuffled.
    private func sorted(_ list: [PhotoAsset]) -> [PhotoAsset] {
        if sortOrder.needsSizes && sizes.isEmpty {
            return list.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        }
        switch sortOrder {
        case .newest:
            return list.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        case .oldest:
            return list.sorted { ($0.creationDate ?? .distantFuture) < ($1.creationDate ?? .distantFuture) }
        case .largest:
            return list.sorted { (sizes[$0.id] ?? 0) > (sizes[$1.id] ?? 0) }
        case .smallest:
            return list.sorted { (sizes[$0.id] ?? 0) < (sizes[$1.id] ?? 0) }
        }
    }

    var body: some View {
        Group {
            if displayed.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .background(Theme.Colors.background.ignoresSafeArea())
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { await loadSizes() }
        .safeAreaInset(edge: .bottom) { deleteBar }
        .confirmationDialog(
            String(localized: "Delete \(counted(pendingDeletion.count))?"),
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete \(pendingDeletion.count)"), role: .destructive) {
                Task { await performDelete() }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
        } message: {
            Text("They'll move to Recently Deleted, where you can recover them for 30 days.")
        }
        .overlay(alignment: .top) { bannerView }
        .sheet(item: $explaining) { asset in
            if let score = asset.score {
                ScoreBreakdownView(
                    score: score,
                    labels: asset.classificationLabels,
                    config: .default
                )
            }
        }
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Theme.Spacing.s) {
                ForEach(displayed) { asset in
                    AssetTileView(
                        assetID: asset.id,
                        isSelected: selected.contains(asset.id),
                        isVideo: category.isVideo,
                        subtitle: subtitle(for: asset),
                        noun: category.noun,
                        onToggle: { toggle(asset.id) }
                    )
                    .contextMenu {
                        if asset.score != nil {
                            Button {
                                explaining = asset
                            } label: {
                                Label("Why this photo?", systemImage: "info.circle")
                            }
                        }
                    }
                }
            }
            .padding(Theme.Spacing.l)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: assets.count)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(allSelected ? String(localized: "Deselect All") : String(localized: "Select All")) {
                if allSelected {
                    // Only deselect what's on screen — "Deselect All" on a
                    // filtered list shouldn't silently discard choices made
                    // under a different filter.
                    selected.subtract(displayed.map(\.id))
                } else {
                    selected.formUnion(displayed.map(\.id))
                }
            }
            .tint(Theme.Colors.accent)
        }
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(CleanupSortOrder.allCases) { order in
                        Label(order.label, systemImage: order.systemImage).tag(order)
                    }
                }
                Picker("Age", selection: $ageFilter) {
                    ForEach(CleanupAgeFilter.allCases) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                if !actionableSelection.isEmpty {
                    Divider()
                    Button {
                        Task { await exportSelectionToAlbum() }
                    } label: {
                        Label("Add \(actionableCount) to album", systemImage: "rectangle.stack.badge.plus")
                    }
                    .disabled(isExporting)
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .tint(Theme.Colors.accent)
        }
    }

    /// Whether everything *currently visible* is selected.
    private var allSelected: Bool {
        ActionableSelection.allVisibleSelected(selected: selected, displayed: displayed.map(\.id))
    }

    // MARK: Delete bar

    @ViewBuilder private var deleteBar: some View {
        // Keyed to what's actionable, so the bar can't offer to act on a
        // selection that is entirely filtered out of view.
        if !actionableSelection.isEmpty {
            VStack(spacing: Theme.Spacing.xs) {
                keepButton
                deleteButton
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.top, Theme.Spacing.s)
            .padding(.bottom, Theme.Spacing.xs)
            .background(.ultraThinMaterial)
        }
    }

    /// "Keep these" — the opposite of deleting: remember the decision so these
    /// photos are never suggested again.
    @ViewBuilder private var keepButton: some View {
        if let onIgnore {
            Button {
                let ids = Array(actionableSelection)
                let removed = Set(ids)
                assets.removeAll { removed.contains($0.id) }
                selected.subtract(removed)
                onIgnore(ids)
                Task { await flashBanner(String(localized: "Won't suggest \(counted(ids.count)) again")) }
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "hand.raised.fill")
                    Text("Keep \(actionableCount) — don't suggest again")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.Colors.accent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Theme.Colors.surfaceMuted, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
            .disabled(isDeleting)
        }
    }

    @ViewBuilder private var deleteButton: some View {
        Button {
            // Freeze the set here — what the dialog names is what gets deleted.
            pendingDeletion = Array(actionableSelection)
            guard !pendingDeletion.isEmpty else { return }
            showConfirm = true
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                if isDeleting {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "trash.fill")
                }
                Text(deleteButtonTitle).monospacedDigit()
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Theme.Colors.destructive, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .disabled(isDeleting)
    }

    private var deleteButtonTitle: String {
        if isDeleting { return String(localized: "Deleting…") }
        var title = String(localized: "Delete \(counted(actionableCount))")
        let bytes = selectedBytes
        if bytes > 0 { title += String(localized: " · frees ~\(bytes.formatted(.byteCount(style: .file)))") }
        return title
    }

    /// Bytes the delete button promises to free. Must match the set that will
    /// actually be deleted, or the button overstates the saving.
    private var selectedBytes: Int64 {
        actionableSelection.reduce(0) { $0 + (sizes[$1] ?? 0) }
    }

    // MARK: Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label(category.emptyTitle, systemImage: category.systemImage)
        } description: {
            Text(category.emptySubtitle)
        }
        .foregroundStyle(Theme.Colors.textPrimary)
    }

    // MARK: Banner

    @ViewBuilder private var bannerView: some View {
        if let banner {
            Text(banner)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.m)
                .background(Theme.Colors.accent, in: Capsule())
                .padding(.top, Theme.Spacing.s)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: Per-tile subtitle

    /// Size and/or duration caption for a tile, when relevant to the category.
    private func subtitle(for asset: PhotoAsset) -> String? {
        let sizeText = sizes[asset.id].map { $0.formatted(.byteCount(style: .file)) }

        if category.isVideo {
            let durationText = Self.formatDuration(asset.duration)
            switch (durationText, sizeText) {
            case let (d?, s?): return "\(d) · \(s)"
            case let (d?, nil): return d
            case let (nil, s?): return s
            default: return nil
            }
        }

        // Non-video, size-ranked categories (big files) show the size.
        // Show sizes when the category is size-ranked, or when the user has
        // explicitly sorted by size and would want to see what they're judging.
        return (category.sortsBySizeDescending || sortOrder.needsSizes) ? sizeText : nil
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String? {
        guard seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: Copy helpers

    /// "3 screenshots", pluralized by the target language's own rules.
    ///
    /// This replaces `category.noun + "s"`, which silently encoded the
    /// assumption that the interface is English — and was already wrong for
    /// "copy"/"copies" before any second language existed.
    private func counted(_ count: Int) -> String {
        category.noun.counted(count)
    }

    // MARK: Actions

    private func toggle(_ id: PhotoAsset.ID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// Saves the current selection into a new Photos album named after the
    /// category. Nothing is moved or removed — the album just references them.
    private func exportSelectionToAlbum() async {
        guard let library else { return }
        let ids = Array(actionableSelection)
        guard !ids.isEmpty else { return }
        let title = String(localized: "TidyGallery – \(category.title)")

        isExporting = true
        defer { isExporting = false }

        do {
            try await library.createAlbum(named: title, withAssetIDs: ids)
            await flashBanner(String(localized: "Added \(ids.count) to “\(title)”"))
        } catch {
            await flashBanner(String(localized: "Couldn't create album: \(error.localizedDescription)"))
        }
    }

    private func loadSizes() async {
        guard let library, sizes.isEmpty, !assets.isEmpty else { return }
        // `await`: measuring on-disk size is a per-asset PHAssetResource
        // lookup, ~10 ms each — though after the first scan most of these are
        // served from the size cache. Off the main actor either way, so a cold
        // grid doesn't stutter.
        let measurement = await library.fileSizes(for: assets.map(\.id))
        // Only latch a complete result: `sizes.isEmpty` is the guard that stops
        // this re-running, so storing a partial map would leave those photos
        // permanently without a size label.
        guard measurement.isComplete else { return }
        sizes = measurement.sizes
    }

    private func performDelete() async {
        guard let library else { return }
        // The frozen set from the confirmation, NOT a fresh evaluation — see
        // `pendingDeletion`. Never `Array(selected)`: see `ActionableSelection`.
        let ids = pendingDeletion
        defer { pendingDeletion = [] }
        guard !ids.isEmpty else { return }

        isDeleting = true
        defer { isDeleting = false }

        do {
            let outcome = try await library.deleteAssets(withIdentifiers: ids)
            guard outcome.confirmed else { return }
            let removed = Set(ids)
            assets.removeAll { removed.contains($0.id) }
            // Subtract rather than clear: anything selected but filtered out of
            // view was not deleted, so silently dropping it would misrepresent
            // what happened. Restoring the filter brings it back, still checked.
            selected.subtract(removed)
            onDeleted(ids)   // reconcile home counts + other categories at once
            // Report what actually went, not what was asked for: some ids may
            // have been deleted elsewhere since this screen opened.
            await flashBanner(String(localized: "Deleted \(counted(outcome.deletedCount))"))
        } catch {
            await flashBanner(String(localized: "Couldn't delete: \(error.localizedDescription)"))
        }
    }

    private func flashBanner(_ text: String) async {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { banner = text }
        try? await Task.sleep(for: .seconds(2.5))
        withAnimation(.easeIn(duration: 0.2)) { banner = nil }
    }
}
