import CoreGraphics

struct LockedCardGeometry {
    struct SizeLimits: Equatable {
        let minWidth: CGFloat
        let maxWidth: CGFloat
        let minHeight: CGFloat
        let maxHeight: CGFloat
    }

    static func clampedCenter(
        _ center: CGPoint,
        cardSize: CGSize,
        sceneSize: CGSize,
        margin: CGFloat = 8
    ) -> CGPoint {
        clampedCenter(
            center,
            cardSize: cardSize,
            sceneRect: CGRect(origin: .zero, size: sceneSize),
            margin: margin
        )
    }

    static func clampedCenter(
        _ center: CGPoint,
        cardSize: CGSize,
        sceneRect: CGRect,
        margin: CGFloat = 8
    ) -> CGPoint {
        let halfWidth = cardSize.width / 2
        let halfHeight = cardSize.height / 2
        let minX = sceneRect.minX + halfWidth + margin
        let maxX = max(minX, sceneRect.maxX - halfWidth - margin)
        let minY = sceneRect.minY + halfHeight + margin
        let maxY = max(minY, sceneRect.maxY - halfHeight - margin)
        return CGPoint(
            x: min(maxX, max(minX, center.x)),
            y: min(maxY, max(minY, center.y))
        )
    }

    static func resizedFrame(
        from startFrame: CGRect,
        translation: CGSize,
        limits: SizeLimits,
        sceneSize: CGSize,
        margin: CGFloat = 8
    ) -> CGRect {
        resizedFrame(
            from: startFrame,
            translation: translation,
            limits: limits,
            sceneRect: CGRect(origin: .zero, size: sceneSize),
            margin: margin
        )
    }

    static func resizedFrame(
        from startFrame: CGRect,
        translation: CGSize,
        limits: SizeLimits,
        sceneRect: CGRect,
        margin: CGFloat = 8
    ) -> CGRect {
        let maxWidth = max(limits.minWidth, min(limits.maxWidth, sceneRect.width - margin * 2))
        let maxHeight = max(limits.minHeight, min(limits.maxHeight, sceneRect.height - margin * 2))
        let width = clamp(startFrame.width + translation.width, lower: limits.minWidth, upper: maxWidth)
        let height = clamp(startFrame.height + translation.height, lower: limits.minHeight, upper: maxHeight)
        let proposedCenter = CGPoint(
            x: startFrame.minX + width / 2,
            y: startFrame.minY + height / 2
        )
        let clampedCenter = clampedCenter(
            proposedCenter,
            cardSize: CGSize(width: width, height: height),
            sceneRect: sceneRect,
            margin: margin
        )
        return CGRect(
            x: clampedCenter.x - width / 2,
            y: clampedCenter.y - height / 2,
            width: width,
            height: height
        )
    }

    static func movedFrame(
        startCenter: CGPoint,
        translation: CGSize,
        size: CGSize,
        sceneSize: CGSize,
        margin: CGFloat = 8
    ) -> CGRect {
        movedFrame(
            startCenter: startCenter,
            translation: translation,
            size: size,
            sceneRect: CGRect(origin: .zero, size: sceneSize),
            margin: margin
        )
    }

    static func movedFrame(
        startCenter: CGPoint,
        translation: CGSize,
        size: CGSize,
        sceneRect: CGRect,
        margin: CGFloat = 8
    ) -> CGRect {
        let proposedCenter = CGPoint(
            x: startCenter.x + translation.width,
            y: startCenter.y + translation.height
        )
        let center = clampedCenter(
            proposedCenter,
            cardSize: size,
            sceneRect: sceneRect,
            margin: margin
        )
        return CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(upper, max(lower, value))
    }
}
