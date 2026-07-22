//
//  OnboardingView.swift
//  TidyGallery
//
//  Shown once, before the first scan. For an app that deletes photos, the most
//  important thing to establish up front is the safety promise — so that's the
//  hero point, not a footnote.
//

import SwiftUI

/// Remembers whether onboarding has been shown.
enum OnboardingStore {
    private static let key = "tidygallery.hasOnboarded"
    static var hasOnboarded: Bool { UserDefaults.standard.bool(forKey: key) }
    static func markSeen() { UserDefaults.standard.set(true, forKey: key) }
}

struct OnboardingView: View {
    var onContinue: () -> Void

    private struct Point: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let body: String
        let tint: Color
    }

    private var points: [Point] {
        [
            Point(
                icon: "checkmark.shield.fill",
                title: "Nothing is deleted without you",
                body: "TidyGallery only ever suggests. You review, you select, and iOS asks you to confirm before a single photo is removed.",
                tint: Theme.Colors.best
            ),
            Point(
                icon: "iphone",
                title: "Everything stays on your phone",
                body: "All analysis runs on-device with Apple's own frameworks. Your photos are never uploaded anywhere.",
                tint: Theme.Colors.accent
            ),
            Point(
                icon: "square.stack.3d.up.fill",
                title: "Finds what's worth clearing",
                body: "Duplicates and near-duplicate bursts, large videos and files, screenshots, and blurry shots — with the best shot picked for you.",
                tint: Theme.Colors.accent
            ),
            Point(
                icon: "trash.slash.fill",
                title: "Deleted photos are recoverable",
                body: "Anything you remove goes to Recently Deleted, where iOS keeps it for 30 days.",
                tint: Theme.Colors.best
            )
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Theme.Spacing.xl) {
                    VStack(spacing: Theme.Spacing.s) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 52))
                            .foregroundStyle(Theme.Colors.accent)
                            .symbolRenderingMode(.hierarchical)
                            .padding(.top, Theme.Spacing.xxl)
                        Text("Welcome to TidyGallery")
                            .font(.largeTitle.bold())
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .multilineTextAlignment(.center)
                        Text("A calmer way to clean up your photos.")
                            .font(.body)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }

                    VStack(spacing: Theme.Spacing.l) {
                        ForEach(points) { point in
                            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                                Image(systemName: point.icon)
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(point.tint)
                                    .frame(width: 40, height: 40)
                                    .background(point.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(point.title)
                                        .font(.headline)
                                        .foregroundStyle(Theme.Colors.textPrimary)
                                    Text(point.body)
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.Colors.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.l)
                }
                .padding(.bottom, Theme.Spacing.xl)
            }

            Button {
                OnboardingStore.markSeen()
                onContinue()
            } label: {
                Text("Get started")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Theme.Colors.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.l)
        }
        .background(Theme.Colors.background.ignoresSafeArea())
    }
}
