//
//  AssetCleanupScreen.swift
//  TidyGallery
//
//  One reusable grid screen for every "flat list" cleanup category: screenshots,
//  large videos, big files, screen recordings, and possibly-blurry singles.
//  There is no best-shot logic here (that lives in `ReviewScreen`) and NOTHING
//  is pre-selected — the user multi-selects and confirms, and deletion routes
//  through the single safe `PhotoLibraryService.deleteAssets` path, which also
//  triggers the system's own confirmation sheet.
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
            String(localized: "Delete \(counted(selected.count))?"),
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete \(selected.count)"), role: .destructive) {
                Task { await performDelete() }
            }
            Button("Cancel", role: .cancel) {}
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
                    selected.removeAll()
                } else {
                    selected = Set(displayed.map(\.id))
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
                if !selected.isEmpty {
                    Divider()
                    Button {
                        Task { await exportSelectionToAlbum() }
                    } label: {
                        Label("Add \(selected.count) to album", systemImage: "rectangle.stack.badge.plus")
                    }
                    .disabled(isExporting)
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .tint(Theme.Colors.accent)
        }
    }

    private var allSelected: Bool {
        !displayed.isEmpty && selected.count == displayed.count
    }

    // MARK: Delete bar

    @ViewBuilder private var deleteBar: some View {
        if !selected.isEmpty {
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
                let ids = Array(selected)
                let removed = Set(ids)
                assets.removeAll { removed.contains($0.id) }
                selected.removeAll()
                onIgnore(ids)
                Task { await flashBanner(String(localized: "Won't suggest \(counted(ids.count)) again")) }
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "hand.raised.fill")
                    Text("Keep \(selected.count) — don't suggest again")
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
        var title = String(localized: "Delete \(counted(selected.count))")
        let bytes = selectedBytes
        if bytes > 0 { title += String(localized: " · frees ~\(bytes.formatted(.byteCount(style: .file)))") }
        return title
    }

    private var selectedBytes: Int64 {
        selected.reduce(0) { $0 + (sizes[$1] ?? 0) }
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
        guard let library, !selected.isEmpty else { return }
        let ids = Array(selected)
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
        // lookup, ~10 ms each. Off the main actor it doesn't stutter the grid.
        sizes = await library.fileSizes(for: assets.map(\.id))
    }

    private func performDelete() async {
        guard let library else { return }
        let ids = Array(selected)
        guard !ids.isEmpty else { return }

        isDeleting = true
        defer { isDeleting = false }

        do {
            let confirmed = try await library.deleteAssets(withIdentifiers: ids)
            guard confirmed else { return }
            let removed = Set(ids)
            assets.removeAll { removed.contains($0.id) }
            selected.removeAll()
            onDeleted(ids)   // reconcile home counts + other categories at once
            await flashBanner(String(localized: "Deleted \(counted(ids.count))"))
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
