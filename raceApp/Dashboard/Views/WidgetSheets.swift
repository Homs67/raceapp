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

    var body: some View {
        List {
            ForEach(WidgetCategory.allCases) { category in
                let kinds = WidgetKind.library.filter { $0.category == category }
                if !kinds.isEmpty {
                    Section(category.title) {
                        ForEach(kinds, id: \.self) { kind in
                            row(kind)
                        }
                    }
                }
            }
        }
    }

    private func row(_ kind: WidgetKind) -> some View {
        let replacing: UUID? = { if case .replace(let id) = mode { return id } else { return nil } }()
        let fitting = edit.fittingSizes(for: kind, replacing: replacing)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: kind.libraryIcon).foregroundStyle(Color.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).font(.system(size: 15, weight: .semibold))
                    Text(kind.libraryDescription).font(.system(size: 12)).foregroundStyle(Color.muted)
                }
            }
            HStack(spacing: 8) {
                ForEach(kind.supportedSizes) { size in
                    let fits = fitting.contains(size)
                    Button(size.label) {
                        let ok: Bool
                        switch mode {
                        case .insert(let index): ok = edit.add(kind: kind, size: size, at: index)
                        case .replace(let id):
                            ok = edit.replace(id: id, with: kind) && edit.resize(id: id, to: size)
                        }
                        if ok { onDone() }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(fits ? Color.accent.opacity(0.18) : Color.cardGray, in: Capsule())
                    .foregroundStyle(fits ? Color.accent : Color.mutedWeak)
                    .disabled(!fits)
                }
                if fitting.isEmpty {
                    Text("No room — remove or shrink a widget").font(.system(size: 11)).foregroundStyle(Color.muted)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}
