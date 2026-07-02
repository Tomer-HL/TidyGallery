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

    @State private var showConfirm = false
    @State private var isDeleting = false
    @State private var banner: String?

    init(stacks: [PhotoStack]) {
        _model = State(initialValue: ReviewModel(stacks: stacks))
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
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom) { deleteBar }
        .confirmationDialog(
            "Delete \(model.totalPhotosToDelete) photo\(model.totalPhotosToDelete == 1 ? "" : "s")?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(model.totalPhotosToDelete)", role: .destructive) {
                Task { await performDelete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They'll move to Recently Deleted, where you can recover them for 30 days.")
        }
        .overlay(alignment: .top) { bannerView }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.l) {
                ForEach(model.stacks) { stack in
                    StackCardView(
                        stack: stack,
                        onToggleDeletion: { model.toggleDeletion(of: $0, inStack: stack.id) },
                        onMakeBest: { model.setBestShot($0, inStack: stack.id) },
                        onSelectAllExtras: { model.checkAllExtras(inStack: stack.id) },
                        onKeepAll: { model.clearChecks(inStack: stack.id) }
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
                    Text(isDeleting
                         ? "Deleting…"
                         : "Delete \(model.totalPhotosToDelete) photo\(model.totalPhotosToDelete == 1 ? "" : "s")")
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

    // MARK: Delete action

    private func performDelete() async {
        guard let library else { return }
        let ids = model.assetsToDelete
        guard !ids.isEmpty else { return }

        isDeleting = true
        defer { isDeleting = false }

        do {
            let confirmed = try await library.deleteAssets(withIdentifiers: ids)
            guard confirmed else { return }   // user cancelled the system sheet
            model.removeDeleted(ids)
            await flashBanner("Deleted \(ids.count) photo\(ids.count == 1 ? "" : "s")")
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
