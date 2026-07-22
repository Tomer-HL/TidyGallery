//
//  PhotoPreviewView.swift
//  TidyGallery
//
//  Full-screen review of a single stack: swipe between its photos, pinch/double-
//  tap to zoom, and decide keep-vs-delete or promote the best shot right here —
//  so the user always sees a photo large before acting on it.
//
//  It reads and mutates the live `ReviewModel`, so any change (toggle, best-shot)
//  is instantly reflected back in the filmstrip behind it.
//

import SwiftUI

struct PhotoPreviewView: View {
    let model: ReviewModel
    let stackID: UUID

    @State private var currentID: PhotoAsset.ID
    @Environment(\.dismiss) private var dismiss

    init(model: ReviewModel, stackID: UUID, startAssetID: PhotoAsset.ID) {
        self.model = model
        self.stackID = stackID
        _currentID = State(initialValue: startAssetID)
    }

    private var stack: ReviewModel.Stack? {
        model.stacks.first { $0.id == stackID }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let stack {
                TabView(selection: $currentID) {
                    ForEach(stack.rankedIDs, id: \.self) { id in
                        ZoomableImageView(assetID: id)
                            .tag(id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()

                topBar(stack)
                bottomControls(stack)
            }
        }
        .statusBarHidden()
        .preferredColorScheme(.dark)
    }

    // MARK: Top bar

    private func topBar(_ stack: ReviewModel.Stack) -> some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.35), in: Circle())
                }
                Spacer()
                if let position = position(in: stack) {
                    Text(position)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Spacing.m)
                        .padding(.vertical, Theme.Spacing.s)
                        .background(.black.opacity(0.35), in: Capsule())
                }
                Spacer()
                Color.clear.frame(width: 44, height: 44)   // balance the layout
            }
            .padding(.horizontal, Theme.Spacing.l)
            Spacer()
        }
        .padding(.top, Theme.Spacing.s)
    }

    // MARK: Bottom controls

    private func bottomControls(_ stack: ReviewModel.Stack) -> some View {
        let isBest = currentID == stack.bestShotID
        let isChecked = stack.checkedForDeletion.contains(currentID)

        return VStack {
            Spacer()
            HStack(spacing: Theme.Spacing.l) {
                // Promote to best shot.
                previewButton(
                    title: isBest ? "Best shot" : "Make best",
                    systemImage: isBest ? "star.fill" : "star",
                    tint: isBest ? Theme.Colors.best : .white,
                    filled: isBest
                ) {
                    model.setBestShot(currentID, inStack: stackID)
                }
                .disabled(isBest)

                // Keep vs delete (best shot can't be deleted).
                if !isBest {
                    previewButton(
                        title: isChecked ? "Marked for deletion" : "Keep",
                        systemImage: isChecked ? "trash.fill" : "trash",
                        tint: isChecked ? .white : .white,
                        filled: isChecked,
                        fillColor: Theme.Colors.destructive
                    ) {
                        model.toggleDeletion(of: currentID, inStack: stackID)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.xl)
        }
    }

    private func previewButton(
        title: String,
        systemImage: String,
        tint: Color,
        filled: Bool,
        fillColor: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(filled ? .white : tint)
                .padding(.horizontal, Theme.Spacing.l)
                .frame(minHeight: 48)
                .frame(maxWidth: .infinity)
                .background(
                    filled ? AnyShapeStyle(fillColor) : AnyShapeStyle(.ultraThinMaterial),
                    in: Capsule()
                )
        }
    }

    private func position(in stack: ReviewModel.Stack) -> String? {
        guard let idx = stack.rankedIDs.firstIndex(of: currentID) else { return nil }
        return String(localized: "\(idx + 1) of \(stack.rankedIDs.count)")
    }
}

// MARK: - Zoomable image

/// A single pinch/double-tap zoomable, pannable image. When not zoomed it lets
/// the parent `TabView` handle horizontal swipes; panning only activates once
/// the user has zoomed in (so paging and panning don't fight).
struct ZoomableImageView: View {
    let assetID: PhotoAsset.ID

    @Environment(\.photoLibrary) private var library
    @Environment(\.displayScale) private var displayScale

    @State private var image: UIImage?
    @State private var steadyZoom: CGFloat = 1
    @GestureState private var pinchZoom: CGFloat = 1
    @State private var steadyOffset: CGSize = .zero
    @GestureState private var dragOffset: CGSize = .zero

    private var zoom: CGFloat { steadyZoom * pinchZoom }

    var body: some View {
        GeometryReader { geo in
            content
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(zoom)
                .offset(
                    x: steadyOffset.width + dragOffset.width,
                    y: steadyOffset.height + dragOffset.height
                )
                .gesture(magnifyGesture)
                .modify(when: steadyZoom > 1) { $0.simultaneousGesture(panGesture) }
                .onTapGesture(count: 2) { withAnimation(.spring(response: 0.3)) { toggleZoom() } }
                .task(id: assetID) { await load(displaySize: geo.size) }
                .contentShape(Rectangle())
        }
    }

    @ViewBuilder private var content: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            ProgressView().tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .updating($pinchZoom) { value, state, _ in state = value.magnification }
            .onEnded { value in
                steadyZoom = min(max(steadyZoom * value.magnification, 1), 4)
                if steadyZoom == 1 { steadyOffset = .zero }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .updating($dragOffset) { value, state, _ in state = value.translation }
            .onEnded { value in
                steadyOffset.width += value.translation.width
                steadyOffset.height += value.translation.height
            }
    }

    private func toggleZoom() {
        if steadyZoom > 1 {
            steadyZoom = 1
            steadyOffset = .zero
        } else {
            steadyZoom = 2.5
        }
    }

    private func load(displaySize: CGSize) async {
        guard image == nil, let library else { return }
        // Cap the long edge so very large photos don't blow up memory.
        let maxEdge: CGFloat = 2048
        let w = min(displaySize.width * displayScale, maxEdge)
        let h = min(displaySize.height * displayScale, maxEdge)
        image = await library.previewImage(for: assetID, targetSize: CGSize(width: w, height: h))
    }
}

// MARK: - Conditional modifier helper

private extension View {
    /// Applies a transform only when `condition` is true, keeping call sites tidy.
    @ViewBuilder
    func modify<Content: View>(when condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}
