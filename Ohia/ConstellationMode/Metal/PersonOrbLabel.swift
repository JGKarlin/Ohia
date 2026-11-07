import AppKit

/// How a People-lens hub orb is labelled in the 96px glyph atlas.
enum PersonOrbLabelKind: Equatable {
    /// A spelled-out name laid out on one or two lines. Covers a full name, a
    /// single chosen name when the full name won't fit, a character-wrapped
    /// long single token, and a leading-character clip of an over-long token.
    case name(String)
    case initials(String)
    case icon

    var usesWideDecalPatch: Bool {
        if case .name = self { return true }
        return false
    }
}

/// Rasterizes correspondent labels onto People-lens planet glyphs.
///
/// The label degrades through a fixed ladder so a correspondent keeps as much
/// real, readable text as the fixed atlas tile allows:
///   1. full name on one or two balanced lines, scaled down to the floor;
///   2. a single name (the shorter of the first/last name) when both won't fit;
///   3. a single long token — a one-word name, or an email address reduced to
///      its local part — wrapped across two lines, then clipped to leading
///      characters (never with ellipsis dots) when even that overflows;
///   4. two initials for unparseable multi-word names, and a person icon only
///      when there is no usable text at all.
enum PersonOrbLabel {
    static let productionTilePixels: CGFloat = 96
    static let baseFontScale: CGFloat = 0.45
    static let minFontScale: CGFloat = 0.14
    // The Metal decal path applies a radial fade over the atlas tile, so
    // stroked glyphs need a real horizontal gutter even when their measured
    // text bounds fit.
    static let contentWidthRatio: CGFloat = 0.90
    static let contentHeightRatio: CGFloat = 0.90

    static func resolveKind(
        for displayName: String,
        tileSize: CGFloat = productionTilePixels
    ) -> PersonOrbLabelKind {
        let base = labelSource(from: displayName)
        guard !base.isEmpty else { return .icon }
        let words = nameWords(from: base)
        guard let firstWord = words.first else { return .icon }

        // 1. Full spelled name on one or two balanced lines.
        let full = twoLineOrbLabel(from: base)
        if !full.isEmpty, fontSize(for: full, tileSize: tileSize) != nil {
            return .name(full)
        }

        // 2. Reduce to a single display token (shorter of the first/last name),
        //    deferring to initials for institutional / unparseable names.
        if let token = singleDisplayToken(words: words) {
            return fitSingleToken(token, tileSize: tileSize)
        }

        // 3. Initials floor.
        if let initialsText = initials(from: base) {
            return .initials(initialsText)
        }

        // 4. Nothing parsed cleanly — show as much of the first token as fits.
        return fitSingleToken(firstWord, tileSize: tileSize)
    }

    /// Supersampling factor for the SDF bake — the coverage mask is
    /// rasterized at `tileSize * sdfSupersample` before the distance
    /// transform runs, so diagonal/curved glyph edges keep sub-pixel
    /// accuracy once downsampled back to `tileSize`. The distance
    /// transform is O(width * height), so this factor squares the bake
    /// cost — measured at 3x, even thin bold strokes never reached full
    /// saturation (peaked ~199/255 for "Jane\nDoe" at the production
    /// 96px tile), which the shader doesn't need anyway since its own
    /// fill threshold sits at 128 with a sub-pixel antialiasing band. 2x
    /// keeps meaningfully better sub-pixel edge placement than no
    /// supersampling at ~44% of the 3x pixel cost, with no measurable
    /// loss to the shader's reconstructed fill.
    static let sdfSupersample = 2
    /// Distance (in final, non-supersampled tile pixels) the field
    /// represents before saturating to pure inside/outside. Chosen so the
    /// procedural stroke band the shader derives from this field reads as
    /// a deliberate outline rather than a blur.
    static let sdfSpreadPixels: Double = 5

    /// A rasterized coverage mask ready for the distance transform, plus
    /// the (supersampled) square size it was rasterized at.
    struct CoverageMask {
        let bytes: [UInt8]
        let size: Int
    }

    /// AppKit rasterization step — must run on the calling thread/actor,
    /// same as the rest of AppKit. Split from `distanceField(from:)` so a
    /// caller baking many labels (`ConstellationMetalRenderer`) can keep
    /// this part serial while parallelizing the actually-expensive
    /// distance-transform step, which touches no AppKit state and is safe
    /// to run concurrently.
    static func coverageMask(for kind: PersonOrbLabelKind, tileSize: CGFloat) -> CoverageMask {
        let superSize = Int((tileSize * CGFloat(sdfSupersample)).rounded())
        return CoverageMask(bytes: rasterizeCoverageMask(kind, size: superSize, tileSize: tileSize), size: superSize)
    }

    /// Pure-Swift distance-transform + downsample step (no AppKit) —
    /// dominates bake cost, and is safe to call from any thread/from
    /// `DispatchQueue.concurrentPerform` since it touches no shared state.
    static func distanceField(from mask: CoverageMask) -> [UInt8] {
        let field = SignedDistanceField.compute(
            coverage: mask.bytes,
            width: mask.size,
            height: mask.size,
            spread: sdfSpreadPixels * Double(sdfSupersample)
        )
        return SignedDistanceField.downsample(field, size: mask.size, factor: sdfSupersample)
    }

    /// Bakes `kind` into a `tileSize x tileSize` signed distance field
    /// ready to drop into the shared glyph atlas. `0.5` marks the glyph
    /// boundary; the GPU derives fill/stroke bands and an
    /// analytically-correct antialiasing width from the field itself, so
    /// the label stays crisp at any on-screen scale — unlike a fixed-
    /// resolution raster, which blurs under magnification and aliases
    /// under minification. Convenience wrapper over
    /// `coverageMask(for:tileSize:)` + `distanceField(from:)` for callers
    /// baking a single label (tests, or a one-off lookup); a caller baking
    /// many labels at once should call the two steps separately to
    /// parallelize the distance-transform step.
    static func sdfTile(for kind: PersonOrbLabelKind, tileSize: CGFloat) -> [UInt8] {
        distanceField(from: coverageMask(for: kind, tileSize: tileSize))
    }

    /// Fill-only rasterization (no stroke — the SDF's distance bands
    /// reconstruct the outline procedurally in the shader) into a
    /// single-channel `size x size` alpha coverage mask. `tileSize` is
    /// the *logical* (non-supersampled) tile size used to re-derive a
    /// best-fit font size at this raster resolution — decoupled from
    /// `productionTilePixels`, which only governs label *classification*
    /// (`resolveKind`) and must stay fixed for its tuned test coverage.
    private static func rasterizeCoverageMask(
        _ kind: PersonOrbLabelKind,
        size: Int,
        tileSize: CGFloat
    ) -> [UInt8] {
        let empty = [UInt8](repeating: 0, count: size * size)
        // RGBA, not single-channel `.deviceWhite` — AppKit's text/path
        // drawing does not reliably composite into a grayscale-only
        // `NSGraphicsContext` (confirmed empirically: `NSAttributedString`
        // draws produced an entirely blank mask under `.deviceWhite`, an
        // empty coverage array end to end). This matches the bitmap
        // descriptor the original raster atlas used, which is proven to
        // render text and vector paths correctly; the single channel we
        // need is extracted below by reading the red byte of each pixel,
        // since foreground/background are pure white-on-black.
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return empty
        }
        bitmap.size = NSSize(width: size, height: size)

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            NSGraphicsContext.restoreGraphicsState()
            return empty
        }
        NSGraphicsContext.current = context
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let scale = CGFloat(size) / max(tileSize, 1)
        switch kind {
        case .name(let text):
            let resolved = (fontSize(for: text, tileSize: tileSize) ?? tileSize * minFontScale) * scale
            renderCenteredLabel(text, fontSize: resolved, in: rect)
        case .initials(let text):
            let resolved = CGFloat(size) * (text.count <= 1 ? 0.58 : baseFontScale)
            renderInitialsLabel(text, fontSize: resolved, in: rect)
        case .icon:
            renderPersonIcon(in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.bitmapData else { return empty }
        // `bytesPerRow: 0` above lets AppKit choose a stride, which it
        // pads to a 32-byte boundary whenever the row byte count (`size *
        // 4` for RGBA) isn't already 32-aligned — reading pixels straight
        // out of `data` at a fixed `size * 4` stride would silently pull
        // padding bytes into the scan and shear every row. Always
        // re-derive the real stride from the bitmap rather than assuming
        // it equals `size * bytesPerPixel`.
        let stride = bitmap.bytesPerRow
        let bytesPerPixel = 4
        guard stride >= size * bytesPerPixel else { return empty }
        var result = [UInt8](repeating: 0, count: size * size)
        for row in 0..<size {
            let rowBase = row * stride
            let destRowBase = row * size
            for col in 0..<size {
                result[destRowBase + col] = data[rowBase + col * bytesPerPixel]
            }
        }
        return result
    }

    /// The text we attempt to spell out. Email addresses collapse to their
    /// local part so an address-only correspondent reads as a name rather than
    /// a generic icon (e.g. `jappleseed@gmail.com` → `jappleseed`).
    static func labelSource(from displayName: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@") else { return trimmed }
        let local = trimmed[..<at].trimmingCharacters(in: .whitespacesAndNewlines)
        return local.isEmpty ? trimmed : local
    }

    /// The single name to show when the full name won't fit: the shorter of the
    /// two words — ties go to the earlier word — so a short given name or a short
    /// surname (e.g. "Ng") is preferred for legibility. Only a clean one- or
    /// two-word name reduces to a single name; three-or-more-word names
    /// (institutional senders, titled or compound names) defer to initials,
    /// which also keeps a bare title like "Dr" from ever standing in as the name.
    static func singleDisplayToken(words: [String]) -> String? {
        guard !words.isEmpty else { return nil }
        if words.count == 1 { return words[0] }
        guard words.count <= 2 else { return nil }
        return words.min(by: { $0.count < $1.count })
    }

    /// Fit a single token: one line if it fits, else wrapped across two lines,
    /// else clipped to leading characters (no ellipsis) so it always renders
    /// something legible.
    static func fitSingleToken(_ token: String, tileSize: CGFloat) -> PersonOrbLabelKind {
        if fontSize(for: token, tileSize: tileSize) != nil {
            return .name(token)
        }
        let wrapped = charWrapTwoLines(token)
        if wrapped != token, fontSize(for: wrapped, tileSize: tileSize) != nil {
            return .name(wrapped)
        }
        return .name(clipToTwoLines(token, tileSize: tileSize))
    }

    static func twoLineOrbLabel(from displayName: String) -> String {
        let words = nameWords(from: displayName)
        guard let first = words.first else { return "" }
        if words.count >= 2 {
            return balancedTwoLineLabel(words: words)
        }
        return first
    }

    static func initials(from displayName: String) -> String? {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("@") else { return nil }

        let words = nameWords(from: name)
        if words.count >= 2 {
            let first = words[0].first.map(String.init) ?? ""
            let second = words[1].first.map(String.init) ?? ""
            let combined = first + second
            return combined.isEmpty ? nil : combined.localizedUppercase
        }

        let clusters = Array(name).prefix(2).map(String.init).joined()
        return clusters.isEmpty ? nil : clusters.localizedUppercase
    }

    static func fontSize(for twoLineText: String, tileSize: CGFloat) -> CGFloat? {
        guard tileSize > 0 else { return nil }
        let maxWidth = tileSize * contentWidthRatio
        let maxHeight = tileSize * contentHeightRatio
        var size = tileSize * baseFontScale
        let floor = tileSize * minFontScale

        while size >= floor {
            if textFits(
                twoLineText,
                fontSize: size,
                maxWidth: maxWidth,
                maxHeight: maxHeight
            ) {
                return size
            }
            size *= 0.9
        }
        return nil
    }

    /// Split a single long token across two balanced lines by character count.
    /// Grapheme-cluster aware, so CJK and combined characters wrap correctly.
    private static func charWrapTwoLines(_ token: String) -> String {
        let chars = Array(token)
        guard chars.count >= 2 else { return token }
        let mid = (chars.count + 1) / 2
        let first = String(chars[..<mid])
        let second = String(chars[mid...])
        return "\(first)\n\(second)"
    }

    /// Fill up to two lines with leading grapheme clusters at the floor font,
    /// discarding any overflow. No ellipsis — the orb's radial fade feathers the
    /// clipped edge.
    private static func clipToTwoLines(_ token: String, tileSize: CGFloat) -> String {
        guard tileSize > 0 else { return String(Array(token).prefix(1)) }
        let floor = tileSize * minFontScale
        let maxWidth = tileSize * contentWidthRatio
        let chars = Array(token)
        var lines: [String] = []
        var index = 0
        while lines.count < 2 && index < chars.count {
            var line = ""
            while index < chars.count {
                let candidate = line + String(chars[index])
                if singleLineBounds(candidate, fontSize: floor).width <= maxWidth {
                    line = candidate
                    index += 1
                } else {
                    break
                }
            }
            if line.isEmpty {
                // A single glyph wider than the gutter — emit it anyway so the
                // loop terminates and the tile never renders blank.
                line = String(chars[index])
                index += 1
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func nameWords(from displayName: String) -> [String] {
        displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" || $0 == "." })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func balancedTwoLineLabel(words: [String]) -> String {
        guard words.count >= 2 else { return words.first ?? "" }
        var bestSplit = 1
        var bestScore = Int.max
        for split in 1..<words.count {
            let first = words[..<split].joined(separator: " ")
            let second = words[split...].joined(separator: " ")
            let lineImbalance = abs(first.count - second.count)
            let longestLine = max(first.count, second.count)
            // Prefer the split whose longest line stays shortest, then use
            // line balance to keep titles from being stranded alone.
            let score = longestLine * 4 + lineImbalance
            if score < bestScore {
                bestScore = score
                bestSplit = split
            }
        }
        let first = words[..<bestSplit].joined(separator: " ")
        let second = words[bestSplit...].joined(separator: " ")
        return "\(first)\n\(second)"
    }

    /// Hold the proven -2.0 outline at ≥~15pt; thin it proportionally for
    /// smaller labels so a fixed-width stroke doesn't swallow the glyphs.
    private static func strokeWidth(forFontSize fontSize: CGFloat) -> CGFloat {
        -min(2.0, fontSize * 0.13)
    }

    private static func labelAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping
        return [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .strokeColor: NSColor.black.withAlphaComponent(0.58),
            .strokeWidth: strokeWidth(forFontSize: fontSize),
            .paragraphStyle: paragraph
        ]
    }

    private static func labelLines(from twoLineText: String) -> [String] {
        twoLineText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    private static func singleLineBounds(
        _ line: String,
        fontSize: CGFloat
    ) -> CGRect {
        NSAttributedString(string: line, attributes: labelAttributes(fontSize: fontSize))
            .boundingRect(
                with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
    }

    private static func stackedLabelSize(
        for lines: [String],
        fontSize: CGFloat
    ) -> (width: CGFloat, height: CGFloat) {
        var maxWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        for line in lines {
            let bounds = singleLineBounds(line, fontSize: fontSize)
            maxWidth = max(maxWidth, bounds.width)
            totalHeight += bounds.height
        }
        return (maxWidth, totalHeight)
    }

    private static func textFits(
        _ text: String,
        fontSize: CGFloat,
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) -> Bool {
        let lines = labelLines(from: text)
        guard !lines.isEmpty, lines.count <= 2 else { return false }

        let stacked = stackedLabelSize(for: lines, fontSize: fontSize)
        return stacked.width <= maxWidth && stacked.height <= maxHeight
    }

    /// Fill-only attributes for baking the SDF coverage mask — no stroke;
    /// the shader reconstructs the outline band from the distance field
    /// itself. Distinct from `labelAttributes(fontSize:)`, which stays
    /// stroke-inclusive because it's the fit-measurement oracle behind
    /// `fontSize(for:)` and must keep its already-tuned test coverage.
    private static func renderAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping
        return [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
    }

    private static func renderCenteredLabel(_ text: String, fontSize: CGFloat, in rect: NSRect) {
        let lines = labelLines(from: text)
        guard !lines.isEmpty else { return }

        let attributes = renderAttributes(fontSize: fontSize)
        let stacked = stackedLabelSize(for: lines, fontSize: fontSize)
        let contentWidth = rect.width * contentWidthRatio
        var cursorY = rect.midY + stacked.height * 0.5 - rect.height * 0.02

        for line in lines {
            let lineBounds = singleLineBounds(line, fontSize: fontSize)
            cursorY -= lineBounds.height
            let drawRect = NSRect(
                x: rect.midX - contentWidth * 0.5,
                y: cursorY,
                width: contentWidth,
                height: lineBounds.height + 2
            )
            NSAttributedString(string: line, attributes: attributes).draw(in: drawRect)
        }
    }

    private static func renderInitialsLabel(_ text: String, fontSize: CGFloat, in rect: NSRect) {
        let attributed = NSAttributedString(string: text, attributes: renderAttributes(fontSize: fontSize))
        let bounds = attributed.boundingRect(
            with: NSSize(width: rect.width * contentWidthRatio, height: rect.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let drawRect = NSRect(
            x: rect.minX + rect.width * 0.04,
            y: rect.midY - bounds.height * 0.5 - rect.height * 0.02,
            width: rect.width * contentWidthRatio,
            height: bounds.height + 4
        )
        attributed.draw(in: drawRect)
    }

    private static func renderPersonIcon(in rect: NSRect) {
        // Solid fill — opacity is the shader's job now (via the fill mask
        // it derives from the SDF), not baked into the source coverage.
        NSColor.white.setFill()
        let headSize = rect.width * 0.30
        let head = NSRect(
            x: rect.midX - headSize * 0.5,
            y: rect.midY + rect.height * 0.10,
            width: headSize,
            height: headSize
        )
        NSBezierPath(ovalIn: head).fill()

        let shoulders = NSBezierPath()
        shoulders.move(to: NSPoint(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.24))
        shoulders.curve(
            to: NSPoint(x: rect.maxX - rect.width * 0.22, y: rect.minY + rect.height * 0.24),
            controlPoint1: NSPoint(x: rect.minX + rect.width * 0.34, y: rect.minY + rect.height * 0.46),
            controlPoint2: NSPoint(x: rect.maxX - rect.width * 0.34, y: rect.minY + rect.height * 0.46)
        )
        shoulders.line(to: NSPoint(x: rect.maxX - rect.width * 0.16, y: rect.minY + rect.height * 0.14))
        shoulders.line(to: NSPoint(x: rect.minX + rect.width * 0.16, y: rect.minY + rect.height * 0.14))
        shoulders.close()
        shoulders.fill()
    }
}
