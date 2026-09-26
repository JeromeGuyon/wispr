//
//  BingoGridView.swift
//  wispr
//
//  The live "bullshit bingo" grid shown from the menu bar. Binds to a
//  MeetingClassifier and lights squares up as JuL hears their jargon during a
//  meeting, detects a completed line, and celebrates a BINGO.
//

import SwiftUI

struct BingoGridView: View {
    let classifier: MeetingClassifier

    private var side: Int { max(1, classifier.gridSide) }
    private var markedCount: Int { classifier.bingoSquares.filter { $0.isMarked && !$0.isFree }.count }
    private var total: Int { classifier.bingoSquares.filter { !$0.isFree }.count }
    private var winning: Set<Int> { Set(classifier.winningLine) }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: side)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if classifier.bingoSquares.isEmpty {
                emptyState
            } else {
                grid
                progressBar
                if !classifier.bingoGames.isEmpty {
                    gamesLog
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: classifier.hasBingo)
    }

    private var gamesLog: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider()
            Text("Previous games")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(classifier.bingoGames.prefix(3)) { game in
                HStack(spacing: 6) {
                    Image(systemName: game.completed ? "rosette" : "xmark.circle")
                        .font(.caption2)
                        .foregroundStyle(game.completed ? Color.orange : Color.secondary)
                    Text(game.completed ? "BINGO" : "no line")
                        .font(.caption2)
                    Spacer()
                    Text("\(game.marked)/\(game.total)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Label("Bullshit Bingo", systemImage: "square.grid.3x3.fill")
                .font(.headline)
            Spacer()
            if !classifier.bingoSquares.isEmpty {
                Button {
                    classifier.resetBingo()
                } label: {
                    Label("New game", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Clears the grid and starts a new game.")
            }
            JulStatusBadge(isReachable: classifier.isServerReachable, modelName: classifier.serverModel)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enable bingo in Settings, then start a meeting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var grid: some View {
        ZStack {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(classifier.bingoSquares.enumerated()), id: \.element.id) { index, square in
                    BingoSquareCell(square: square, isWinning: winning.contains(index))
                }
            }

            if classifier.hasBingo {
                celebration
            }
        }
    }

    private var celebration: some View {
        Text("BINGO!")
            .font(.system(size: 34, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 22).padding(.vertical, 10)
            .background(
                Capsule().fill(
                    LinearGradient(colors: [.pink, .orange, .yellow],
                                   startPoint: .leading, endPoint: .trailing))
            )
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            .rotationEffect(.degrees(-8))
            .transition(.scale(scale: 0.3).combined(with: .opacity))
            .accessibilityLabel("Bingo! A line is complete.")
    }

    private var progressBar: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(LinearGradient(colors: [.accentColor, .purple],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: total > 0 ? geo.size.width * CGFloat(markedCount) / CGFloat(total) : 0)
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: markedCount)
                }
            }
            .frame(height: 6)

            Text("\(markedCount)/\(total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// One square: the jargon term, greyed out until heard, highlighted once marked,
/// and given a distinct treatment when it is part of the winning line.
private struct BingoSquareCell: View {
    let square: BingoSquare
    let isWinning: Bool

    var body: some View {
        Text(square.term)
            .font(.caption.weight(square.isMarked ? .semibold : .regular))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.65)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(4)
            .background(background)
            .foregroundStyle(square.isMarked ? Color.white : Color.primary)
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(isWinning ? Color.yellow : (square.isMarked ? Color.accentColor : Color.clear),
                            lineWidth: isWinning ? 2 : 1)
            )
            .scaleEffect(square.isMarked ? 1.0 : 0.98)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: square.isMarked)
            .accessibilityLabel(Text(square.term))
            .accessibilityValue(Text(square.isMarked ? "heard" : "not yet"))
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        if isWinning {
            shape.fill(LinearGradient(colors: [.orange, .pink],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
        } else if square.isFree {
            shape.fill(Color.secondary.opacity(0.25))   // free padding cell
        } else if square.isMarked {
            shape.fill(Color.accentColor.opacity(0.85))
        } else {
            shape.fill(Color.secondary.opacity(0.12))
        }
    }
}
