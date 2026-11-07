import CoreGraphics

struct LockedOverlayLayoutCoordinator {
    enum CardInteraction: Equatable {
        case idle
        case moving
        case resizing

        var isActive: Bool {
            self != .idle
        }
    }

    struct LayerPlan: Equatable {
        let liveCardFrame: CGRect
        let annotationAvoidanceFrames: [CGRect]
        let interaction: CardInteraction
        let contactPadding: CGFloat
        let contactOpacity: Double

        var cardZIndex: Double {
            interaction.isActive ? 100 : 20
        }

        var secondaryZIndex: Double {
            5
        }

        func secondaryOpacity(for frame: CGRect) -> Double {
            liveCardFrame.insetBy(dx: -contactPadding, dy: -contactPadding).intersects(frame)
                ? contactOpacity
                : 1
        }
    }

    var contactPadding: CGFloat = 12
    var contactOpacity: Double = 0.32

    func plan(
        liveCardFrame: CGRect,
        settledCardFrame: CGRect?,
        reservedFrames: [CGRect],
        interaction: CardInteraction
    ) -> LayerPlan {
        let cardAvoidanceFrame = interaction.isActive
            ? (settledCardFrame ?? liveCardFrame)
            : liveCardFrame
        return LayerPlan(
            liveCardFrame: liveCardFrame,
            annotationAvoidanceFrames: [cardAvoidanceFrame] + reservedFrames,
            interaction: interaction,
            contactPadding: contactPadding,
            contactOpacity: contactOpacity
        )
    }
}
