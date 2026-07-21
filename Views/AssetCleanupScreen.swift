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

    @State private var assets: [PhotoAsset]
    @Environment(\.photoLibrary) private var library

    @State private var selected: Set<PhotoAsset.ID> = []
    @State private var sizes: [PhotoAsset.ID: Int64] = [:]
    @State private var showConfirm = false
    @State private var isDeleting = false
    @State private var banner: String?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: Theme.Spacing.s)]

    init(
        category: CleanupCategory,
        assets: [PhotoAsset],
        onDeleted: @escaping ([PhotoAsset.ID]) -> Void = { _ in }
    ) {
        self.category = category
        self.onDeleted = onDeleted
        _assets = State(initialValue: assets)
    }

    // MARK: Derived display list

    /// The assets actually shown: optionally sorted largest-file-first once
    /// sizes are known, then capped to the category's display limit.
    private var displayed: [PhotoAsset] {
        var list = assets
        if category.sortsBySizeDescending, !sizes.isEmpty {
            list.sort { (sizes[$0.id] ?? 0) > (sizes[$1.id] ?? 0) }
        }
        if let limit = category.displayLimit {
            list = Array(list.prefix(limit))
        }
        return list
    }

    var body: some View {
        Group {
            if assets.isEmpty {
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
            "Delete \(selected.count) \(noun(selected.count))?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(selected.count)", role: .destructive) {
                Task { await performDelete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They'll move to Recently Deleted, where you can recover them for 30 days.")
        }
        .overlay(alignment: .top) { bannerView }
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
                }
            }
            .padding(Theme.Spacing.l)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: assets.count)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(allSelected ? "Deselect All" : "Select All") {
                if allSelected {
                    selected.removeAll()
                } else {
                    selected = Set(displayed.map(\.id))
                }
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
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.top, Theme.Spacing.s)
            .padding(.bottom, Theme.Spacing.xs)
            .background(.ultraThinMaterial)
        }
    }

    private var deleteButtonTitle: String {
        if isDeleting { return "Deleting…" }
        var title = "Delete \(selected.count) \(noun(selected.count))"
        let bytes = selectedBytes
        if bytes > 0 { title += " · frees ~\(bytes.formatted(.byteCount(style: .file)))" }
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
        return category.sortsBySizeDescending ? sizeText : nil
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String? {
        guard seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: Copy helpers

    private func noun(_ count: Int) -> String {
        count == 1 ? category.noun : category.noun + "s"
    }

    // MARK: Actions

    private func toggle(_ id: PhotoAsset.ID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func loadSizes() async {
        guard let library, sizes.isEmpty, !assets.isEmpty else { return }
        sizes = library.fileSizes(for: assets.map(\.id))
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
            await flashBanner("Deleted \(ids.count) \(noun(ids.count))")
        } catch {
            await flashBanner("Couldn't delete: \(error.localizedDescription)")
        }
    }

    private func flashBanner(_ text: String) async {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { banner = text }
        try? await Task.sleep(for: .seconds(2.5))
        withAnimation(.easeIn(duration: 0.2)) { banner = nil }
    }
}
