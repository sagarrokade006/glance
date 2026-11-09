//
//  NotchMessageView.swift
//  glance
//
//  A short message shown in the notch when face unlock can't run.
//

import SwiftUI

struct NotchNotice: Equatable {
    let symbol: String
    let title: String
    let detail: String

    var statusText: String { "\(title). \(detail)" }
}

struct NotchMessageView: View {
    let notice: NotchNotice

    /// Pass the camera housing's size in notch style, or `nil` for the pill.
    static func panelSize(closedSize: CGSize?) -> CGSize {
        guard let closedSize else { return CGSize(width: 300, height: 76) }
        return CGSize(width: closedSize.width + 120, height: closedSize.height + 70)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: notice.symbol)
                .font(.system(size: 20))
                .foregroundStyle(.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(notice.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HeadTurnPrompt: Equatable {
    let direction: HeadTurnDirection
    let progress: Float

    var isComplete: Bool { progress >= 1 }
}

struct NotchChallengeView: View {
    let prompt: HeadTurnPrompt

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: CGFloat(prompt.progress))
                    .stroke(.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: prompt.isComplete ? "eye.fill" : prompt.direction.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            .animation(.easeOut(duration: 0.15), value: prompt.progress)

            Text(prompt.isComplete ? "Now look at the screen" : prompt.direction.prompt)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
