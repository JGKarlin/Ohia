import Foundation
import Metal
import simd

/// A texture and its matching index-addressed coordinates move together from
/// the preparation actor to the renderer. The builder never retains textures
/// after transferring them, and the renderer treats them as immutable.
nonisolated struct PersonGlyphAtlas {
    let texture: MTLTexture?
    let uvs: [SIMD4<Float>]
    let wideDecalFlags: [Bool]

    static func empty(hubCount: Int) -> Self {
        Self(
            texture: nil,
            uvs: Array(repeating: .zero, count: hubCount),
            wideDecalFlags: Array(repeating: false, count: hubCount)
        )
    }
}

nonisolated struct PersonGlyphTile: Sendable {
    enum Source: Sendable {
        case distanceField([UInt8])
        case coverage(bytes: [UInt8], size: Int)
    }

    let key: String
    let source: Source
}

/// One serial worker per renderer bounds CPU preparation to one running bake,
/// even when rapidly changing filters cancel and replace pending requests.
/// AppKit rasterization remains on MainActor; only value-type pixels cross
/// this boundary. No main-thread join or GPU completion wait is involved.
actor PersonGlyphAtlasBuilder {
    private var tileCache: [String: [UInt8]] = [:]
    private static let tileCacheCapacity = 512

    func cachedTiles() -> [String: [UInt8]] { tileCache }

    func build(
        tiles: [PersonGlyphTile],
        tileSize: Int,
        hubCount: Int,
        labeledIndices: [Int],
        wideDecalFlags: [Bool],
        supersample: Int,
        spread: Double,
        device: MTLDevice
    ) throws -> sending PersonGlyphAtlas {
        try Task.checkCancellation()
        guard !tiles.isEmpty else { return .empty(hubCount: hubCount) }
        let activeKeys = Set(tiles.map(\.key))
        defer {
            if tileCache.count > Self.tileCacheCapacity {
                tileCache = tileCache.filter { activeKeys.contains($0.key) }
            }
        }

        let columns = Int(ceil(sqrt(Double(tiles.count))))
        let rows = (tiles.count + columns - 1) / columns
        let width = columns * tileSize
        let height = rows * tileSize
        var atlasBytes = [UInt8](repeating: 0, count: width * height)
        var uvs = Array(repeating: SIMD4<Float>.zero, count: hubCount)

        for (tileIndex, input) in tiles.enumerated() {
            try Task.checkCancellation()
            let tile: [UInt8]
            if let cached = tileCache[input.key] {
                tile = cached
            } else {
                switch input.source {
                case .distanceField(let cached):
                    tile = cached
                case .coverage(let bytes, let size):
                    let field = SignedDistanceField.compute(
                        coverage: bytes,
                        width: size,
                        height: size,
                        spread: spread * Double(supersample)
                    )
                    tile = SignedDistanceField.downsample(field, size: size, factor: supersample)
                }
                tileCache[input.key] = tile
            }

            let originX = (tileIndex % columns) * tileSize
            let originY = (tileIndex / columns) * tileSize
            for y in 0..<tileSize {
                let source = (y * tileSize)..<((y + 1) * tileSize)
                let destination = ((originY + y) * width + originX)..<((originY + y) * width + originX + tileSize)
                atlasBytes.replaceSubrange(destination, with: tile[source])
            }
            uvs[labeledIndices[tileIndex]] = SIMD4<Float>(
                Float(originX) / Float(width), Float(originY) / Float(height),
                Float(tileSize) / Float(width), Float(tileSize) / Float(height)
            )
        }

        try Task.checkCancellation()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: height, mipmapped: true
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PreparationError.textureAllocationFailed
        }

        var levelBytes = atlasBytes
        var levelWidth = width
        var levelHeight = height
        for level in 0..<texture.mipmapLevelCount {
            try Task.checkCancellation()
            levelBytes.withUnsafeBytes { bytes in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, levelWidth, levelHeight),
                    mipmapLevel: level, withBytes: bytes.baseAddress!, bytesPerRow: levelWidth
                )
            }
            if level + 1 < texture.mipmapLevelCount {
                let nextWidth = max(1, levelWidth / 2)
                let nextHeight = max(1, levelHeight / 2)
                levelBytes = Self.downsample(
                    levelBytes, width: levelWidth, height: levelHeight,
                    outWidth: nextWidth, outHeight: nextHeight
                )
                levelWidth = nextWidth
                levelHeight = nextHeight
            }
        }
        return PersonGlyphAtlas(texture: texture, uvs: uvs, wideDecalFlags: wideDecalFlags)
    }

    private enum PreparationError: Error {
        case textureAllocationFailed
    }

    /// 96px tiles produce odd dimensions late in the mip chain. Clamp edge
    /// samples so those levels have the same box filter as the original atlas.
    private static func downsample(
        _ source: [UInt8], width: Int, height: Int, outWidth: Int, outHeight: Int
    ) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: outWidth * outHeight)
        for oy in 0..<outHeight {
            let sy0 = min(oy * 2, height - 1)
            let sy1 = min(oy * 2 + 1, height - 1)
            for ox in 0..<outWidth {
                let sx0 = min(ox * 2, width - 1)
                let sx1 = min(ox * 2 + 1, width - 1)
                let sum = Int(source[sy0 * width + sx0]) + Int(source[sy0 * width + sx1])
                    + Int(source[sy1 * width + sx0]) + Int(source[sy1 * width + sx1])
                result[oy * outWidth + ox] = UInt8(sum / 4)
            }
        }
        return result
    }
}
