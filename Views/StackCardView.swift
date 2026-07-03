//
//  StackCardView.swift
//  TidyGallery
//
//  One stack, rendered as an elevated card: a header (how many photos, how many
//  will be freed) and a horizontal filmstrip of the photos. The best shot leads;
//  inferior duplicates follow, pre-checked for deletion.
//

import SwiftUI

struct StackCardView: View {
    let stack: ReviewModel.Stack
    let onOpenPreview: (PhotoAsset.ID) -> Void
    let onToggleDeletion: (PhotoAsset.ID) -> Void
    let onMakeBest: (PhotoAsset.ID) -> Void
    let onSelectAllExtras: () -> Void
    let onKeepAll: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            header
            filmstrip
            footerActions
        }
        .padding(Theme.Spacing.l)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .shadow(color: Theme.cardShadow(scheme), radius: 14, x: 0, y: 6)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(stack.assets.count) similar photos")
                    .font(.headline)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer()
            if stack.checkedForDeletion.count > 0 {
                Label("\(stack.checkedForDeletion.count)", systemImage: "trash.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Colors.destructive)
                    .monospacedDigit()
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(Theme.Colors.destructive.opacity(0.12), in: Capsule())
                    .accessibilityLabel("\(stack.checkedForDeletion.count) marked for deletion")
            }
        }
    }

    private var subtitle: String {
        let n = stack.checkedForDeletion.count
        if n == 0 { return "Keeping all — tap photos to remove" }
        return "Keeping the ★ best shot, removing \(n)"
    }

    // MARK: Filmstrip

    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.m) {
                ForEach(stack.rankedIDs, id: \.self) { id in
                    PhotoTileView(
                        assetID: id,
                        isBestShot: id == stack.bestShotID,
                        isChecked: stack.checkedForDeletion.contains(id),
                        onOpenPreview: { onOpenPreview(id) },
                        onToggleDeletion: { onToggleDeletion(id) },
                        onMakeBest: { onMakeBest(id) }
                    )
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, -2)
    }

    // MARK: Footer quick actions

    private var footerActions: some View {
        HStack(spacing: Theme.Spacing.m) {
            Button(action: onSelectAllExtras) {
                Label("Select extras", systemImage: "checklist")
            }
            .buttonStyle(QuietButtonStyle(tint: Theme.Colors.accent))

            Button(action: onKeepAll) {
                Label("Keep all", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(QuietButtonStyle(tint: Theme.Colors.textSecondary))

            Spacer()
        }
        .font(.subheadline.weight(.medium))
    }
}

/// A low-emphasis pill button used for the per-card quick actions.
struct QuietButtonStyle: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
            .background(tint.opacity(configuration.isPressed ? 0.20 : 0.10), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .frame(minHeight: 44)
    }
}
