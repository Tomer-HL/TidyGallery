//
//  StorageRingView.swift
//  TidyGallery
//
//  A donut chart of where reclaimable space lives (duplicates, videos, big
//  files, recordings) drawn against the rest of the library, with the total
//  reclaimable figure in the centre. Uses Swift Charts (iOS 17+ `SectorMark`).
//

import SwiftUI
import Charts

struct StorageRingView: View {
    let summary: StorageSummary
    /// Total library size; `nil` while the background measurement is running.
    let totalLibraryBytes: Int64?

    private struct Segment: Identifiable {
        let id = UUID()
        let name: String
        let bytes: Int64
        let color: Color
    }

    private var segments: [Segment] {
        var segs: [Segment] = []
        func add(_ name: String, _ item: StorageSummary.LineItem, _ color: Color) {
            if item.bytes > 0 { segs.append(Segment(name: name, bytes: item.bytes, color: color)) }
        }
        add("Duplicates", summary.duplicates, Theme.Colors.accent)
        add("Large videos", summary.largeVideos, Theme.Colors.best)
        add("Big files", summary.bigFiles, Theme.Colors.destructive)
        add("Screen recordings", summary.screenRecordings, .teal)

        if let total = totalLibraryBytes {
            let rest = max(0, total - summary.reclaimableBytes)
            if rest > 0 {
                segs.append(Segment(name: "Rest of library", bytes: rest, color: Theme.Colors.surfaceMuted))
            }
        }
        return segs
    }

    var body: some View {
        ZStack {
            if segments.isEmpty {
                Circle()
                    .stroke(Theme.Colors.surfaceMuted, lineWidth: 22)
                    .frame(height: 168)
                    .padding(6)
            } else {
                Chart(segments) { seg in
                    SectorMark(
                        angle: .value("Bytes", Double(seg.bytes)),
                        innerRadius: .ratio(0.66),
                        angularInset: 1.5
                    )
                    .cornerRadius(3)
                    .foregroundStyle(seg.color)
                }
                .chartLegend(.hidden)
                .frame(height: 168)
            }

            VStack(spacing: 2) {
                Text(summary.reclaimableBytes > 0
                     ? summary.reclaimableBytes.formatted(.byteCount(style: .file))
                     : "0 KB")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text("reclaimable")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }
}
