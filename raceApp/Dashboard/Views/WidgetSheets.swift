//
//  WidgetSheets.swift
//  raceApp
//
//  Edit-mode sheets: per-widget options (size / replace / remove) and the
//  widget library. Sizes that would overflow either orientation are shown
//  disabled with the reason, never silently allowed.
//

import SwiftUI

struct WidgetOptionsSheet: View {
    let edit: DashboardEditController
    let placementId: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var showLibrary = false

    private var placement: WidgetPlacement? {
        edit.working.placements.first { $0.id == placementId }
    }

    var body: some View {
        NavigationStack {
            List {
                if let placement {
                    Section("Size") {
                        let fitting = edit.fittingSizes(for: placement.kind, replacing: placement.id)
                        ForEach(placement.kind.supportedSizes) { size in
                            let fits = fitting.contains(size)
                            Button {
                                if edit.resize(id: placement.id, to: size) { dismiss() }
                            } label: {
                                HStack {
                                    Text(size.label)
                                    Spacer()
                                    if !fits {
                                        Text("Doesn't fit").font(.footnote).foregroundStyle(Color.muted)
                                    } else if size == placement.size {
                                        Image(systemName: "checkmark").foregroundStyle(Color.accent)
                                    }
                                }
                            }
                            .disabled(!fits)
                            .foregroundStyle(fits ? Color.textPrimary : Color.mutedWeak)
                        }
                    }
                    Section {
                        Button("Replace…") { showLibrary = true }
                        Button("Remove", role: .destructive) {
                            edit.remove(id: placement.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(placement?.kind.title ?? "Widget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(isPresented: $showLibrary) {
                WidgetLibraryList(edit: edit, mode: .replace(placementId)) { dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}

struct WidgetLibrarySheet: View {
    let edit: DashboardEditController
    let insertAt: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WidgetLibraryList(edit: edit, mode: .insert(insertAt)) { dismiss() }
                .navigationTitle("Add widget")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}

struct WidgetLibraryList: View {
    enum Mode { case insert(Int), replace(UUID) }

    let edit: DashboardEditController
    let mode: Mode
    let onDone: () -> Void

    @AppStorage("useMetricUnits") private var metric = false

    /// Preview cells are the real landscape cell size, scaled to the sheet.
    private static let cell = CGSize(width: 191, height: 177)
    private static let gap: CGFloat = 8
    private static let margin: CGFloat = 16

    var body: some View {
        let track = TrackDatabase.track(id: "big-willow") ?? TrackDatabase.all.first
        let live = LiveSnapshot.demo(track: track)
        let units = UnitsFormatter(metric: metric)
        GeometryReader { geo in
            let width = geo.size.width - 2 * Self.margin
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(WidgetSize.allCases) { size in
                        let kinds = WidgetKind.library.filter { $0.supportedSizes.contains(size) }
                        if !kinds.isEmpty {
                            section(size, kinds: kinds, width: width, live: live, units: units, track: track)
                        }
                    }
                }
                .padding(Self.margin)
            }
        }
    }

    private func section(_ size: WidgetSize, kinds: [WidgetKind], width: CGFloat,
                         live: LiveSnapshot, units: UnitsFormatter, track: Track?) -> some View {
        // Smalls sit two per row; medium and large take the full width.
        let columns = size == .small ? 2 : 1
        let cellW = Self.cell.width * CGFloat(size.span.cols)
        let cellH = Self.cell.height * CGFloat(size.span.rows)
        let previewW = (width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)
        let scale = previewW / cellW
        return VStack(alignment: .leading, spacing: 10) {
            Text(size.label.uppercased())
                .font(.sofia(14, .heavy)).kerning(1.5).foregroundStyle(Color.muted)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(previewW), spacing: Self.gap), count: columns),
                      alignment: .leading, spacing: Self.gap) {
                ForEach(kinds, id: \.self) { kind in
                    let fits = fitting(kind).contains(size)
                    Button {
                        if pick(kind, size) { onDone() }
                    } label: {
                        WidgetPreview(kind: kind, size: size, live: live, units: units, track: track,
                                      nominal: CGSize(width: cellW, height: cellH), scale: scale)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(!fits)
                    .opacity(fits ? 1 : 0.35)
                    .accessibilityLabel("\(kind.title), \(size.label)\(fits ? "" : ", doesn't fit")")
                }
            }
        }
    }

    private func fitting(_ kind: WidgetKind) -> [WidgetSize] {
        let replacing: UUID? = { if case .replace(let id) = mode { return id } else { return nil } }()
        return edit.fittingSizes(for: kind, replacing: replacing)
    }

    private func pick(_ kind: WidgetKind, _ size: WidgetSize) -> Bool {
        switch mode {
        case .insert(let index): return edit.add(kind: kind, size: size, at: index)
        case .replace(let id): return edit.replace(id: id, with: kind) && edit.resize(id: id, to: size)
        }
    }
}

/// One widget rendered exactly as it will appear on the dashboard, with demo
/// data, scaled to the gallery column.
private struct WidgetPreview: View {
    let kind: WidgetKind
    let size: WidgetSize
    let live: LiveSnapshot
    let units: UnitsFormatter
    let track: Track?
    let nominal: CGSize
    let scale: CGFloat

    var body: some View {
        let placement = WidgetPlacement(kind: kind, size: size)
        WidgetChrome(context: WidgetContext(
            placement: placement,
            contentSize: CGSize(width: nominal.width - 2 * WidgetMetrics.padding,
                                height: nominal.height - 2 * WidgetMetrics.padding),
            isLandscape: true, live: live, units: units, isEditing: false, track: track))
        .frame(width: nominal.width, height: nominal.height)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: WidgetMetrics.outerCornerRadius / scale))
        .overlay {
            RoundedRectangle(cornerRadius: WidgetMetrics.outerCornerRadius / scale)
                .stroke(Color.widgetBorder, lineWidth: WidgetMetrics.borderWidth / scale)
        }
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: nominal.width * scale, height: nominal.height * scale, alignment: .topLeading)
        .allowsHitTesting(false)
        .contentShape(Rectangle())
    }
}
