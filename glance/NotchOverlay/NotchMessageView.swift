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
