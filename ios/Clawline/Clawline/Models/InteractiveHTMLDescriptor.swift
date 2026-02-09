//
//  InteractiveHTMLDescriptor.swift
//  Clawline
//
//  Created by Codex on 2/9/26.
//

import Foundation
import CoreGraphics

struct InteractiveHTMLDescriptor: Codable, Equatable {
    static let mimeType = "application/vnd.clawline.interactive-html+json"

    struct Metadata: Codable, Equatable {
        var title: String?
        var height: Height?
        var maxHeight: CGFloat?
        var backgroundColor: String?

        enum Height: Codable, Equatable {
            case auto
            case fixed(CGFloat)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let string = try? container.decode(String.self) {
                    if string.lowercased() == "auto" {
                        self = .auto
                        return
                    }
                }
                let value = try container.decode(Double.self)
                self = .fixed(CGFloat(value))
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .auto:
                    try container.encode("auto")
                case .fixed(let value):
                    try container.encode(Double(value))
                }
            }
        }
    }

    let version: Int
    let html: String
    let metadata: Metadata?
}
