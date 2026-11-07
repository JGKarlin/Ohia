import Foundation

/// Pure helpers for converting aperture-control input events into
/// scalar deltas applied to `ConstellationState.aperture`. The stateful
/// wrapper (per-frame accumulator, gesture entry points) lives in the
/// app target; this module contains only the math so it's unit-testable.
public enum ApertureAccumulator {

    /// Convert a MagnifyGesture transition from `fromScale` to `toScale`
    /// into a log-space aperture delta. Pinch-in (toScale < fromScale)
    /// returns a negative delta; pinch-out returns positive.
    ///
    /// Scaling factor `0.8` matches the spec §6.2 — one full pinch
    /// doubling moves aperture roughly one step.
    public static func magnifyDelta(from fromScale: CGFloat, to toScale: CGFloat) -> Float {
        guard fromScale > 0, toScale > 0 else { return 0 }
        let ratio = toScale / fromScale
        return Float(log(ratio)) * 0.8
    }

    /// Convert a macOS virtual key code into an aperture step, or nil
    /// if the key isn't bound to aperture. `-` (keycode 27) tightens
    /// by 0.15; `=` (keycode 24) widens by 0.15.
    ///
    /// macOS virtual keycodes are physical-position-based, so 27/24
    /// reference the keys in the `-`/`=` positions on a US keyboard
    /// regardless of the user's logical layout (AZERTY, Dvorak, JIS all
    /// fire the same keycodes from those physical keys). Consistent with
    /// how `FlightInputAccumulator` binds W/A/S/D.
    public static func keyboardStep(for keyCode: UInt16) -> Float? {
        switch keyCode {
        case 27: return -0.15  // physical `-` position
        case 24: return 0.15   // physical `=` position
        default: return nil
        }
    }
}
