//
//  ScreenshotsScreen.swift
//  TidyGallery
//
//  A grid of all screenshots with multi-select and a confirmation-gated delete.
//  Screenshots aren't near-duplicates, so there's no best-shot logic — just pick
//  the ones to clear. Reuses the size estimate and the safe deletion path.
//

import SwiftUI

struct ScreenshotsScreen: View {
    @State private var assets: [PhotoAsset]
    @Environment(\.photoLibrary) private var library

    @State private var selected: Set<PhotoAsset.ID> = []
    @State private var sizes: [PhotoAsset.ID: Int64] = [:]
    @State private var showConfirm = false
    @State private var isDeleting = false
    @State private var banner: String?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: Theme.Spacing.s)]

    init(assets: [PhotoAsset]) {
        _assets = State(initialValue: assets)
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
        .navigationTitle("Screenshots")
        .toolbar { toolbarContent }
        .task { await loadSizes() }
        .safeAreaInset(edge: .bottom) { deleteBar }
        .confirmationDialog(
            "Delete \(selected.count) screenshot\(selected.count == 1 ? "" : "s")?",
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
                ForEach(assets) { asset in
                    ScreenshotTileView(
                        assetID: asset.id,
                        isSelected: selected.contains(asset.id),
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
            Button(selected.count == assets.count ? "Deselect All" : "Select All") {
                if selected.count == assets.count {
                    selected.removeAll()
                } else {
                    selected = Set(assets.map(\.id))
                }
            }
            .tint(Theme.Colors.accent)
        }
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
        var title = "Delete \(selected.count) screenshot\(selected.count == 1 ? "" : "s")"
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
            Label("No screenshots", systemImage: "camera.viewfinder")
        } description: {
            Text("You don't have any screenshots to clean up right now.")
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
            await flashBanner("Deleted \(ids.count) screenshot\(ids.count == 1 ? "" : "s")")
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
