//
//  AchievementViews.swift
//  raceApp
//
//  The ACHIEVEMENTS row at the top of the Tracks tab, and the full-screen
//  emblem (opened from the row, or popped up when a drive earns one).
//

import SwiftUI

extension AppModel {
    func emblemContent(for entry: AchievementEntry) -> EmblemContent {
        EmblemContent(entry: entry,
                      centerline: tracks.track(id: entry.outlineTrackId ?? entry.trackId)?.centerline ?? [],
                      progress: achievements.progress[entry.trackId],
                      driverName: ProfileKeys.engravedName)
    }
}

/// Horizontal row of every catalogued emblem; locked ones are grey and
/// don't open.
struct AchievementsRow: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ProfileKeys.firstName) private var firstName = ""
    @State private var open: AchievementEntry?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(AchievementCatalog.all) { entry in
                    let content = model.emblemContent(for: entry)
                    Button {
                        if !content.locked { open = entry }
                    } label: {
                        VStack(spacing: 6) {
                            EmblemThumbnail(content: content)
                                .frame(width: 104, height: 104)
                            Text(entry.shortName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(content.locked ? Color.muted : Color.textPrimary)
                                .lineLimit(1)
                            Text(content.progress.map { $0.earnedAt.formatted(.dateTime.month(.abbreviated).day().year()) } ?? "Locked")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.muted)
                        }
                        .frame(width: 112)
                    }
                    .buttonStyle(.plain)
                    .disabled(content.locked)
                    .accessibilityLabel("\(entry.shortName), \(content.locked ? "locked" : "earned")")
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
        .fullScreenCover(item: $open) { entry in
            AchievementDetailView(entry: entry, isNew: false)
                .environment(model)
        }
    }
}

struct AchievementDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: AchievementEntry
    /// Shown as the unlock pop-up after a drive.
    let isNew: Bool

    var body: some View {
        let content = model.emblemContent(for: entry)
        let fullName = entry.fullName ?? model.tracks.track(id: entry.trackId)?.name ?? entry.shortName
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.textPrimary)
                .accessibilityLabel("Close")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            EmblemView(content: content, introTurns: isNew ? 2 : 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 6) {
                if isNew {
                    Text("NEW ACHIEVEMENT")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Color.accent)
                }
                Text(entry.shortName)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color.textPrimary)
                if let p = content.progress {
                    Text("Earned by completing a lap at \(fullName). \(p.earnedAt.formatted(date: .abbreviated, time: .omitted)).")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.mutedStrong)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            if isNew { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
    }
}
