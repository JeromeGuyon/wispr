//
//  LiveFeatureComponents.swift
//  wispr
//
//  Small, polished building blocks for the live-meeting features UI: a JuL
//  connection status badge and a chip-style editor for the monitored names.
//  Kept separate so the Settings section and the bingo grid share one look.
//

import SwiftUI

/// A pill showing whether the local JuL server is reachable, with a colored dot.
/// Green = ready, orange = not running. Purely presentational.
struct JulStatusBadge: View {
    let isReachable: Bool
    var modelName: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isReachable ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle().stroke(.white.opacity(0.4), lineWidth: 0.5)
                )
            Text(label)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill((isReachable ? Color.green : Color.orange).opacity(0.12))
        )
        .overlay(
            Capsule().stroke((isReachable ? Color.green : Color.orange).opacity(0.3), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isReachable ? "JuL connected" : "JuL not running")
    }

    private var label: String {
        if isReachable {
            return modelName.map { "JuL · \($0)" } ?? "JuL connected"
        }
        return "JuL offline"
    }
}

/// A chip-style editor for a list of names: type a name, press Return to add it;
/// click the × on a chip to remove it. Wraps to multiple rows.
struct NameChipsEditor: View {
    @Binding var names: [String]
    var placeholder: String = "Add a name, then press Return"
    var icon: String = "person.wave.2.fill"
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .accessibilityLabel(placeholder)
                Button(action: add) {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled(trimmed.isEmpty)
                .accessibilityLabel("Add name")
            }

            if names.isEmpty {
                Text("Nothing yet — add an entry above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(names, id: \.self) { name in
                        NameChip(name: name) { remove(name) }
                    }
                }
            }
        }
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func add() {
        let n = trimmed
        guard !n.isEmpty, !names.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) else {
            draft = ""
            return
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            names.append(n)
        }
        draft = ""
    }

    private func remove(_ name: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            names.removeAll { $0 == name }
        }
    }
}

/// One removable name chip.
private struct NameChip: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.caption.weight(.medium))
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.3), lineWidth: 0.5))
        .foregroundStyle(Color.accentColor)
        .transition(.scale.combined(with: .opacity))
    }
}

/// A minimal flow layout that wraps its children onto multiple lines — used for
/// the name chips. Standard on macOS 13+ (Layout protocol).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}


// MARK: - Bingo terms editor

/// A focused editor for the bingo grid terms: a live preview of the square grid,
/// an add field, per-term removal on hover/click, a term count with a hint toward
/// perfect squares, and a reset. Clearer than a flat chip list for ~16 items.
struct BingoTermsEditor: View {
    @Binding var terms: [String]
    @State private var draft = ""

    /// The grid is a strict 4×4 (16 cells), matching the live board.
    private var side: Int { BingoConfig.gridSide }        // 4
    private var capacity: Int { BingoConfig.cellCount }   // 16
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: side)
    }
    /// How many real terms are shown, capped at the 16 grid cells.
    private var shown: Int { min(terms.count, capacity) }
    private var freeCells: Int { max(0, capacity - terms.count) }
    private var ignored: Int { max(0, terms.count - capacity) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Grid terms")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(countHint)
                    .font(.caption2)
                    .foregroundStyle(freeCells == 0 && ignored == 0 ? Color.green : Color.secondary)
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        terms = BingoConfig.randomTerms()
                    }
                } label: {
                    Label("Random", systemImage: "die.face.5")
                }
                .font(.caption)
                .accessibilityHint("Fills the grid with 16 random buzzwords.")
                Button("Reset") { terms = BingoConfig.defaultTerms }
                    .font(.caption)
                    .accessibilityHint("Restores the default bingo grid terms.")
            }

            // Add field.
            HStack(spacing: 6) {
                Image(systemName: "text.badge.plus").foregroundStyle(.secondary).font(.caption)
                TextField("Add a buzzword, then press Return", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button(action: add) { Image(systemName: "plus.circle.fill") }
                    .buttonStyle(.borderless)
                    .disabled(trimmed.isEmpty)
            }

            // Preview grid — a strict 4×4, exactly like the live board: the first
            // 16 terms, then free ★ cells to fill the square.
            if terms.isEmpty {
                Text("No terms — add a few, hit Random, or reset to the defaults.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(Array(terms.prefix(capacity)), id: \.self) { term in
                        BingoTermCell(term: term, isFree: false) { remove(term) }
                    }
                    ForEach(0..<freeCells, id: \.self) { _ in
                        BingoTermCell(term: "★", isFree: true, onRemove: {})
                    }
                }
            }

            Text(footerHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A 4×4-aware summary: full, partially filled (free cells), or overflowing.
    private var countHint: String {
        if ignored > 0 { return "\(terms.count) terms · \(ignored) ignored (max 16)" }
        if freeCells > 0 { return "\(shown)/16 · \(freeCells) free" }
        return "16/16 ✓"
    }

    private var footerHint: String {
        if ignored > 0 {
            return "The grid is a fixed 4×4. Only the first 16 terms are used; \(ignored) extra ignored. Changes apply live."
        }
        if freeCells > 0 {
            return "The grid is a fixed 4×4. \(freeCells) free ★ cell\(freeCells == 1 ? "" : "s") fill the rest. Add \(freeCells) more for a full board. Changes apply live."
        }
        return "The grid is a fixed 4×4, full. Changes apply live to the bingo window."
    }

    private func add() {
        let t = trimmed
        guard !t.isEmpty, !terms.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else {
            draft = ""; return
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { terms.append(t) }
        draft = ""
    }

    private func remove(_ term: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { terms.removeAll { $0 == term } }
    }
}

private struct BingoTermCell: View {
    let term: String
    var isFree: Bool = false
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(term)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 36)
                .padding(4)
                .foregroundStyle(isFree ? Color.secondary : Color.primary)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(isFree ? 0.06 : 0.12)))
            if hovering && !isFree {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.white, .red)
                }
                .buttonStyle(.borderless)
                .padding(2)
                .accessibilityLabel("Remove \(term)")
            }
        }
        .onHover { if !isFree { hovering = $0 } }
        .transition(.scale.combined(with: .opacity))
    }
}
