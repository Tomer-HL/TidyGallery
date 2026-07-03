//
//  ContentView.swift
//  TidyGallery
//
//  Root surface. Drives the scan lifecycle (idle → scanning → review) and hands
//  off to `ReviewScreen` when stacks are ready. Each phase gets a purpose-built,
//  on-brand state rather than a bare spinner.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @State var coordinator: LibraryScanCoordinator

    var body: some View {
        // The finished state is a TabView whose tabs own their own navigation;
        // the transient scan states are simple centered screens.
        if case .finished = coordinator.phase {
            MainTabView(coordinator: coordinator)
        } else {
            ZStack {
                Theme.Colors.background.ignoresSafeArea()
                content
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch coordinator.phase {
        case .idle:
            startState
        case .requestingAccess:
            progressState("Requesting photo access…")
        case let .scanning(analysed, _):
            progressState("Analysing your library…", detail: "\(analysed) photos scanned")
        case .clustering:
            progressState("Grouping similar photos…")
        case .accessDenied:
            accessDeniedState
        case let .failed(message):
            messageState(icon: "exclamationmark.triangle.fill",
                         title: "Scan failed",
                         detail: message)
        case .finished:
            EmptyView()   // handled above by MainTabView
        }
    }

    // MARK: States

    private var startState: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.Colors.accent)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: Theme.Spacing.s) {
                Text("Tidy your gallery")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text("TidyGallery finds bursts and near-duplicates on-device, picks the best shot, and lets you clear the rest — nothing is deleted without your say-so.")
                    .font(.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.xl)
            }
            Spacer()
            Button {
                Task { await coordinator.scan() }
            } label: {
                Text("Scan my library")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Theme.Colors.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.l)
        }
    }

    private func progressState(_ title: String, detail: String? = nil) -> some View {
        VStack(spacing: Theme.Spacing.l) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.Colors.accent)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.Colors.textPrimary)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }

    private var accessDeniedState: some View {
        messageState(
            icon: "lock.fill",
            title: "Photo access needed",
            detail: "TidyGallery needs access to your photo library to find duplicates. You can enable it in Settings › Privacy › Photos.",
            actionTitle: "Open Settings"
        ) {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }

    private func messageState(
        icon: String,
        title: String,
        detail: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: Theme.Spacing.l) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(Theme.Colors.accent)
                .symbolRenderingMode(.hierarchical)
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(Theme.Colors.textPrimary)
            Text(detail)
                .font(.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xl)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(QuietButtonStyle(tint: Theme.Colors.accent))
            }
        }
    }
}
