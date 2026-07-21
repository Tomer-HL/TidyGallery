//
//  IgnoredAssetsScreen.swift
//  TidyGallery
//
//  Review the photos the user has told the app to stop suggesting, and put them
//  back into circulation. Deliberately has NO delete action: this screen exists
//  to undo a "keep" decision, not to remove photos.
//

import SwiftUI

struct IgnoredAssetsScreen: View {
    @State private var assets: [PhotoAsset]
    /// Called with the assets that should stop being ignored.
    var onRestore: ([PhotoAsset.ID]) -> Void

    @State private var selected: Set<PhotoAsset.ID> = []
    @State private var banner: String?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: Theme.Spacing.s)]

    init(assets: [PhotoAsset], onRestore: @escaping ([PhotoAsset.ID]) -> Void) {
        _assets = State(initialValue: assets)
        self.onRestore = onRestore
    }

    var body: some View {
        Group {
            if assets.isEmpty {
                ContentUnavailableView {
                    Label("Nothing ignored", systemImage: "hand.raised")
                } description: {
                    Text("Photos you choose to keep will be listed here, and won't be suggested again.")
                }
                .foregroundStyle(Theme.Colors.textPrimary)
            } else {
                grid
            }
        }
        .background(Theme.Colors.background.ignoresSafeArea())
        .navigationTitle("Ignored")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    selected = allSelected ? [] : Set(assets.map(\.id))
                }
                .tint(Theme.Colors.accent)
            }
        }
        .safeAreaInset(edge: .bottom) { restoreBar }
        .overlay(alignment: .top) { bannerView }
    }

    private var allSelected: Bool {
        !assets.isEmpty && selected.count == assets.count
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Theme.Spacing.s) {
                ForEach(assets) { asset in
                    AssetTileView(
                        assetID: asset.id,
                        isSelected: selected.contains(asset.id),
                        isVideo: asset.isVideo,
                        subtitle: nil,
                        noun: "ignored photo",
                        onToggle: { toggle(asset.id) }
                    )
                }
            }
            .padding(Theme.Spacing.l)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: assets.count)
        }
    }

    @ViewBuilder private var restoreBar: some View {
        if !selected.isEmpty {
            Button {
                let ids = Array(selected)
                let removed = Set(ids)
                assets.removeAll { removed.contains($0.id) }
                selected.removeAll()
                onRestore(ids)
                Task { await flashBanner("Restored \(ids.count) photo\(ids.count == 1 ? "" : "s")") }
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("Stop ignoring \(selected.count)")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Theme.Colors.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.top, Theme.Spacing.s)
            .padding(.bottom, Theme.Spacing.xs)
            .background(.ultraThinMaterial)
        }
    }

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

    private func toggle(_ id: PhotoAsset.ID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func flashBanner(_ text: String) async {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { banner = text }
        try? await Task.sleep(for: .seconds(2.5))
        withAnimation(.easeIn(duration: 0.2)) { banner = nil }
    }
}
