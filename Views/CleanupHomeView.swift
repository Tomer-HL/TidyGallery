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
    @State private var showDiagnostics = false

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
                    ignoreFailureBanner
                    iCloudBanner

                    if showAllClear {
                        allClearCard
                    }

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
                        Button {
                            showDiagnostics = true
                        } label: {
                            Label("Diagnostics", systemImage: "stopwatch")
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
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsScreen(coordinator: coordinator)
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

    // MARK: Ignore-list failure banner

    /// Shown when a "don't suggest again" decision couldn't be written to disk.
    ///
    /// Worth a banner rather than a log line: the photos will have disappeared
    /// from their category, so the app *looks* like it did what was asked. The
    /// user would only find out at the next launch, when everything they kept
    /// came back — with no way to know why, or that it had happened at all.
    @ViewBuilder
    private var ignoreFailureBanner: some View {
        if coordinator.ignoreListWriteFailed {
            Label {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Couldn't save your choice")
                        .font(.subheadline.weight(.semibold))
                    Text("The photos you kept are hidden for now, but the decision wasn't written to storage and won't survive a restart.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.destructive)
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
                    Text(String(localized: "\(ItemNoun.photo.counted(skipped)) stored in iCloud"))
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

    // MARK: All-clear

    /// Whether the scan finished and found nothing actionable at all.
    private var showAllClear: Bool {
        coordinator.analysisProgress == nil
            && coordinator.stacks.isEmpty
            && coordinator.exactDuplicateExtras.isEmpty
            && coordinator.screenshots.isEmpty
            && coordinator.largeVideos.isEmpty
            && coordinator.bigFileCandidates.isEmpty
            && coordinator.screenRecordings.isEmpty
            && coordinator.blurryPhotos.isEmpty
            && coordinator.foodPhotos.isEmpty
            && coordinator.petPhotos.isEmpty
            && coordinator.documentPhotos.isEmpty
            && coordinator.naturePhotos.isEmpty
            && coordinator.selfiePhotos.isEmpty
    }

    private var allClearCard: some View {
        VStack(spacing: Theme.Spacing.s) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.Colors.best)
                .symbolRenderingMode(.hierarchical)
            Text("All tidy")
                .font(.title2.bold())
                .foregroundStyle(Theme.Colors.textPrimary)
            Text("Nothing to clean up in this range. Try a wider scan from the menu above to look further back.")
                .font(.subheadline)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
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
                        Text(String(localized: "\(ItemNoun.safeDuplicate.counted(recommended.count)) to review"))
                            .font(.caption)
                            .opacity(0.9)
                    }
                    Spacer()
                    // `.forward`, not `.right`: the semantic variant mirrors in
                    // right-to-left layouts, so in Hebrew this points left — the
                    // direction "onward" actually is. `chevron.right` would keep
                    // pointing back the way the user came.
                    Image(systemName: "chevron.forward").font(.caption.weight(.bold))
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

    /// `LocalizedStringKey`, not `String`: a `String` handed to `Text` is
    /// passed through verbatim, so this helper was quietly the one place on the
    /// home screen that could never be translated.
    ///
    /// `.textCase(.uppercase)` replaces `title.uppercased()` for the same
    /// reason it's applied as a style rather than baked into the text — it is a
    /// visual treatment for a cased script, and a no-op in Hebrew.
    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .textCase(.uppercase)
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
            countLabel: ItemNoun.copy.counted(extras.count)
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
            title: String(localized: "Duplicates"),
            blurb: String(localized: "Bursts and near-duplicates, with the best shot picked for you"),
            count: coordinator.stacks.count,
            countLabel: ItemNoun.group.counted(coordinator.stacks.count)
        ) {
            ReviewScreen(
                stacks: coordinator.stacks,
                onDeleted: { coordinator.noteDeleted(ids: $0) },
                onIgnore: { ids in Task { await coordinator.ignore(ids: ids) } }
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
            countLabel: category.noun.counted(assets.count)
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
            title: String(localized: "Ignored"),
            blurb: String(localized: "Photos you chose to keep — never suggested again"),
            count: ignored.count,
            countLabel: ItemNoun.photo.counted(ignored.count)
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
                    // Semantic direction, so it mirrors in Hebrew. See above.
                    Image(systemName: "chevron.forward")
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
