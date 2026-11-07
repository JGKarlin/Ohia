import Foundation
import simd

/// Camera-anchored hot-zone selector. Pure static helper — no state, no
/// MainActor, no SwiftUI or renderer dependency.
///
/// `select` returns the subset of input nodes inside a sphere of radius
/// R around the camera, always unioned with `alwaysInclude` (nodes the
/// user is actively working on — search results, citations, locked,
/// hovered). If the union is smaller than `kFloor`, the nearest-by-distance
/// non-member nodes are appended until the floor is met. This guarantees
/// the scene never goes empty when the user tightens aperture in a
/// sparse region of the vector space.
public enum ApertureSelector {

    /// Logarithmic mapping from aperture [0, 1] to world-space radius
    /// [0.02, 10.0]. Pinch feels linear in "opening speed." Inputs are
    /// clamped.
    public static func radius(forAperture aperture: Double) -> Float {
        let minR: Float = 0.02
        let maxR: Float = 10.0
        let t = max(0.0, min(1.0, aperture))
        let logMin = log(minR)
        let logMax = log(maxR)
        return exp(logMin + Float(t) * (logMax - logMin))
    }

    /// Select the camera-anchored subset of `nodes`, with always-include
    /// exemptions and a minimum-K floor.
    ///
    /// Aperture is an inspection tool, not a data filter: it must never
    /// hide a node the user is actively working on (search result, Q&A
    /// citation, locked, hovered). Exemptions therefore ride **additively
    /// on top of** the K-floor, so at tight aperture with one far exemption
    /// the output is `kFloor + 1`, not `kFloor`.
    ///
    /// - `aperture`: 0.0 = tightest, 1.0 = widest. Clamped to [0, 1].
    /// - `alwaysInclude`: vectorIds to render even if outside the radius.
    /// - `kFloor`: minimum number of nodes returned from the
    ///   "inside-radius ∪ K-floor" set, before exemptions are added. If the
    ///   inside-radius set is smaller than `kFloor`, the nearest-to-camera
    ///   non-members fill up to `kFloor`. Exemptions are additive on top
    ///   (they do not count toward the floor). When the input has fewer
    ///   than `kFloor` nodes, returns what's available.
    ///
    /// Output order: input order for nodes inside the radius, followed by
    /// K-floor filler in vectorId-ascending order among ties on distance,
    /// followed by always-include exemptions in vectorId-ascending order.
    public static func select(
        nodes: [VectorRecord],
        cameraPosition: SIMD3<Float>,
        aperture: Double,
        alwaysInclude: Set<Int64> = [],
        kFloor: Int = 50
    ) -> [VectorRecord] {
        // Short-circuit: widest aperture with no special selections → return as-is.
        if aperture >= 0.999 {
            return nodes
        }

        let r = radius(forAperture: aperture)
        let r2 = r * r

        // Precompute squared distances once.
        let dist2: [Int64: Float] = Dictionary(uniqueKeysWithValues:
            nodes.compactMap { rec -> (Int64, Float)? in
                guard let x = rec.layoutX, let y = rec.layoutY, let z = rec.layoutZ else {
                    return nil
                }
                let d = SIMD3<Float>(x, y, z) - cameraPosition
                return (rec.vectorId, simd_dot(d, d))
            }
        )

        // Step 1: nodes inside radius, preserving input order.
        var kept: [VectorRecord] = []
        var keptIds: Set<Int64> = []
        for rec in nodes {
            guard let d2 = dist2[rec.vectorId] else { continue }
            if d2 <= r2 {
                kept.append(rec)
                keptIds.insert(rec.vectorId)
            }
        }

        // Step 2: K-floor — top up with the nearest non-member nodes so the
        // "inside ∪ K-floor" union has at least `kFloor` nodes. Exemptions do
        // NOT count toward this floor — they are additive in Step 3. When the
        // input has fewer than `kFloor` nodes total, we simply fill with what
        // we have.
        if kept.count < kFloor {
            let candidates = nodes.filter { !keptIds.contains($0.vectorId) && dist2[$0.vectorId] != nil }
                .sorted { a, b in
                    let da = dist2[a.vectorId]!
                    let db = dist2[b.vectorId]!
                    if da == db { return a.vectorId < b.vectorId }
                    return da < db
                }
            let need = kFloor - kept.count
            for rec in candidates.prefix(need) {
                kept.append(rec)
                keptIds.insert(rec.vectorId)
            }
        }

        // Step 3: union with alwaysInclude exemptions (vectorId-ascending for
        // determinism). Skipped when the exemption is already present from
        // Step 1 or Step 2, so no duplicates.
        let exemptRecords = nodes.filter { alwaysInclude.contains($0.vectorId) && !keptIds.contains($0.vectorId) }
            .sorted { $0.vectorId < $1.vectorId }
        for rec in exemptRecords {
            kept.append(rec)
            keptIds.insert(rec.vectorId)
        }

        return kept
    }
}
