//
//  SESubtitleLayer.swift
//  SEPlayer
//
//  Created by tvrrp on 02.10.2026.
//

import CoreText
import QuartzCore
import SEPlayerCommon
#if canImport(MediaAccessibility)
import MediaAccessibility
#endif

/// Draws cues with Core Text.
///
/// Cues are positioned in ``viewport``, the picture of the video, and styled with ``captionStyle``, which follows the user's
/// settings in Settings › Accessibility › Subtitles & Captioning by default.
///
/// The picture keeps a title-safe area, inset by ``safeAreaInsetFraction`` of its size on each side: cues without a
/// line sit at its bottom, lines wrap in its width, and cues placed elsewhere move into it. Text sizes and the safe area
/// are relative to ``sizingViewport``, the whole picture.
///
/// Like any layer, use it on the main thread.
@MainActor
public final class SESubtitleLayer: CALayer {
    /// The default text size, as a fraction of the picture height: 5% of the height of its title-safe area.
    public static let defaultTextSizeFraction: CGFloat = 0.045

    /// The default inset of the title-safe area from each edge of the picture, as a fraction of its width and height.
    public static let defaultSafeAreaInsetFraction: CGFloat = 0.05

    /// The cues to show.
    public var cues: [Cue] = [] {
        didSet {
            guard cues != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// The caption style. Setting it stops following the user's settings, see ``followsUserStyle``.
    public var captionStyle: CaptionStyle = .user {
        didSet {
            fonts.removeAll()
            invalidateCues()
        }
    }

    /// Whether ``captionStyle`` is the style the user chose in the system settings, and follows its changes.
    public var followsUserStyle = true {
        didSet {
            guard followsUserStyle != oldValue else { return }
            if followsUserStyle { captionStyle = .user }
            updateSettingsObserver()
        }
    }

    /// Whether styling embedded within the cues should be applied. Font sizes are controlled separately, see
    /// ``applyEmbeddedFontSizes``.
    public var applyEmbeddedStyles = true {
        didSet { invalidateCues() }
    }

    /// Whether font sizes embedded within the cues should be applied. Only takes effect if ``applyEmbeddedStyles`` is
    /// true.
    public var applyEmbeddedFontSizes = true {
        didSet { invalidateCues() }
    }

    /// The text size, or `nil` for the default: ``defaultTextSizeFraction`` scaled by the user's preferred character
    /// size, and narrower in a portrait picture.
    public var textSize: Cue.TextSize? {
        didSet { invalidateCues() }
    }

    /// The inset of the title-safe area from each edge of the picture, as a fraction of its width and height.
    public var safeAreaInsetFraction = SESubtitleLayer.defaultSafeAreaInsetFraction {
        didSet { invalidateCues() }
    }

    /// Where cues are positioned in the bounds: the picture of the video. `nil` for the whole bounds.
    public var viewport: CGRect? {
        didSet {
            guard viewport != oldValue else { return }
            invalidateCues()
        }
    }

    /// What text and image sizes are relative to, in the bounds: the whole picture, when the ``viewport`` is only the
    /// part of it the subtitles may use, such as above the controls. `nil` for the viewport.
    public var sizingViewport: CGRect? {
        didSet {
            guard sizingViewport != oldValue else { return }
            invalidateCues()
        }
    }

    public override var contentsScale: CGFloat {
        didSet {
            guard contentsScale != oldValue else { return }
            invalidateCues()
        }
    }

    private var observesSettings = false

    /// The layers of the cues on screen, in the order of ``cues``.
    private var cueLayers: [CueLayer] = []
    /// Bumped by every change to how cues are drawn: a cue layer drawn for another generation draws its cue again.
    private var generation = 0
    /// The bounds the cue layers were drawn in.
    private var drawnBounds: CGRect?
    private let fonts = FontCache()

    public override init() {
        super.init()
        #if os(macOS)
        // Cues are laid out top down.
        isGeometryFlipped = true
        #endif
        updateSettingsObserver()
    }

    /// Core Animation's copies, such as the presentation layer.
    public override init(layer: Any) {
        super.init(layer: layer)
        guard let layer = layer as? SESubtitleLayer else { return }
        cues = layer.cues
        captionStyle = layer.captionStyle
        followsUserStyle = layer.followsUserStyle
        applyEmbeddedStyles = layer.applyEmbeddedStyles
        applyEmbeddedFontSizes = layer.applyEmbeddedFontSizes
        textSize = layer.textSize
        safeAreaInsetFraction = layer.safeAreaInsetFraction
        viewport = layer.viewport
        sizingViewport = layer.sizingViewport
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError()
    }

    /// Cues change at once: no fade between contents, and no animation of the layout.
    public override func action(forKey event: String) -> CAAction? {
        NSNull()
    }

    /// Shows the cues of `cueGroup`.
    public func setCues(_ cueGroup: CueGroup) {
        cues = cueGroup.cues
    }

    // MARK: - Layout

    /// The cues draw in layers of their own, each when it or the way cues look changes: cues that stay on screen while
    /// others come and go, as captions do while they are typed on, aren't drawn again.
    public override func setNeedsDisplay() {
        invalidateCues()
    }

    public override func layoutSublayers() {
        super.layoutSublayers()
        if drawnBounds != bounds {
            drawnBounds = bounds
            generation &+= 1
        }

        guard let (painter, sizingViewport) = makePainter() else {
            cueLayers.forEach { $0.removeFromSuperlayer() }
            cueLayers = []
            return
        }

        // Layers keep the cues they show; the others show the new cues.
        var unused = cueLayers
        var layers = [CueLayer?](repeating: nil, count: cues.count)
        for (index, cue) in cues.enumerated() {
            if let match = unused.firstIndex(where: { $0.generation == generation && $0.cue == cue }) {
                layers[index] = unused.remove(at: match)
            }
        }
        for (index, cue) in cues.enumerated() where layers[index] == nil {
            let layer = unused.popLast() ?? CueLayer()
            let cueTextSize = cue.textSize.map { resolveTextSize($0, viewportHeight: sizingViewport.height) }
            layer.show(cue, painter.render(cue, cueTextSize: cueTextSize), generation: generation, scale: contentsScale)
            layers[index] = layer
        }
        unused.forEach { $0.removeFromSuperlayer() }

        let newLayers = layers.compactMap { $0 }
        if newLayers != cueLayers {
            // In the order of the cues: later ones show above.
            for layer in newLayers {
                addSublayer(layer)
            }
            cueLayers = newLayers
        }
    }

    /// Makes the cue layers draw again, in a new generation.
    private func invalidateCues() {
        generation &+= 1
        setNeedsLayout()
    }

    /// The painter of the cues in the bounds, and the viewport text sizes are relative to; `nil` with nothing to draw.
    private func makePainter() -> (CuePainter, sizingViewport: CGRect)? {
        let viewport = viewport?.intersection(bounds) ?? bounds
        guard !cues.isEmpty, viewport.width > 0, viewport.height > 0 else {
            return nil
        }
        // Making room for the controls moves the subtitles, it doesn't shrink them.
        let sizingViewport = sizingViewport.map { $0.intersection(bounds) }.flatMap { $0.isEmpty ? nil : $0 } ?? viewport

        var defaultTextSize = resolveTextSize(
            textSize ?? .fractional(Self.defaultTextSizeFraction * captionStyle.relativeCharacterSize),
            viewportHeight: sizingViewport.height
        )
        // A portrait picture is narrow for its height: the text narrows with it.
        if textSize == nil, sizingViewport.width < sizingViewport.height {
            defaultTextSize *= sizingViewport.width / sizingViewport.height
        }
        guard defaultTextSize > 0 else {
            // Text has no height.
            return nil
        }

        let painter = CuePainter(
            style: captionStyle,
            applyEmbeddedStyles: applyEmbeddedStyles,
            applyEmbeddedFontSizes: applyEmbeddedFontSizes && applyEmbeddedStyles && !captionStyle.overridesTextSize,
            defaultTextSize: defaultTextSize,
            safeInsets: CGSize(
                width: sizingViewport.width * safeAreaInsetFraction,
                height: sizingViewport.height * safeAreaInsetFraction
            ),
            viewport: viewport,
            sizingViewport: sizingViewport,
            scale: contentsScale,
            fonts: fonts
        )
        return (painter, sizingViewport)
    }

    private func resolveTextSize(_ textSize: Cue.TextSize, viewportHeight: CGFloat) -> CGFloat {
        switch textSize {
        case let .fractional(fraction), let .fractionalIgnoringPadding(fraction):
            return fraction * viewportHeight
        case let .absolute(size):
            return size
        }
    }

    private func updateSettingsObserver() {
        #if canImport(MediaAccessibility)
        let name = Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String)
        if followsUserStyle, !observesSettings {
            NotificationCenter.default.addObserver(self, selector: #selector(captionSettingsChanged), name: name, object: nil)
            observesSettings = true
        } else if !followsUserStyle, observesSettings {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
            observesSettings = false
        }
        #endif
    }

    @objc private func captionSettingsChanged() {
        // Posted on any queue.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.followsUserStyle else { return }
            self.captionStyle = .user
        }
    }
}

/// Lays out and draws one cue at a time, for a ``CueLayer``.
private struct CuePainter {
    /// The least space between lines, as a fraction of their height.
    static let lineSpacingRatio: CGFloat = 0.2
    /// The width of an outline, as a fraction of the height of its line.
    static let outlineWidthRatio: CGFloat = 0.1
    /// The offset and blur of shadows, as a fraction of the font size; a third less above ``largeEdgeTextSize``.
    static let shadowRatio: CGFloat = 3 / 34
    static let largeEdgeTextSize: CGFloat = 60
    /// The weight of bold text, as `UIFont.Weight.bold`.
    static let boldWeight: Double = 0.4
    /// The size of ruby text relative to the base text, Core Text's default.
    static let rubySizeFactor: CGFloat = 0.5
    /// How far past the cue box the text is drawn, for its edges and shadows, as a fraction of the font size.
    static let contentMarginRatio: CGFloat = 0.5

    let style: CaptionStyle
    let applyEmbeddedStyles: Bool
    let applyEmbeddedFontSizes: Bool
    let defaultTextSize: CGFloat
    /// The insets of the title-safe area from the edges of the viewport.
    let safeInsets: CGSize
    let viewport: CGRect
    /// What image sizes are relative to.
    let sizingViewport: CGRect
    /// The pixels per point of the drawings.
    let scale: CGFloat
    let fonts: FontCache

    /// The cue laid out in the viewport, and drawn; `nil` when there is nothing to show.
    func render(_ cue: Cue, cueTextSize: CGFloat?) -> CueRendering? {
        if let image = cue.image {
            return .image(image, frame: imageFrame(of: image, cue: cue))
        } else if let text = cue.text, !text.characters.isEmpty {
            return renderText(text, of: cue, cueTextSize: cueTextSize).map { .text($0) }
        }
        return nil
    }

    // MARK: - Image cues

    private func imageFrame(of image: CGImage, cue: Cue) -> CGRect {
        let anchorX = viewport.minX + viewport.width * (cue.position ?? 0.5)
        let anchorY = lineFraction(cue.line).map { viewport.minY + viewport.height * $0 } ?? viewport.maxY - safeInsets.height
        let width = sizingViewport.width * (cue.size ?? min(1, CGFloat(image.width) / sizingViewport.width))
        let height = cue.imageHeight.map { sizingViewport.height * $0 }
            ?? width * CGFloat(image.height) / CGFloat(image.width)
        let x = switch cue.positionAnchor ?? (cue.position == nil ? .middle : .start) {
        case .end: anchorX - width
        case .middle: anchorX - width / 2
        case .start: anchorX
        }
        let y = switch cue.lineAnchor ?? (cue.line == nil ? .end : .start) {
        case .end: anchorY - height
        case .middle: anchorY - height / 2
        case .start: anchorY
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func lineFraction(_ line: Cue.Line?) -> CGFloat? {
        if case let .fraction(fraction) = line { fraction } else { nil }
    }

    // MARK: - Text cues

    private func renderText(_ text: AttributedString, of cue: Cue, cueTextSize: CGFloat?) -> TextCueRendering? {
        let isVertical = cue.verticalType != nil
        // The writing direction runs along the inline axis, and lines follow each other along the block axis.
        let inlineExtent = isVertical ? viewport.height : viewport.width
        let blockExtent = isVertical ? viewport.width : viewport.height
        let inlineSafeInset = isVertical ? safeInsets.height : safeInsets.width
        let blockSafeInset = isVertical ? safeInsets.width : safeInsets.height

        let fontSize = applyEmbeddedFontSizes ? cueTextSize ?? defaultTextSize : defaultTextSize
        // The window is the text and its padding, half on each side; the padding above and below in whole points.
        let metrics = style.windowMetrics
        let textPadding = fontSize * metrics.horizontalPadding / 2
        let verticalPadding = (fontSize * metrics.verticalPadding / 2).rounded(.up)
        let cornerRadius = (fontSize * metrics.cornerRadius).rounded(.up)

        // Lines wrap in the title-safe area; their padding may reach past it.
        var availableWidth = inlineExtent - inlineSafeInset * 2
        if let size = cue.size {
            availableWidth = min(availableWidth, inlineExtent * size)
        }
        guard availableWidth > 0 else {
            // TODO: log "Skipped drawing subtitle cue (insufficient space)"
            return nil
        }

        let cueText = makeTypesetText(text, fontSize: fontSize, isVertical: isVertical)
        let typesetter = CTTypesetterCreateWithAttributedString(cueText)
        var lines = typeset(typesetter, length: cueText.length, width: availableWidth)
        guard !lines.isEmpty else { return nil }

        let textHeight = Self.height(of: lines) + verticalPadding * 2
        var textWidth = lines.reduce(0) { max($0, $1.width) }
        if cue.size != nil && textWidth < availableWidth {
            textWidth = availableWidth
        }
        textWidth = (textWidth + textPadding * 2).rounded(.up)

        var textStart: CGFloat
        if let position = cue.position {
            let anchorPosition = (inlineExtent * position).rounded()
            textStart = switch cue.positionAnchor {
            case .end: anchorPosition - textWidth
            case .middle: (anchorPosition * 2 - textWidth) / 2
            case .start, nil: anchorPosition
            }
        } else {
            textStart = (inlineExtent - textWidth) / 2
        }
        textStart = Self.moveIntoSafeArea(textStart, length: textWidth, extent: inlineExtent, inset: inlineSafeInset)

        var textTop: CGFloat
        switch cue.line {
        case let .fraction(fraction):
            let anchorPosition = (blockExtent * fraction).rounded()
            textTop = switch cue.lineAnchor {
            case .end: anchorPosition - textHeight
            case .middle: (anchorPosition * 2 - textHeight) / 2
            case .start, nil: anchorPosition
            }
        case let .number(number):
            let firstLineHeight = lines[0].height
            if number >= 0 {
                textTop = (CGFloat(number) * firstLineHeight).rounded()
            } else {
                textTop = (CGFloat(number + 1) * firstLineHeight).rounded() + blockExtent - textHeight
            }
        case nil:
            // Horizontal cues sit on the bottom of the safe area, vertical ones start from the edge their lines start
            // from.
            textTop = isVertical ? blockSafeInset : blockExtent - textHeight - blockSafeInset
        }
        textTop = Self.moveIntoSafeArea(textTop, length: textHeight, extent: blockExtent, inset: blockSafeInset)

        // Lay the lines out again in the final width, for the alignment within the cue box.
        lines = typeset(typesetter, length: cueText.length, width: textWidth - textPadding * 2)
        let isRightToLeft = lines.first.map(isRightToLeftLine) ?? false
        let windowColor = !style.overridesWindowColor ? cue.windowColor ?? style.windowColor : style.windowColor
        let box = CGRect(x: 0, y: 0, width: textWidth, height: Self.height(of: lines) + verticalPadding * 2)
        let placement = placement(of: cue, inlineStart: textStart, blockStart: textTop, box: box)

        // Mongolian lines follow each other left to right: the block turned for vertical text stacks them the other
        // way.
        let orderedLines = cue.verticalType == .leftToRight ? lines.reversed() : lines
        let lineOrigins = orderedLines.map { line in
            textPadding + lineOffset(
                line,
                in: box.width - textPadding * 2,
                alignment: cue.textAlignment ?? .center,
                isRightToLeft: isRightToLeft
            )
        }

        var window: CueWindow?
        if windowColor.alpha > 0 {
            // The window wraps the text, not the whole cue box: a cue as wide as the video keeps a window around its
            // words.
            let textMinX = lineOrigins.min() ?? textPadding
            let textMaxX = zip(orderedLines, lineOrigins).map { $1 + $0.width }.max() ?? box.width - textPadding
            let windowMinX = max(0, (textMinX - textPadding).rounded(.down))
            let windowMaxX = min(box.width, (textMaxX + textPadding).rounded(.up))
            let frame = CGRect(x: windowMinX, y: 0, width: windowMaxX - windowMinX, height: box.height)
            window = CueWindow(
                frame: frame,
                color: windowColor,
                cornerRadius: min(cornerRadius, frame.width / 2, frame.height / 2)
            )
        }

        // The text goes past the box with its edges and shadows. Its drawing sits on whole pixels of the screen, or
        // it would be resampled there and blur: the text moves within it by what the box is off them.
        let margin = (fontSize * Self.contentMarginRatio).rounded(.up)
        let start = CGPoint(x: -margin, y: -margin)
        let screenStart = start.applying(placement.transform)
        let pixelStart = CGPoint(
            x: (screenStart.x * scale).rounded() / scale,
            y: (screenStart.y * scale).rounded() / scale
        )
        let shift = CGPoint(x: pixelStart.x - screenStart.x, y: pixelStart.y - screenStart.y)
            .applying(placement.turn.inverted())
        let contentFrame = CGRect(
            x: start.x + shift.x,
            y: start.y + shift.y,
            width: box.width + margin * 2,
            height: box.height + margin * 2
        )
        let content = makeImage(size: contentFrame.size) { ctx in
            ctx.translateBy(x: margin - shift.x, y: margin - shift.y)
            var baseline = verticalPadding
            for (line, x) in zip(orderedLines, lineOrigins) {
                baseline += line.ascent
                draw(line, fontSize: fontSize, typesetter: typesetter, cueText: cueText, at: CGPoint(x: x, y: baseline), in: ctx)
                baseline += line.descent + line.leading
            }
        }

        return TextCueRendering(
            transform: placement.transform,
            boxSize: box.size,
            window: window,
            content: content,
            contentFrame: contentFrame
        )
    }

    /// A drawing of `size` points, laid out top down.
    private func makeImage(size: CGSize, drawing: (CGContext) -> Void) -> CGImage? {
        let width = Int((size.width * scale).rounded(.up))
        let height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB), let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        drawing(ctx)
        return ctx.makeImage()
    }

    /// The height of lines stacked: the space after the last one doesn't count, and the height is in whole points.
    private static func height(of lines: [TypesetLine]) -> CGFloat {
        (lines.reduce(0) { $0 + $1.height } - (lines.last?.leading ?? 0)).rounded(.up)
    }

    /// Where a box of `length` starting at `start` lands once moved into the safe area of `extent`: centered in the
    /// extent when it is wider than the safe area.
    private static func moveIntoSafeArea(_ start: CGFloat, length: CGFloat, extent: CGFloat, inset: CGFloat) -> CGFloat {
        guard length <= extent - inset * 2 else { return (extent - length) / 2 }
        return min(max(start, inset), extent - inset - length)
    }

    /// Where the cue box, laid out horizontally from the origin, goes in the bounds. Vertical cue boxes are turned a
    /// quarter clockwise, so their lines run down and follow each other leftwards.
    private func placement(of cue: Cue, inlineStart: CGFloat, blockStart: CGFloat, box: CGRect) -> CuePlacement {
        // A quarter turn, exactly: a rotation by an angle would be a little off one, and resampled.
        let quarterTurn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        return switch cue.verticalType {
        case nil:
            CuePlacement(origin: CGPoint(x: viewport.minX + inlineStart, y: viewport.minY + blockStart), turn: .identity)
        case .rightToLeft:
            CuePlacement(origin: CGPoint(x: viewport.maxX - blockStart, y: viewport.minY + inlineStart), turn: quarterTurn)
        case .leftToRight:
            CuePlacement(
                origin: CGPoint(x: viewport.minX + blockStart + box.height, y: viewport.minY + inlineStart),
                turn: quarterTurn
            )
        }
    }

    private func lineOffset(_ line: TypesetLine, in width: CGFloat, alignment: Cue.Alignment, isRightToLeft: Bool) -> CGFloat {
        let isLeft = switch alignment {
        case .leading: !isRightToLeft
        case .trailing: isRightToLeft
        case .center: false
        }
        let isRight = switch alignment {
        case .leading: isRightToLeft
        case .trailing: !isRightToLeft
        case .center: false
        }

        if isLeft { return 0 }
        if isRight { return width - line.width }
        return (width - line.width) / 2
    }

    private func isRightToLeftLine(_ line: TypesetLine) -> Bool {
        guard let run = (CTLineGetGlyphRuns(line.line) as? [CTRun])?.first else {
            return false
        }
        return CTRunGetStatus(run).contains(.rightToLeft)
    }

    private func draw(
        _ line: TypesetLine,
        fontSize: CGFloat,
        typesetter: CTTypesetter,
        cueText: NSAttributedString,
        at origin: CGPoint,
        in ctx: CGContext
    ) {
        drawBackgrounds(of: line, cueText: cueText, at: origin, in: ctx)

        // Shadows grow with the text, a third less for large text.
        let shadow = fontSize * Self.shadowRatio / (fontSize > Self.largeEdgeTextSize ? 1.5 : 1)
        switch style.edgeType {
        case .outline:
            // Draw the outline first, without the colors of the text, which would cover the edge. The stroke width is
            // a percentage of the font size.
            let outlineWidth = Self.outlineWidthRatio * (line.ascent + line.descent)
            let edgeText = NSMutableAttributedString(attributedString: cueText)
            let range = NSRange(location: 0, length: edgeText.length)
            edgeText.addAttributes([
                kCTForegroundColorAttributeName as NSAttributedString.Key: style.edgeColor,
                kCTStrokeColorAttributeName as NSAttributedString.Key: style.edgeColor,
                kCTStrokeWidthAttributeName as NSAttributedString.Key: outlineWidth * 100 / max(fontSize, 1),
            ], range: range)
            let edgeLine = CTTypesetterCreateLine(CTTypesetterCreateWithAttributedString(edgeText), line.range)
            drawLine(edgeLine, at: origin, in: ctx)
        case .dropShadow:
            ctx.setShadow(
                offset: shadowOffset(width: shadow, height: shadow, in: ctx),
                blur: shadow,
                color: style.edgeColor
            )
        case .raised, .depressed:
            let raised = style.edgeType == .raised
            let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            let colorUp = raised ? white : style.edgeColor
            let colorDown = raised ? style.edgeColor : white
            let offset = shadow / 2
            ctx.saveGState()
            ctx.setShadow(offset: shadowOffset(width: -offset, height: -offset, in: ctx), blur: shadow, color: colorUp)
            drawLine(line.line, at: origin, in: ctx)
            ctx.restoreGState()
            ctx.setShadow(offset: shadowOffset(width: offset, height: offset, in: ctx), blur: shadow, color: colorDown)
        case .none:
            break
        }

        drawLine(line.line, at: origin, in: ctx)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        drawStrikethroughs(of: line, cueText: cueText, at: origin, in: ctx)
    }

    /// A shadow offset given in the current coordinates: shadow offsets are in device space, whatever the transform of
    /// the context.
    private func shadowOffset(width: CGFloat, height: CGFloat, in ctx: CGContext) -> CGSize {
        let ctm = ctx.ctm
        return CGSize(width: width, height: height)
            .applying(CGAffineTransform(a: ctm.a, b: ctm.b, c: ctm.c, d: ctm.d, tx: 0, ty: 0))
    }

    /// Draws `line` with its baseline at `origin`, bottom up as Core Text expects: ruby and vertical forms go the right
    /// way.
    private func drawLine(_ line: CTLine, at origin: CGPoint, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private func drawBackgrounds(of line: TypesetLine, cueText: NSAttributedString, at origin: CGPoint, in ctx: CGContext) {
        cueText.enumerateAttribute(.subtitleBackgroundColor, in: line.nsRange) { value, range, _ in
            guard let value, CFGetTypeID(value as CFTypeRef) == CGColor.typeID else {
                return
            }
            let color = value as! CGColor
            guard color.alpha > 0 else { return }

            let (start, end) = offsets(of: range, in: line)
            ctx.setFillColor(color)
            ctx.fill(CGRect(
                x: origin.x + start,
                y: origin.y - line.ascent,
                width: end - start,
                height: line.ascent + line.descent
            ))
        }
    }

    private func drawStrikethroughs(of line: TypesetLine, cueText: NSAttributedString, at origin: CGPoint, in ctx: CGContext) {
        cueText.enumerateAttribute(.subtitleStrikethrough, in: line.nsRange) { value, range, _ in
            guard (value as? NSNumber)?.boolValue == true else { return }
            let font = cueText.attribute(kCTFontAttributeName as NSAttributedString.Key, at: range.location, effectiveRange: nil)
            guard let font, CFGetTypeID(font as CFTypeRef) == CTFontGetTypeID() else {
                return
            }
            let ctFont = font as! CTFont

            let (start, end) = offsets(of: range, in: line)
            let thickness = max(CTFontGetUnderlineThickness(ctFont), 1)
            let color = cueText.attribute(kCTForegroundColorAttributeName as NSAttributedString.Key, at: range.location, effectiveRange: nil)
            ctx.setFillColor((color.map { $0 as! CGColor }) ?? style.foregroundColor)
            ctx.fill(CGRect(
                x: origin.x + start,
                y: origin.y - CTFontGetXHeight(ctFont) / 2 - thickness / 2,
                width: end - start,
                height: thickness
            ))
        }
    }

    private func offsets(of range: NSRange, in line: TypesetLine) -> (CGFloat, CGFloat) {
        let start = CTLineGetOffsetForStringIndex(line.line, range.location, nil)
        let end = CTLineGetOffsetForStringIndex(line.line, NSMaxRange(range), nil)
        return (min(start, end), max(start, end))
    }

    // MARK: - Typesetting

    private struct TypesetLine {
        let line: CTLine
        let range: CFRange
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        let leading: CGFloat

        var height: CGFloat { ascent + descent + leading }
        var nsRange: NSRange { NSRange(location: range.location, length: range.length) }
    }

    private func typeset(_ typesetter: CTTypesetter, length: Int, width: CGFloat) -> [TypesetLine] {
        var lines: [TypesetLine] = []
        var start = 0
        while start < length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            guard count > 0 else { break }

            let range = CFRange(location: start, length: count)
            let line = CTTypesetterCreateLine(typesetter, range)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let lineWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading) - CTLineGetTrailingWhitespaceWidth(line)
            // The bounds leave out ruby: make room for it.
            let ruby = rubyExtent(of: line)
            ascent += ruby.before
            descent += ruby.after
            lines.append(TypesetLine(
                line: line,
                range: range,
                width: CGFloat(lineWidth),
                ascent: ascent,
                descent: descent,
                // Lines keep apart by a fifth of their height at least.
                leading: max(leading, (ascent + descent) * Self.lineSpacingRatio)
            ))
            start += count
        }
        return lines
    }

    /// How far ruby reaches before and after the line.
    private func rubyExtent(of line: CTLine) -> (before: CGFloat, after: CGFloat) {
        var before: CGFloat = 0
        var after: CGFloat = 0
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let position = attributes[NSAttributedString.Key.subtitleRubyPosition] as? NSNumber,
                  let fontValue = attributes[kCTFontAttributeName] else {
                continue
            }
            let font = fontValue as! CTFont
            let rubyFont = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * Self.rubySizeFactor, nil, nil)
            let height = CTFontGetAscent(rubyFont) + CTFontGetDescent(rubyFont)
            if position.uint8Value == CTRubyPosition.after.rawValue {
                after = max(after, height)
            } else {
                before = max(before, height)
            }
        }
        return (before, after)
    }

    /// The cue text with Core Text attributes: the styles of the cue, where they apply, over the caption style.
    private func makeTypesetText(_ text: AttributedString, fontSize: CGFloat, isVertical: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(string: String(text.characters))
        let applyEmbeddedStyles = applyEmbeddedStyles

        // Runs follow each other: each starts where the one before ended, counted in UTF-16 for Core Text.
        var location = 0
        for run in text.runs {
            let length = String(text[run.range].characters).utf16.count
            let range = NSRange(location: location, length: length)
            location += length

            var size = fontSize
            if applyEmbeddedFontSizes {
                if let absolute = run.cueAbsoluteFontSize {
                    size = absolute
                } else if let relative = run.cueRelativeFontSize {
                    size = fontSize * relative
                }
            }

            let family = applyEmbeddedStyles && !style.overridesFont ? run.cueFontFamily : nil
            var traits = CTFontSymbolicTraits()
            if applyEmbeddedStyles {
                if run.cueBold == true { traits.insert(.traitBold) }
                if run.cueItalic == true { traits.insert(.traitItalic) }
            }

            var resolved: [NSAttributedString.Key: Any] = [
                kCTFontAttributeName as NSAttributedString.Key: makeFont(family: family, size: size, traits: traits),
                kCTForegroundColorAttributeName as NSAttributedString.Key: style.foregroundColor,
                .subtitleBackgroundColor: style.backgroundColor,
            ]

            if applyEmbeddedStyles {
                if !style.overridesForegroundColor, let color = run.cueForegroundColor {
                    resolved[kCTForegroundColorAttributeName as NSAttributedString.Key] = color
                }
                if !style.overridesBackgroundColor, let color = run.cueBackgroundColor {
                    resolved[.subtitleBackgroundColor] = color
                }
                if run.cueUnderline == true {
                    resolved[kCTUnderlineStyleAttributeName as NSAttributedString.Key] =
                        NSNumber(value: CTUnderlineStyle.single.rawValue)
                }
                if run.cueStrikethrough == true {
                    resolved[.subtitleStrikethrough] = true
                }
                if let ruby = run.cueRuby {
                    resolved[kCTRubyAnnotationAttributeName as NSAttributedString.Key] = makeRubyAnnotation(ruby)
                    resolved[.subtitleRubyPosition] = NSNumber(value: (ruby.position == .after ? CTRubyPosition.after : .before).rawValue)
                }
                // TODO: Draw text emphasis marks, `.cueTextEmphasis`: Core Text has no attribute for them.
            }

            if isVertical {
                // TODO: Draw `.cueHorizontalInVertical` text across the line (tate-chu-yoko).
                let isHorizontal = applyEmbeddedStyles && run.cueHorizontalInVertical == true
                resolved[kCTVerticalFormsAttributeName as NSAttributedString.Key] = !isHorizontal
            }

            result.addAttributes(resolved, range: range)
        }

        return result
    }

    private func makeRubyAnnotation(_ ruby: Cue.Ruby) -> CTRubyAnnotation {
        let position: CTRubyPosition = ruby.position == .after ? .after : .before
        let annotation = CTRubyAnnotationCreateWithAttributes(.auto, .auto, position, ruby.text as CFString, [
            kCTRubyAnnotationSizeFactorAttributeName: Self.rubySizeFactor,
        ] as CFDictionary)
        return annotation
    }

    private func makeFont(family: String?, size: CGFloat, traits: CTFontSymbolicTraits) -> CTFont {
        let traits = traits.intersection([.traitBold, .traitItalic])
        return fonts.font(family: family, size: size, traits: traits) {
            makeUncachedFont(family: family, size: size, traits: traits)
        }
    }

    private func makeUncachedFont(family: String?, size: CGFloat, traits: CTFontSymbolicTraits) -> CTFont {
        let font: CTFont
        if let family {
            font = CTFontCreateWithName(Self.fontName(forFamily: family) as CFString, size, nil)
        } else if let descriptor = style.fontDescriptor {
            font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        } else {
            font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        }

        guard !traits.isEmpty else { return font }

        // Fonts named by the caption settings, such as `.SFUI-Medium`, stay themselves when copied with traits: match
        // their family by weight and slant instead.
        let fontTraits = CTFontCopyTraits(font) as NSDictionary
        let weight = traits.contains(.traitBold)
            ? max(Self.boldWeight, (fontTraits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0)
            : (fontTraits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: CTFontCopyFamilyName(font),
            kCTFontTraitsAttribute: [
                kCTFontWeightTrait: weight,
                kCTFontSymbolicTrait: traits.rawValue,
            ] as [CFString: Any],
        ] as CFDictionary)
        let matched = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        if CTFontGetSymbolicTraits(matched).contains(traits) {
            return matched
        }
        return CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, [.traitBold, .traitItalic]) ?? font
    }

    /// The font for a family a cue names: a generic family, as in CSS, or a font family.
    private static func fontName(forFamily family: String) -> String {
        switch family.lowercased() {
        case "serif": "Times New Roman"
        case "sans-serif", "sans_serif", "default": "Helvetica"
        case "monospace", "monospace-serif", "monospace-sans-serif": "Menlo"
        case "cursive": "Snell Roundhand"
        case "casual": "Chalkboard SE"
        case "small-capitals": "Copperplate"
        default: family
        }
    }
}

/// A cue laid out in the bounds of the subtitle layer, and drawn.
private enum CueRendering {
    case image(CGImage, frame: CGRect)
    case text(TextCueRendering)
}

/// Where the top left of a cue box goes, and how the box turns about it.
private struct CuePlacement {
    let origin: CGPoint
    let turn: CGAffineTransform

    /// From the box to the bounds of the subtitle layer.
    var transform: CGAffineTransform {
        turn.concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
    }
}

private struct TextCueRendering {
    /// From the cue box to the bounds of the subtitle layer.
    let transform: CGAffineTransform
    let boxSize: CGSize
    /// The window behind the text, in the box.
    let window: CueWindow?
    /// The text, in `contentFrame` of the box.
    let content: CGImage?
    let contentFrame: CGRect
}

private struct CueWindow {
    let frame: CGRect
    let color: CGColor
    let cornerRadius: CGFloat
}

/// Shows one cue: its window, a rounded rectangle Core Animation draws, and its text or image above it.
private final class CueLayer: StillLayer {
    /// The cue shown, drawn in ``generation`` of the subtitle layer.
    private(set) var cue: Cue?
    private(set) var generation = 0

    private let windowLayer = StillLayer()
    private let contentLayer = StillLayer()

    override init() {
        super.init()
        anchorPoint = .zero
        addSublayer(windowLayer)
        addSublayer(contentLayer)
    }

    /// Core Animation's copies, such as the presentation layer.
    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func show(_ cue: Cue, _ rendering: CueRendering?, generation: Int, scale: CGFloat) {
        self.cue = cue
        self.generation = generation
        contentLayer.contentsScale = scale

        switch rendering {
        case let .image(image, frame):
            setAffineTransform(.identity)
            bounds = CGRect(origin: .zero, size: frame.size)
            position = frame.origin
            windowLayer.isHidden = true
            contentLayer.frame = bounds
            contentLayer.contents = image
        case let .text(text):
            // The layer turns about its origin, the anchor point.
            setAffineTransform(CGAffineTransform(
                a: text.transform.a, b: text.transform.b, c: text.transform.c, d: text.transform.d, tx: 0, ty: 0
            ))
            bounds = CGRect(origin: .zero, size: text.boxSize)
            position = CGPoint(x: text.transform.tx, y: text.transform.ty)
            if let window = text.window {
                windowLayer.isHidden = false
                windowLayer.frame = window.frame
                windowLayer.backgroundColor = window.color
                windowLayer.cornerRadius = window.cornerRadius
            } else {
                windowLayer.isHidden = true
            }
            contentLayer.frame = text.contentFrame
            contentLayer.contents = text.content
        case nil:
            windowLayer.isHidden = true
            contentLayer.contents = nil
        }
    }
}

/// A layer that changes at once, without the animations Core Animation gives its properties.
private class StillLayer: CALayer {
    override func action(forKey event: String) -> CAAction? {
        NSNull()
    }
}

/// The fonts of the cues, made once for each family, size and traits.
private final class FontCache {
    private struct Key: Hashable {
        let family: String?
        let size: CGFloat
        let traits: UInt32
    }

    /// Sizes follow the size of the picture: the fonts of earlier sizes go once there are this many.
    private static let capacity = 64
    private var fonts: [Key: CTFont] = [:]

    func font(family: String?, size: CGFloat, traits: CTFontSymbolicTraits, make: () -> CTFont) -> CTFont {
        let key = Key(family: family, size: size, traits: traits.rawValue)
        if let font = fonts[key] { return font }
        if fonts.count >= Self.capacity { fonts.removeAll() }
        let font = make()
        fonts[key] = font
        return font
    }

    func removeAll() {
        fonts.removeAll()
    }
}

private extension NSAttributedString.Key {
    /// `CGColor`: the background the layer draws itself, as Core Text doesn't draw `kCTBackgroundColorAttributeName`
    /// everywhere.
    static let subtitleBackgroundColor = NSAttributedString.Key("SEPlayerSubtitleBackgroundColor")

    /// `NSNumber` of a `CTRubyPosition` raw value: where the ruby of the text goes, as an annotation doesn't tell.
    static let subtitleRubyPosition = NSAttributedString.Key("SEPlayerSubtitleRubyPosition")

    /// `Bool`: the layer strikes the text through itself, as Core Text has no attribute for it.
    static let subtitleStrikethrough = NSAttributedString.Key("SEPlayerSubtitleStrikethrough")
}
