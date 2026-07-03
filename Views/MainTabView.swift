//
//  MainTabView.swift
//  TidyGallery
//
//  The post-scan home: two cleanup categories as bottom tabs — duplicate/burst
//  "Duplicates" and standalone "Screenshots". Each tab owns its own navigation
//  stack so titles and the delete bar behave independently.
//

import SwiftUI

struct MainTabView: View {
    let coordinator: LibraryScanCoordinator

    var body: some View {
        TabView {
            NavigationStack {
                ReviewScreen(stacks: coordinator.stacks)
            }
            .tabItem {
                Label("Duplicates", systemImage: "square.stack.3d.up.fill")
            }

            NavigationStack {
                ScreenshotsScreen(assets: coordinator.screenshots)
            }
            .tabItem {
                Label("Screenshots", systemImage: "camera.viewfinder")
            }
            .badge(coordinator.screenshots.count)
        }
        .tint(Theme.Colors.accent)
    }
}
