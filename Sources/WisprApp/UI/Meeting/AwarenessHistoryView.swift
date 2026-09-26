//
//  AwarenessHistoryView.swift
//  wispr
//
//  Lists the moments the user was addressed during the meeting, so they can
//  catch up on what they missed. Binds to the MeetingClassifier's solicitations.
//

import SwiftUI

struct AwarenessHistoryView: View {
    let classifier: MeetingClassifier

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("You were mentioned", systemImage: "bell.badge.fill")
                    .font(.headline)
                Spacer()
                JulStatusBadge(isReachable: classifier.isServerReachable, modelName: classifier.serverModel)
            }

            if classifier.solicitations.isEmpty {
                Text("Nothing yet. When someone addresses you a question or a task, it shows up here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(classifier.solicitations) { item in
                            SolicitationRow(item: item, time: Self.timeFormatter.string(from: item.date))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct SolicitationRow: View {
    let item: MeetingClassifier.Solicitation
    let time: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if item.urgent {
                    Label("now", systemImage: "bolt.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
                Text(item.speaker)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // Headline: generated summary (B) if present, else the raw sentence.
            if let summary = item.summary, !summary.isEmpty {
                Text(summary)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text("“\(item.sentence)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("“\(item.sentence)”")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                // In "last messages" mode, show the preceding lines for context.
                if item.recentMessages.count > 1 {
                    Text(item.recentMessages.dropLast().suffix(3).joined(separator: "\n"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !item.tags.isEmpty || item.needsAction || item.hasDeadline || item.tone != nil {
                HStack(spacing: 4) {
                    if item.needsAction {
                        highlightChip("🙋 action", .blue)
                    }
                    if item.hasDeadline {
                        highlightChip("📅 deadline", .purple)
                    }
                    if let tone = item.tone, let label = Self.toneLabel(tone) {
                        highlightChip(label, tone >= 3 ? .red : .secondary)
                    }
                    ForEach(item.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            item.urgent ? Color.orange.opacity(0.10) : Color.secondary.opacity(0.08)))
    }

    @ViewBuilder private func highlightChip(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
            .foregroundStyle(tint)
    }

    /// Short label for a 0…4 tone level, nil for the neutral middle.
    static func toneLabel(_ tone: Int) -> String? {
        switch tone {
        case 0: return "🙂 calm"
        case 1: return nil
        case 2: return "😐 pressing"
        case 3: return "😟 tense"
        case 4: return "😠 angry"
        default: return nil
        }
    }
}
