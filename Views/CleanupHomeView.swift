//
//  CleanupHomeView.swift
//  TidyGallery
//
//  The post-scan home dashboard. A summary card up top shows how much space is
//  reclaimable; below it, cleanup categories are grouped into sections
//  ("Reclaim space", "Clutter", "By content"). "Duplicates" leads to the
//  best-shot review flow; the standalone categories each open a reusable
//  `AssetCleanupScreen`. Cards show a live count and dim to a dead-end only when
//  empty.
//

import SwiftUI

struct CleanupHomeView: View {
    let coordinator: LibraryScanCoordinator

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.m) {
                    summaryCard

                    sectionHeader("Reclaim space")
                    duplicatesCard
                    flatCard(.largeVideos, assets: coordinator.largeVideos)
                    flatCard(.bigFiles, assets: coordinator.bigFileCandidates)
                    flatCard(.screenRecordings, assets: coordinator.screenRecordings)

                    sectionHeader("Clutter")
                    flatCard(.screenshots, assets: coordinator.screenshots)
                    flatCard(.blurry, assets: coordinator.blurryPhotos)

                    sectionHeader("By content")
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

    // MARK: Summary card

    private var summaryCard: some View {
        let summary = coordinator.storageSummary
        return VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Up to")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text(summary.reclaimableBytes > 0
                     ? summary.reclaimableBytes.formatted(.byteCount(style: .file))
                     : "0 KB")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .monospacedDigit()
                Text("reclaimable across duplicates, videos, and large files")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            if summary.hasReclaimableSpace {
                VStack(spacing: Theme.Spacing.xs) {
                    breakdownRow("Duplicates", summary.duplicates)
                    breakdownRow("Large videos", summary.largeVideos)
                    breakdownRow("Big files", summary.bigFiles)
                    breakdownRow("Screen recordings", summary.screenRecordings)
                }
            }

            Divider().overlay(Theme.Colors.hairline)

            Text("Everything below is a suggestion — nothing is deleted until you select it and confirm.")
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    @ViewBuilder
    private func breakdownRow(_ title: String, _ item: StorageSummary.LineItem) -> some View {
        if item.bytes > 0 {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
                Text(item.bytes.formatted(.byteCount(style: .file)))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.textPrimary)
            }
        }
    }

    // MARK: Section header

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(Theme.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Theme.Spacing.s)
            .padding(.leading, Theme.Spacing.xs)
    }

    // MARK: Cards

    private var duplicatesCard: some View {
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
    }

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
