//
//  CleanupHomeView.swift
//  TidyGallery
//
//  The post-scan home dashboard. A summary card up top shows a storage ring
//  (where reclaimable space lives, against the rest of the library), the total
//  library size, a one-tap "Recommended cleanup", and a per-category breakdown.
//  Below it, cleanup categories are grouped into sections ("Reclaim space",
//  "Clutter", "By content"). "Duplicates" leads to the best-shot review flow;
//  standalone categories each open a reusable `AssetCleanupScreen`.
//

import SwiftUI

struct CleanupHomeView: View {
    let coordinator: LibraryScanCoordinator

    @State private var showSettings = false

    // Colours shared by the ring segments and the breakdown legend.
    private let colorExactDuplicates = Color.green
    private let colorDuplicates = Theme.Colors.accent
    private let colorVideos = Theme.Colors.best
    private let colorBigFiles = Theme.Colors.destructive
    private let colorScreenshots = Color.purple
    private let colorRecordings = Color.teal

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.m) {
                    analysisBanner
                    iCloudBanner
                    summaryCard

                    sectionHeader("Reclaim space")
                    exactDuplicatesCard
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

                    sectionHeader("Your decisions")
                    ignoredCard
                }
                .padding(Theme.Spacing.l)
            }
            .background(Theme.Colors.background.ignoresSafeArea())
            .navigationTitle("Clean up")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section("Rescan") {
                            ForEach(ScanScope.allCases) { option in
                                Button {
                                    Task { await coordinator.rescan(scope: option) }
                                } label: {
                                    if option == coordinator.scope {
                                        Label(option.label, systemImage: "checkmark")
                                    } else {
                                        Text(option.label)
                                    }
                                }
                            }
                        }
                        Divider()
                        Button {
                            showSettings = true
                        } label: {
                            Label("Detection settings", systemImage: "slider.horizontal.3")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .tint(Theme.Colors.accent)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsScreen(current: coordinator.tuning) { newTuning in
                    Task { await coordinator.applyTuning(newTuning) }
                }
            }
            .overlay {
                if coordinator.isRetuning {
                    retuningOverlay
                }
            }
        }
        .tint(Theme.Colors.accent)
    }

    /// Shown while new detection settings are being applied (which may involve
    /// a full re-scan).
    private var retuningOverlay: some View {
        ZStack {
            Theme.Colors.background.opacity(0.85).ignoresSafeArea()
            VStack(spacing: Theme.Spacing.m) {
                ProgressView().controlSize(.large).tint(Theme.Colors.accent)
                Text("Applying new settings…")
                    .font(.headline)
                    .foregroundStyle(Theme.Colors.textPrimary)
            }
        }
    }

    // MARK: Analysis banner

    /// Shown while Vision analysis is still running. The categories above it are
    /// already usable — this just explains why Duplicates and the content
    /// categories are still filling in.
    @ViewBuilder
    private var analysisBanner: some View {
        if let progress = coordinator.analysisProgress {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.s) {
                    ProgressView().controlSize(.small).tint(Theme.Colors.accent)
                    Text("Still looking for duplicates…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Spacer()
                    if progress.total > 0 {
                        Text("\(progress.done) of \(progress.total)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
                if progress.total > 0 {
                    ProgressView(value: progress.fraction).tint(Theme.Colors.accent)
                }
                Text("Everything below is ready to use now.")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .padding(Theme.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.surfaceMuted, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    // MARK: iCloud banner

    /// Explains photos that couldn't be analysed because they live only in
    /// iCloud, rather than dropping them silently. Offers the one-tap fix.
    @ViewBuilder
    private var iCloudBanner: some View {
        let skipped = coordinator.iCloudSkippedCount
        if skipped > 0, coordinator.analysisProgress == nil {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Label {
                    Text("\(skipped) photo\(skipped == 1 ? "" : "s") stored in iCloud")
                        .font(.subheadline.weight(.semibold))
                } icon: {
                    Image(systemName: "icloud.and.arrow.down")
                }
                .foregroundStyle(Theme.Colors.textPrimary)

                Text("They weren't analysed, so they're missing from Duplicates and the content categories. Analysing them means downloading them, which uses data.")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Download and analyse them") {
                    var updated = coordinator.tuning
                    updated.analyseICloudPhotos = true
                    Task { await coordinator.applyTuning(updated) }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.Colors.accent)
            }
            .padding(Theme.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.surfaceMuted, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    // MARK: Summary card

    private var summaryCard: some View {
        let summary = coordinator.storageSummary
        return VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            StorageRingView(summary: summary, totalLibraryBytes: coordinator.totalLibraryBytes)
                .frame(maxWidth: .infinity)

            Group {
                if let total = coordinator.totalLibraryBytes {
                    Text("of \(total.formatted(.byteCount(style: .file))) in your library")
                } else {
                    Text("Measuring library size…")
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
            .frame(maxWidth: .infinity)

            recommendedButton

            if summary.hasReclaimableSpace {
                VStack(spacing: Theme.Spacing.xs) {
                    breakdownRow("Exact duplicates", summary.exactDuplicates, colorExactDuplicates)
                    breakdownRow("Duplicate extras", summary.duplicates, colorDuplicates)
                    breakdownRow("Large videos", summary.largeVideos, colorVideos)
                    breakdownRow("Big files", summary.bigFiles, colorBigFiles)
                    breakdownRow("Screenshots", summary.screenshots, colorScreenshots)
                    breakdownRow("Screen recordings", summary.screenRecordings, colorRecordings)
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
    private var recommendedButton: some View {
        let recommended = coordinator.recommendedAssets
        if !recommended.isEmpty {
            NavigationLink {
                AssetCleanupScreen(
                    category: .recommended,
                    assets: recommended,
                    initiallySelected: Set(recommended.map(\.id)),
                    onDeleted: { coordinator.noteDeleted(ids: $0) }
                )
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "wand.and.stars")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Recommended cleanup")
                            .font(.headline)
                        Text("\(recommended.count) safe duplicate\(recommended.count == 1 ? "" : "s") to review")
                            .font(.caption)
                            .opacity(0.9)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(Theme.Spacing.m)
                .frame(maxWidth: .infinity)
                .background(Theme.Colors.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func breakdownRow(_ title: String, _ item: StorageSummary.LineItem, _ color: Color) -> some View {
        if item.bytes > 0 {
            HStack(spacing: Theme.Spacing.s) {
                Circle().fill(color).frame(width: 9, height: 9)
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

    /// Byte-identical copies. Opens pre-checked: unlike visual near-duplicates
    /// there's no judgement call, and one copy of each is always kept.
    private var exactDuplicatesCard: some View {
        let extras = coordinator.exactDuplicateExtras
        return categoryCard(
            icon: CleanupCategory.exactDuplicates.systemImage,
            title: CleanupCategory.exactDuplicates.title,
            blurb: CleanupCategory.exactDuplicates.blurb,
            count: extras.count,
            countLabel: "\(extras.count) cop\(extras.count == 1 ? "y" : "ies")"
        ) {
            AssetCleanupScreen(
                category: .exactDuplicates,
                assets: extras,
                initiallySelected: Set(extras.map(\.id)),
                onDeleted: { coordinator.noteDeleted(ids: $0) }
            )
        }
    }

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
                onDeleted: { coordinator.noteDeleted(ids: $0) },
                onIgnore: { ids in Task { await coordinator.ignore(ids: ids) } }
            )
        }
    }

    /// Review and undo "don't suggest again" decisions.
    private var ignoredCard: some View {
        let ignored = coordinator.ignoredAssets
        return categoryCard(
            icon: "hand.raised",
            title: "Ignored",
            blurb: "Photos you chose to keep — never suggested again",
            count: ignored.count,
            countLabel: "\(ignored.count) photo\(ignored.count == 1 ? "" : "s")"
        ) {
            IgnoredAssetsScreen(
                assets: ignored,
                onRestore: { ids in Task { await coordinator.stopIgnoring(ids: ids) } }
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
