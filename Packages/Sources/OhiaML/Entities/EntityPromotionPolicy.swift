import Foundation
import OhiaCore

public enum EntityPromotionPolicy {
    public static func shouldPromote(kind: EntityKind, supportCount: Int, supportWeight: Double) -> Bool {
        guard supportCount > 0 else { return false }
        switch kind {
        case .correspondent, .attachment:
            return true
        }
    }
}
