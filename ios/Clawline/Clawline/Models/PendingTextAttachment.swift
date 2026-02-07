//
//  PendingTextAttachment.swift
//  Clawline
//
//  Created by Codex on 1/15/26.
//

import UIKit

final class PendingTextAttachment: NSTextAttachment {
    private enum Metrics {
        static let maxHeight: CGFloat = 44
        static let maxWidth: CGFloat = 72
        static let verticalOffset: CGFloat = -6
    }

    let pendingId: UUID
    private let accessibilityText: String

    init(id: UUID, thumbnail: UIImage, accessibilityLabel: String) {
        self.pendingId = id
        self.accessibilityText = accessibilityLabel
        super.init(data: nil, ofType: nil)
        image = thumbnail
        bounds = PendingTextAttachment.makeBounds(for: thumbnail)
        isAccessibilityElement = true
        self.accessibilityLabel = accessibilityText
    }

    required init?(coder: NSCoder) {
        guard let id = coder.decodeObject(forKey: "pendingId") as? UUID else {
            return nil
        }
        self.pendingId = id
        self.accessibilityText = coder.decodeObject(forKey: "accessibilityText") as? String ?? "Attachment"
        super.init(coder: coder)
        if let image = image {
            bounds = PendingTextAttachment.makeBounds(for: image)
        }
        isAccessibilityElement = true
        self.accessibilityLabel = accessibilityText
    }

    override func encode(with coder: NSCoder) {
        coder.encode(pendingId, forKey: "pendingId")
        coder.encode(accessibilityText, forKey: "accessibilityText")
        super.encode(with: coder)
    }

    private static func makeBounds(for image: UIImage) -> CGRect {
        // Preserve aspect ratio: fit inside a max height + max width box.
        // This avoids squashing wide/tall thumbnails in the compose bar (#55).
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(x: 0, y: Metrics.verticalOffset, width: Metrics.maxHeight, height: Metrics.maxHeight)
        }

        let heightScale = Metrics.maxHeight / imageSize.height
        let widthScale = Metrics.maxWidth / imageSize.width
        let scale = min(heightScale, widthScale, 1)
        let size = CGSize(width: floor(imageSize.width * scale), height: floor(imageSize.height * scale))
        return CGRect(x: 0, y: Metrics.verticalOffset, width: max(1, size.width), height: max(1, size.height))
    }
}
