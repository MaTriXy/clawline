//
//  Task+Sleep.swift
//  Clawline
//
//  Created by Codex on 1/17/26.
//

import Foundation

extension Task where Success == Never, Failure == Never {
    static func sleep(forDuration duration: Duration) async throws {
        let components = duration.components
        guard components.seconds >= 0 else { return }
        var nanoseconds = UInt64(components.seconds) * 1_000_000_000
        if components.attoseconds > 0 {
            nanoseconds += UInt64(components.attoseconds) / 1_000_000_000
        }
        if nanoseconds == 0 {
            return
        }
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
