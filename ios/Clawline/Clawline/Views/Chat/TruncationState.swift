//
//  TruncationState.swift
//  Clawline
//
//  Created by Codex on 1/25/26.
//

import CoreGraphics

struct TruncationState {
    let contentHeight: CGFloat?
    let shouldTruncate: Bool
    let showsControl: Bool

    static let none = TruncationState(contentHeight: nil, shouldTruncate: false, showsControl: false)
}
