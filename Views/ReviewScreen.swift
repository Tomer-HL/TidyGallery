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

    /// Records the implicit "I'm keeping these" for photos left unticked after a
    /// deletion. Separate from `onIgnore` because only this one is reversible:
    /// the coordinator remembers which ids it actually added.
    var onAutoKeep: (([PhotoAsset.ID]) -> Void)?

    /// Reverses the most recent automatic keep. Takes no ids on purpose — the
    /// coordinator knows which ones it added, and this view does not. `nil`
    /// hides the reversing button rather than showing one that does nothing.
    var onStopIgnoring: (() -> Void)?

    @State private var showConfirm = false
    @State private var isDeleting = false
    @State private var banner: Banner?
    @State private var bannerTask: Task<Void, Never>?
    @State private var preview: PreviewContext?
    /// Which photo's score breakdown is open. Built on demand only.
    @State private var explaining: ExplainContext?

    /// A transient message, optionally carrying the action that reverses it.
    ///
    /// The banner used to be a bare `String`, which was fine while it only
    /// reported things the user had just asked for. It stopped being fine when
    /// it became the sole disclosure of something the app decided on its own:
    /// after a deletion, every photo in the affected stacks that the user did
    /// NOT tick is written to the permanent ignore list, app-wide. The
    /// reasoning is sound — you have already curated that burst, so don't ask
    /// again — but not ticking a photo during a duplicate review says nothing
    /// about whether it is a blurry screenshot, and the decision suppressed it
    /// in every other category too.
    ///
    /// Undo is the smallest honest fix: it leaves the behaviour (which is
    /// usually right) and restores control at the moment it is taken, rather
    /// than requiring the user to discover the Ignored screen later and work out
    /// what happened.
    private struct Banner: Identifiable {
        let id = UUID()
        let text: String
        /// How many photos the auto-keep applied to, when it did. Drives the
        /// reversing button.
        ///
        /// A count, not a closure. Storing the action itself meant `Banner` held
        /// a snapshot of `self`, which made a (self-healing but real) retain
        /// cycle through the `@State` box and — worse — read `bannerTask`
        /// through that stale copy, so the cancellation could miss the live
        /// task. The view already knows how to reverse the keep; it only needs
        /// to be told that there is one.
        var keptCount: Int?
    }

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
        onIgnore: (([PhotoAsset.ID]) -> Void)? = nil,
        onAutoKeep: (([PhotoAsset.ID]) -> Void)? = nil,
        onStopIgnoring: (() -> Void)? = nil
    ) {
        _model = State(initialValue: ReviewModel(stacks: stacks))
        self.onDeleted = onDeleted
        self.onIgnore = onIgnore
        self.onAutoKeep = onAutoKeep
        self.onStopIgnoring = onStopIgnoring
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
        // Clearing `banner` matters as much as cancelling: leaving it set keeps
        // this screen's `ReviewModel` — and every stack in it — alive for the
        // rest of the dwell after the user has navigated away.
        .onDisappear {
            bannerTask?.cancel()
            banner = nil
        }
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
            HStack(spacing: Theme.Spacing.m) {
                Text(banner.text)
                    .font(.subheadline.weight(.semibold))
                if banner.keptCount != nil {
                    Button {
                        undoAutoKeep()
                    } label: {
                        // "Keep suggesting", not "Undo".
                        //
                        // Beside the text "Deleted 3 · won't suggest 5 again",
                        // an Undo button reads as "undo the deletion" — which is
                        // the one thing it does not do. A user chasing photos
                        // back out of Recently Deleted would tap it, get an
                        // unrelated confirmation, and learn nothing. Naming the
                        // action removes the ambiguity entirely.
                        Text("Keep suggesting")
                            .font(.subheadline.weight(.bold))
                            .underline()
                            // Inside the label, with a content shape: applied to
                            // the Button it would grow the layout frame while
                            // leaving the hit region the size of the glyph.
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, banner.keptCount == nil ? Theme.Spacing.m : Theme.Spacing.xs)
            .background(Theme.Colors.accent, in: Capsule())
            .padding(.top, Theme.Spacing.s)
            .transition(.move(edge: .top).combined(with: .opacity))
            // The banner is the ONLY disclosure that photos were auto-kept, and
            // it leaves after six seconds. Without this VoiceOver never mentions
            // it at all.
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isSummaryElement)
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
        // No Undo here: this one the user explicitly asked for, and the Ignored
        // screen is the right place to reverse a deliberate choice. Undo is for
        // decisions the app made on its own.
        flashBanner(String(localized: "Won't suggest \(ItemNoun.photo.counted(ids.count)) again"))
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

            if !survivors.isEmpty, let onAutoKeep {
                onAutoKeep(survivors)
                // Both counts are interpolated inline rather than via local
                // bindings, and the literal is single-line. Both are constraints
                // of the localization coverage check in
                // Scripts/build_localizations.py: it can't see inside a
                // multi-line (`"""`) literal, and it infers %@ vs %lld from the
                // interpolated expression's text — so hiding `counted(...)`
                // behind a `let` makes it guess `%lld` for what is really a
                // string, and the key it demands stops matching the one the app
                // looks up.
                // Says what happened to the kept photos, rather than just that
                // they were kept. "kept 5" reads as a neutral fact; it was in
                // truth the app deciding, on its own, never to mention those
                // five anywhere again.
                flashBanner(
                    String(localized: "Deleted \(ItemNoun.photo.counted(outcome.deletedCount)) · won't suggest \(ItemNoun.photo.counted(survivors.count)) again"),
                    // The only banner in the app reporting something the user
                    // did not ask for, so the only one offering to take it back.
                    keptCount: onStopIgnoring == nil ? nil : survivors.count
                )
            } else {
                flashBanner(String(localized: "Deleted \(ItemNoun.photo.counted(outcome.deletedCount))"))
            }
        } catch {
            // `String(localized:)`, not a bare literal: the key already exists
            // in both .strings files (AssetCleanupScreen adds it correctly), so
            // this was rendering in English on a Hebrew device for no reason.
            flashBanner(String(localized: "Couldn't delete: \(error.localizedDescription)"))
        }
    }

    /// Reverses the automatic keep the banner is reporting.
    ///
    /// Delegates the "which ids did that actually add" question to the
    /// coordinator — see `LibraryScanCoordinator.lastAutoIgnored`. A photo can
    /// survive a stack while *already* being ignored from an earlier, deliberate
    /// decision, and reversing that too would be the app overriding the user in
    /// the name of giving them control.
    private func undoAutoKeep() {
        guard let count = banner?.keptCount else { return }
        onStopIgnoring?()
        flashBanner(String(localized: "Will keep suggesting \(ItemNoun.photo.counted(count))"))
    }

    /// Shows a banner, optionally with an action that reverses what it reports.
    ///
    /// No longer `async`. It used to sleep for its own dwell time, which made
    /// every caller `await` a message it had nothing more to do with — and,
    /// worse, meant two banners in quick succession each cleared the other's
    /// state. The dwell now lives in a cancellable task keyed to the banner's
    /// id, so a newer message replaces an older one cleanly.
    private func flashBanner(_ text: String, keptCount: Int? = nil) {
        bannerTask?.cancel()
        let next = Banner(text: text, keptCount: keptCount)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { banner = next }

        bannerTask = Task { @MainActor in
            // Reversible banners stay up more than twice as long. 2.5s is enough
            // to read a confirmation of something you just did; it is not enough
            // to notice the app did something you didn't ask for, read what,
            // decide you disagree, and reach the button.
            try? await Task.sleep(for: .seconds(keptCount == nil ? 2.5 : 6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                // Only clear if it's still the same banner — a newer one that
                // arrived meanwhile owns the slot now.
                if banner?.id == next.id { banner = nil }
            }
        }
    }

}
