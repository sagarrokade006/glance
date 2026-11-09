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

    static func panelSize(closedHeight: CGFloat) -> CGSize {
        CGSize(width: 320, height: 92 + closedHeight)
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: notice.symbol)
                .font(.system(size: 26))
                .foregroundStyle(.orange)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(notice.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26)
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
                Circle().stroke(.white.opacity(0.18), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: CGFloat(prompt.progress))
                    .stroke(.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: prompt.isComplete ? "eye.fill" : prompt.direction.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)
            .animation(.easeOut(duration: 0.15), value: prompt.progress)

            Text(prompt.isComplete ? "Now look at the screen" : prompt.direction.prompt)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
