//
//  CleanupHomeView.swift
//  TidyGallery
//
//  The post-scan home. Instead of a crowded tab bar, cleanup categories are
//  presented as a scrollable list of cards (à la CleanMy®Phone): "Duplicates"
//  leads to the best-shot review flow, and the standalone categories each open a
//  reusable `AssetCleanupScreen`. Cards show a live count and dim to a dead-end
//  only when empty.
//

import SwiftUI

struct CleanupHomeView: View {
    let coordinator: LibraryScanCoordinator

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.m) {
                    header

                    // Duplicates / bursts — its own best-shot workflow.
                    categoryCard(
                        icon: "square.stack.3d.up.fill",
                        title: "Duplicates",
                        blurb: "Bursts and near-duplicates, with the best shot picked for you",
                        count: coordinator.stacks.count,
                        countLabel: "\(coordinator.stacks.count) group\(coordinator.stacks.count == 1 ? "" : "s")"
                    ) {
                        ReviewScreen(
                            stacks: coordinator.stacks,
                            onDeleted: { coordinator.noteDeleted(ids: $0) }
                        )
                    }

                    // Standalone flat-list categories.
                    flatCard(.screenshots, assets: coordinator.screenshots)
                    flatCard(.largeVideos, assets: coordinator.largeVideos)
                    flatCard(.bigFiles, assets: coordinator.bigFileCandidates)
                    flatCard(.screenRecordings, assets: coordinator.screenRecordings)
                    flatCard(.blurry, assets: coordinator.blurryPhotos)
                    flatCard(.food, assets: coordinator.foodPhotos)
                    flatCard(.pets, assets: coordinator.petPhotos)
                    flatCard(.documents, assets: coordinator.documentPhotos)
                    flatCard(.nature, assets: coordinator.naturePhotos)
                    flatCard(.selfies, assets: coordinator.selfiePhotos)
                }
                .padding(Theme.Spacing.l)
            }
            .background(Theme.Colors.background.ignoresSafeArea())
            .navigationTitle("Clean up")
        }
        .tint(Theme.Colors.accent)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Everything below is a suggestion.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.Colors.textPrimary)
            Text("Nothing is deleted until you select it and confirm.")
                .font(.subheadline)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.l)
        .background(Theme.Colors.surfaceMuted, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .padding(.bottom, Theme.Spacing.xs)
    }

    // MARK: Cards

    /// Card for a standalone `CleanupCategory` backed by a flat asset list.
    private func flatCard(_ category: CleanupCategory, assets: [PhotoAsset]) -> some View {
        categoryCard(
            icon: category.systemImage,
            title: category.title,
            blurb: category.blurb,
            count: assets.count,
            countLabel: "\(assets.count) \(category.noun)\(assets.count == 1 ? "" : "s")"
        ) {
            AssetCleanupScreen(
                category: category,
                assets: assets,
                onDeleted: { coordinator.noteDeleted(ids: $0) }
            )
        }
    }

    /// A single tappable category card. Navigates to `destination` unless the
    /// category is empty, in which case it renders as a dimmed, inert row.
    @ViewBuilder
    private func categoryCard<Destination: View>(
        icon: String,
        title: String,
        blurb: String,
        count: Int,
        countLabel: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        if count > 0 {
            NavigationLink {
                destination()
            } label: {
                cardBody(icon: icon, title: title, blurb: blurb, countLabel: countLabel, enabled: true)
            }
            .buttonStyle(.plain)
        } else {
            cardBody(icon: icon, title: title, blurb: blurb, countLabel: "None", enabled: false)
        }
    }

    private func cardBody(icon: String, title: String, blurb: String, countLabel: String, enabled: Bool) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 44, height: 44)
                .background(Theme.Colors.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(blurb)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Theme.Spacing.s)

            VStack(alignment: .trailing, spacing: 2) {
                Text(countLabel)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(enabled ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
                if enabled {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .opacity(enabled ? 1 : 0.5)
    }
}
