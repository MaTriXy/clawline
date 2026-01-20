//
//  FlowLayout.swift
//  Clawline
//
//  Created by Codex on 1/11/26.
//

import SwiftUI

struct FlowLayout: Layout {
    var itemSpacing: CGFloat
    var rowSpacing: CGFloat
    var maxLineWidth: CGFloat
    var isCompact: Bool
    var heightWrapThreshold: CGFloat = 1.6
    var heightWrapDelta: CGFloat = .infinity

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let containerWidth = proposal.width ?? maxLineWidth
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let sizeClass = readOnMainActor { subview[MessageSizeClassKey.self] }
            let maxWidth = maxItemWidth(for: sizeClass, containerWidth: containerWidth)
            let size = readOnMainActor {
                subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            }

            let heightMismatch = rowHeight > 0 && (
                heightRatio(a: rowHeight, b: size.height) > heightWrapThreshold ||
                abs(rowHeight - size.height) > heightWrapDelta
            )
            if rowWidth > 0 && (rowWidth + size.width > containerWidth || heightMismatch) {
                totalHeight += rowHeight + rowSpacing
                rowWidth = 0
                rowHeight = 0
            }

            rowWidth += size.width + (rowWidth == 0 ? 0 : itemSpacing)
            rowHeight = max(rowHeight, size.height)
        }

        totalHeight += rowHeight
        return CGSize(width: containerWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let sizeClass = readOnMainActor { subview[MessageSizeClassKey.self] }
            let maxWidth = maxItemWidth(for: sizeClass, containerWidth: bounds.width)
            let size = readOnMainActor {
                subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            }

            let heightMismatch = rowHeight > 0 && (
                heightRatio(a: rowHeight, b: size.height) > heightWrapThreshold ||
                abs(rowHeight - size.height) > heightWrapDelta
            )
            if x > bounds.minX && (x + size.width > bounds.maxX || heightMismatch) {
                x = bounds.minX
                y += rowHeight + rowSpacing
                rowHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )

            x += size.width + itemSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    func maxItemWidth(for sizeClass: MessageSizeClass, containerWidth: CGFloat) -> CGFloat {
        switch sizeClass {
        case .short:
            return min(containerWidth, maxLineWidth)
        case .medium:
            if isCompact {
                return containerWidth
            }
            return min(containerWidth, max(containerWidth * 0.45, 200))
        case .long:
            return min(containerWidth, maxLineWidth)
        }
    }

    private func readOnMainActor<T>(_ work: () -> T) -> T {
        MainActor.assumeIsolated(work)
    }

    private func heightRatio(a: CGFloat, b: CGFloat) -> CGFloat {
        let minValue = max(1, min(a, b))
        let maxValue = max(a, b)
        return maxValue / minValue
    }

}
