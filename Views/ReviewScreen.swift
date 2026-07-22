//
//  ReviewScreen.swift
//  TidyGallery
//
//  The main Phase 2 surface: a scrollable list of stack cards with a pinned,
//  safe-area-aware "Delete" bar. Deletion is gated by an explicit confirmation
//  and only ever removes the photos the user has checked — never automatically.
//

import SwiftUI

struct ReviewScreen: View {
    @State private var model: ReviewModel
    @Environment(\.photoLibrary) private var library
    /// Called after a successful deletion so the coordinator can reconcile the
    /// home counts and other category screens immediately.
    var onDeleted: ([PhotoAsset.ID]) -> Void
    /// Record photos as "never suggest again". `nil` hides the action.
    ///
    /// This screen previously had no way to reach the ignore list at all: the
    /// only "keep" affordance was `clearChecks`, which unticks boxes in memory.
    /// So a user who carefully kept photos here saw nothing recorded, nothing on
    /// the Ignored screen, and the same photos pre-selected again after the next
    /// scan — the app quietly forgetting every decision they made.
    var onIgnore: (([PhotoAsset.ID]) -> Void)?

    @State private var showConfirm = false
    @State private var isDeleting = false
    @State private var banner: String?
    @State private var preview: PreviewContext?
    /// Which photo's score breakdown is open. Built on demand only.
    @State private var explaining: ExplainContext?

    /// Identifies the photo being explained and the stack it belongs to, so the
    /// breakdown can compare it against that group's best shot.
    private struct ExplainContext: Identifiable {
        let id = UUID()
        let stackID: UUID
        let assetID: PhotoAsset.ID
    }

    /// Identifies which photo (and stack) the full-screen preview should open at.
    private struct PreviewContext: Identifiable {
        let id = UUID()
        let stackID: UUID
        let startAssetID: PhotoAsset.ID
    }

    init(
        stacks: [PhotoStack],
        onDeleted: @escaping ([PhotoAsset.ID]) -> Void = { _ in },
        onIgnore: (([PhotoAsset.ID]) -> Void)? = nil
    ) {
        _model = State(initialValue: ReviewModel(stacks: stacks))
        self.onDeleted = onDeleted
        self.onIgnore = onIgnore
    }

    var body: some View {
        Group {
            if model.stacks.isEmpty {
                allClearState
            } else {
                list
            }
        }
        .background(Theme.Colors.background.ignoresSafeArea())
        .task { if let library { await model.loadSizes(using: library) } }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom) { deleteBar }
        .confirmationDialog(
            String(localized: "Delete \(ItemNoun.photo.counted(model.totalPhotosToDelete))?"),
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete \(model.totalPhotosToDelete)"), role: .destructive) {
                Task { await performDelete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They'll move to Recently Deleted, where you can recover them for 30 days.")
        }
        .overlay(alignment: .top) { bannerView }
        .fullScreenCover(item: $preview) { ctx in
            PhotoPreviewView(model: model, stackID: ctx.stackID, startAssetID: ctx.startAssetID)
        }
        .sheet(item: $explaining) { ctx in
            breakdown(for: ctx)
        }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.l) {
                ForEach(model.stacks) { stack in
                    StackCardView(
                        stack: stack,
                        reclaimBytes: model.bytesToFree(inStack: stack.id),
                        onOpenPreview: { preview = PreviewContext(stackID: stack.id, startAssetID: $0) },
                        onToggleDeletion: { model.toggleDeletion(of: $0, inStack: stack.id) },
                        onMakeBest: { model.setBestShot($0, inStack: stack.id) },
                        onSelectAllExtras: { model.checkAllExtras(inStack: stack.id) },
                        onKeepAll: { model.clearChecks(inStack: stack.id) },
                        onNeverSuggest: onIgnore == nil ? nil : { neverSuggest(stack) },
                        onExplain: { explaining = ExplainContext(stackID: stack.id, assetID: $0) }
                    )
                }
            }
            .padding(Theme.Spacing.l)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.stacks.count)
        }
    }

    // MARK: Bottom delete bar

    @ViewBuilder private var deleteBar: some View {
        if model.hasSelection {
            Button {
                showConfirm = true
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    if isDeleting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "trash.fill")
                    }
                    Text(deleteButtonTitle)
                        .monospacedDigit()
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

    // MARK: All-clear empty state

    private var allClearState: some View {
        ContentUnavailableView {
            Label("All tidy", systemImage: "checkmark.seal.fill")
        } description: {
            Text("No more duplicate stacks to review. Your gallery is looking clean.")
        }
        .foregroundStyle(Theme.Colors.textPrimary)
    }

    // MARK: Success banner

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

    // MARK: Delete button label

    private var deleteButtonTitle: String {
        if isDeleting { return String(localized: "Deleting…") }
        let n = model.totalPhotosToDelete
        var title = String(localized: "Delete \(ItemNoun.photo.counted(n))")
        if model.totalBytesToFree > 0 {
            title += String(localized: " · frees ~\(model.totalBytesToFree.formatted(.byteCount(style: .file)))")
        }
        return title
    }

    // MARK: Score breakdown

    /// Builds the breakdown for one photo, comparing it against its group's best
    /// shot. Only ever constructed when the user opens the sheet.
    @ViewBuilder
    private func breakdown(for ctx: ExplainContext) -> some View {
        if let stack = model.stacks.first(where: { $0.id == ctx.stackID }),
           let asset = stack.asset(ctx.assetID),
           let score = asset.score {
            let isBest = ctx.assetID == stack.bestShotID
            ScoreBreakdownView(
                score: score,
                bestShotScore: isBest ? nil : stack.asset(stack.bestShotID)?.score,
                isBestShot: isBest,
                labels: asset.classificationLabels,
                config: .default
            )
        }
    }

    // MARK: Never-suggest action

    /// "I'm keeping this entire group — stop asking about it."
    ///
    /// The deletion checks are cleared *first*, deliberately. Without that, this
    /// action would add photos the user had queued for deletion to the list of
    /// photos they want to keep — two opposite intentions applied to the same
    /// photo in one tap. Clearing first makes the button mean exactly one thing:
    /// nothing here is being deleted, and none of it should come back.
    private func neverSuggest(_ stack: ReviewModel.Stack) {
        guard let onIgnore else { return }
        let ids = stack.assets.map(\.id)
        guard !ids.isEmpty else { return }

        model.clearChecks(inStack: stack.id)
        onIgnore(ids)
        model.removeStack(stack.id)
        Task {
            await flashBanner(
                String(localized: "Won't suggest \(ItemNoun.photo.counted(ids.count)) again")
            )
        }
    }

    // MARK: Delete action

    private func performDelete() async {
        guard let library else { return }
        let ids = model.assetsToDelete
        guard !ids.isEmpty else { return }

        isDeleting = true
        defer { isDeleting = false }

        do {
            let outcome = try await library.deleteAssets(withIdentifiers: ids)
            guard outcome.confirmed else { return }   // user cancelled the system sheet

            // Read the survivors BEFORE `removeDeleted` mutates the stacks.
            //
            // Choosing which photos to delete from a group is also, implicitly,
            // choosing which to keep — and that second half of the decision used
            // to be thrown away. Recording it here means a photo you kept out of
            // a burst is never offered up again, without you having to say so
            // twice. Only groups this deletion actually touched count: leaving a
            // group alone isn't a decision about it.
            let survivors = model.survivors(ofStacksAffectedBy: ids)

            model.removeDeleted(ids)
            onDeleted(ids)   // reconcile home counts + other categories at once

            if !survivors.isEmpty, let onIgnore {
                onIgnore(survivors)
                // Both counts are interpolated inline rather than via local
                // bindings, and the literal is single-line. Both are constraints
                // of the localization coverage check in
                // Scripts/build_localizations.py: it can't see inside a
                // multi-line (`"""`) literal, and it infers %@ vs %lld from the
                // interpolated expression's text — so hiding `counted(...)`
                // behind a `let` makes it guess `%lld` for what is really a
                // string, and the key it demands stops matching the one the app
                // looks up.
                await flashBanner(
                    String(localized: "Deleted \(ItemNoun.photo.counted(outcome.deletedCount)) · kept \(ItemNoun.photo.counted(survivors.count))")
                )
            } else {
                await flashBanner(String(localized: "Deleted \(ItemNoun.photo.counted(outcome.deletedCount))"))
            }
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
