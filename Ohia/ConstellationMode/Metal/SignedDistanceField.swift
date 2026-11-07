import Foundation

/// 8-points signed sequential Euclidean distance transform (8SSEDT).
///
/// Converts a binary coverage mask (e.g. a rasterized glyph) into a
/// normalized signed distance field: 0.5 marks the shape's boundary,
/// values above 0.5 are inside (saturating to 1.0 at `spread` pixels or
/// deeper), values below 0.5 are outside (saturating to 0.0 at `spread`
/// pixels or farther). Unlike a raw alpha mask, this field stays smooth
/// under both magnification and minification — the GPU reconstructs a
/// crisp, resolution-independent edge from it with a simple threshold
/// instead of needing the source raster to already be at display
/// resolution. O(width * height); no external dependency, since neither
/// vImage nor Core Image ships a distance-transform primitive.
nonisolated enum SignedDistanceField {
    /// Nearest same/opposite-class pixel offset, propagated across the
    /// grid. `far` is an unreached sentinel; its magnitude just needs to
    /// exceed any real in-image distance.
    private struct Offset {
        var dx: Int16
        var dy: Int16

        static let far = Offset(dx: 30_000, dy: 30_000)
        static let zero = Offset(dx: 0, dy: 0)
    }

    /// `coverage` is a row-major `width * height` mask, one byte per
    /// pixel; a pixel counts as "inside" when its value is >= 128.
    /// Returns a row-major `width * height` field of the same size.
    static func compute(coverage: [UInt8], width: Int, height: Int, spread: Double) -> [UInt8] {
        guard width > 0, height > 0, coverage.count == width * height, spread > 0 else {
            return coverage
        }
        let inside = coverage.map { $0 >= 128 }
        // Distance from every "inside" pixel to the nearest "outside" pixel,
        // and vice versa — two independent unsigned transforms, combined
        // below by polarity into one signed field.
        let distanceToOutside = unsignedDistance(seedWhere: { !inside[$0] }, width: width, height: height)
        let distanceToInside = unsignedDistance(seedWhere: { inside[$0] }, width: width, height: height)

        var field = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let signedDistance = inside[index] ? distanceToOutside[index] : -distanceToInside[index]
            let normalized = 0.5 + signedDistance / (2.0 * spread)
            field[index] = UInt8((normalized * 255.0).rounded().clamped(to: 0...255))
        }
        return field
    }

    /// Unsigned Euclidean distance (in pixels) from every pixel to the
    /// nearest pixel where `seedWhere` is true, via two-pass 8SSEDT
    /// propagation (forward top-to-bottom, then backward bottom-to-top;
    /// each pass also sweeps its row horizontally so distance propagates
    /// in all eight directions across the two passes).
    private static func unsignedDistance(
        seedWhere: (Int) -> Bool,
        width: Int,
        height: Int
    ) -> [Double] {
        var grid = [Offset](repeating: .far, count: width * height)
        for index in 0..<grid.count where seedWhere(index) {
            grid[index] = .zero
        }

        grid.withUnsafeMutableBufferPointer { buffer in
            @inline(__always) func distSq(_ o: Offset) -> Int32 {
                Int32(o.dx) * Int32(o.dx) + Int32(o.dy) * Int32(o.dy)
            }
            @inline(__always) func compare(_ p: inout Offset, x: Int, y: Int, ox: Int, oy: Int) {
                let nx = x + ox, ny = y + oy
                guard nx >= 0, nx < width, ny >= 0, ny < height else { return }
                var other = buffer[ny * width + nx]
                other.dx += Int16(ox)
                other.dy += Int16(oy)
                if distSq(other) < distSq(p) {
                    p = other
                }
            }

            for y in 0..<height {
                for x in 0..<width {
                    var p = buffer[y * width + x]
                    compare(&p, x: x, y: y, ox: -1, oy: 0)
                    compare(&p, x: x, y: y, ox: 0, oy: -1)
                    compare(&p, x: x, y: y, ox: -1, oy: -1)
                    compare(&p, x: x, y: y, ox: 1, oy: -1)
                    buffer[y * width + x] = p
                }
                for x in stride(from: width - 1, through: 0, by: -1) {
                    var p = buffer[y * width + x]
                    compare(&p, x: x, y: y, ox: 1, oy: 0)
                    buffer[y * width + x] = p
                }
            }
            for y in stride(from: height - 1, through: 0, by: -1) {
                for x in stride(from: width - 1, through: 0, by: -1) {
                    var p = buffer[y * width + x]
                    compare(&p, x: x, y: y, ox: 1, oy: 0)
                    compare(&p, x: x, y: y, ox: 0, oy: 1)
                    compare(&p, x: x, y: y, ox: 1, oy: 1)
                    compare(&p, x: x, y: y, ox: -1, oy: 1)
                    buffer[y * width + x] = p
                }
                for x in 0..<width {
                    var p = buffer[y * width + x]
                    compare(&p, x: x, y: y, ox: -1, oy: 0)
                    buffer[y * width + x] = p
                }
            }
        }

        return grid.map { offset in
            sqrt(Double(Int32(offset.dx) * Int32(offset.dx) + Int32(offset.dy) * Int32(offset.dy)))
        }
    }

    /// Box-filter downsample by an integer `factor` (e.g. 3 for a 3x
    /// supersampled bake). Safe for a smooth SDF, unlike downsampling a
    /// raw alpha mask — this is precisely why the field mips correctly
    /// where the old raster-plus-stroke atlas did not.
    static func downsample(_ field: [UInt8], size: Int, factor: Int) -> [UInt8] {
        guard factor > 1 else { return field }
        let outSize = size / factor
        var result = [UInt8](repeating: 0, count: outSize * outSize)
        for oy in 0..<outSize {
            for ox in 0..<outSize {
                var sum = 0
                for dy in 0..<factor {
                    let sy = oy * factor + dy
                    let rowBase = sy * size + ox * factor
                    for dx in 0..<factor {
                        sum += Int(field[rowBase + dx])
                    }
                }
                result[oy * outSize + ox] = UInt8(sum / (factor * factor))
            }
        }
        return result
    }
}

private extension Comparable {
    nonisolated func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
