//
//  DebugTimelineView.swift
//  DemoApp
//

import CoreMedia
import SEPlayer
import UIKit

/// What the timeline bar draws, read from the player at once.
struct DebugTimelineSnapshot {
    struct PeriodInfo {
        let index: Int
        let duration: CMTime
        let positionInWindow: CMTime
        let isPlaceholder: Bool
    }

    struct WindowInfo {
        let index: Int
        let title: String
        let duration: CMTime
        let defaultPosition: CMTime
        let isSeekable: Bool
        let isDynamic: Bool
        let isLive: Bool
        let isPlaceholder: Bool
        let periods: [PeriodInfo]
    }

    var windows: [WindowInfo] = []
    var currentWindowIndex: Int?
    var currentPeriodIndex: Int?
    /// In the current window.
    var position: CMTime = .invalid
    /// In the current window.
    var bufferedPosition: CMTime = .invalid
    /// All that is buffered ahead of the position, also in the next windows.
    var totalBufferedDuration: CMTime = .zero

    init() {}

    init(player: SEPlayer) {
        let snapshot = player.snapshot
        let timeline = snapshot.timeline
        let window = Window()
        let period = Period()
        for windowIndex in 0 ..< timeline.windowCount() {
            timeline.getWindow(windowIndex: windowIndex, window: window, defaultPositionProjection: .zero)
            var periods = [PeriodInfo]()
            if window.lastPeriodIndex >= window.firstPeriodIndex {
                for periodIndex in window.firstPeriodIndex ... window.lastPeriodIndex {
                    timeline.getPeriod(periodIndex: periodIndex, period: period, setIds: false)
                    periods.append(PeriodInfo(
                        index: periodIndex,
                        duration: period.duration,
                        positionInWindow: period.positionInWindow,
                        isPlaceholder: period.isPlaceholder
                    ))
                }
            }
            windows.append(WindowInfo(
                index: windowIndex,
                title: DebugFormat.host(of: window.mediaItem),
                duration: window.duration,
                defaultPosition: window.defaultPosition,
                isSeekable: window.isSeekable,
                isDynamic: window.isDynamic,
                isLive: window.isLive,
                isPlaceholder: window.isPlaceholder,
                periods: periods
            ))
        }
        if !windows.isEmpty {
            currentWindowIndex = snapshot.currentMediaItemIndex
            currentPeriodIndex = snapshot.currentPeriodIndex
        }
        position = player.currentPosition
        bufferedPosition = player.bufferedPosition
        totalBufferedDuration = player.totalBufferedDuration
    }
}

/// A horizontally scrolling bar of the windows of the timeline, each with its periods, the played and buffered
/// parts, the playhead and the default position. Tapping a period reports it; pinching zooms the windows.
final class DebugTimelineView: UIView, UIScrollViewDelegate {
    static var height: CGFloat { Canvas.height }

    /// Called with the window and period index tapped.
    var onSelectPeriod: ((Int, Int?) -> Void)?

    private let scrollView = UIScrollView()
    private let canvas = Canvas()
    private var snapshot = DebugTimelineSnapshot()
    private var zoom: CGFloat = 1
    private var pinchStartZoom: CGFloat = 1
    private var lastCurrentWindowIndex: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.45)
        layer.cornerRadius = 6
        clipsToBounds = true

        scrollView.showsHorizontalScrollIndicator = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.delegate = self
        addSubview(scrollView)
        scrollView.addSubview(canvas)
        canvas.backgroundColor = .clear

        canvas.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTap)))
        #if !os(tvOS)
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(didPinch)))
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Canvas.height) }

    func update(_ snapshot: DebugTimelineSnapshot) {
        self.snapshot = snapshot
        canvas.snapshot = snapshot
        layoutCanvas()
        canvas.setNeedsDisplay()
        // Follow the playing window, unless it is the one in view already.
        if snapshot.currentWindowIndex != lastCurrentWindowIndex {
            lastCurrentWindowIndex = snapshot.currentWindowIndex
            scrollToCurrentWindow(animated: true)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        layoutCanvas()
    }

    private func layoutCanvas() {
        canvas.windowWidth = max(160, (bounds.width - 2 * Canvas.inset) * 0.86 * zoom)
        let width = canvas.contentWidth(windowCount: snapshot.windows.count, minimum: bounds.width)
        canvas.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        scrollView.contentSize = canvas.frame.size
    }

    private func scrollToCurrentWindow(animated: Bool) {
        guard let index = snapshot.currentWindowIndex, !scrollView.isTracking else {
            return
        }
        let frame = canvas.windowFrame(at: index)
        let x = min(max(0, frame.minX - Canvas.inset), max(0, scrollView.contentSize.width - scrollView.bounds.width))
        scrollView.setContentOffset(CGPoint(x: x, y: 0), animated: animated)
    }

    @objc
    private func didTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: canvas)
        guard let (windowIndex, periodIndex) = canvas.periodAt(point) else {
            return
        }
        onSelectPeriod?(windowIndex, periodIndex)
    }

    #if !os(tvOS)
    @objc
    private func didPinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pinchStartZoom = zoom
        case .changed:
            // Keep the point under the fingers in place.
            let anchor = recognizer.location(in: canvas).x
            let oldWidth = canvas.bounds.width
            zoom = min(max(pinchStartZoom * recognizer.scale, 0.3), 40)
            layoutCanvas()
            canvas.setNeedsDisplay()
            let ratio = canvas.bounds.width / max(oldWidth, 1)
            let offset = scrollView.contentOffset.x + anchor * (ratio - 1)
            scrollView.contentOffset.x = min(max(0, offset), max(0, scrollView.contentSize.width - scrollView.bounds.width))
        default:
            break
        }
    }
    #endif
}

// MARK: - Drawing

private final class Canvas: UIView {
    static let height: CGFloat = 50
    static let inset: CGFloat = 8
    static let gap: CGFloat = 10
    private static let barY: CGFloat = 16
    private static let barHeight: CGFloat = 16

    var snapshot = DebugTimelineSnapshot()
    var windowWidth: CGFloat = 240

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func contentWidth(windowCount: Int, minimum: CGFloat) -> CGFloat {
        guard windowCount > 0 else { return minimum }
        let width = 2 * Self.inset + CGFloat(windowCount) * windowWidth + CGFloat(windowCount - 1) * Self.gap
        return max(width, minimum)
    }

    func windowFrame(at index: Int) -> CGRect {
        CGRect(x: Self.inset + CGFloat(index) * (windowWidth + Self.gap), y: 0, width: windowWidth, height: Self.height)
    }

    func periodAt(_ point: CGPoint) -> (Int, Int?)? {
        for window in snapshot.windows {
            let frame = windowFrame(at: window.index)
            guard frame.minX ... frame.maxX ~= point.x else { continue }
            let period = window.periods.first { period in
                let range = periodRange(period, in: window, frame: frame)
                return range.contains(point.x)
            }
            return (window.index, period?.index ?? window.periods.first?.index)
        }
        return nil
    }

    // MARK: Geometry

    /// The x of `time` in a window; a window of unknown duration is drawn with a nominal length.
    private func x(for time: CMTime, in window: DebugTimelineSnapshot.WindowInfo, frame: CGRect) -> CGFloat {
        guard time.isNumeric else { return frame.minX }
        let length = displayDuration(window)
        let fraction = length > 0 ? min(max(time.seconds / length, 0), 1) : 0
        return frame.minX + frame.width * fraction
    }

    private func displayDuration(_ window: DebugTimelineSnapshot.WindowInfo) -> Double {
        if window.duration.isNumeric, window.duration.seconds > 0 { return window.duration.seconds }
        // Unknown: as long as what is known to be in it.
        let known = window.periods.map { $0.positionInWindow.seconds + ($0.duration.isNumeric ? $0.duration.seconds : 0) }
        return max(known.max() ?? 0, 1)
    }

    private func periodRange(
        _ period: DebugTimelineSnapshot.PeriodInfo,
        in window: DebugTimelineSnapshot.WindowInfo,
        frame: CGRect
    ) -> ClosedRange<CGFloat> {
        let start = x(for: max(period.positionInWindow, .zero), in: window, frame: frame)
        let end = period.duration.isNumeric
            ? x(for: period.positionInWindow + period.duration, in: window, frame: frame)
            : frame.maxX
        return start ... max(start, end)
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        if snapshot.windows.isEmpty {
            draw("Empty timeline", at: CGPoint(x: Self.inset, y: Self.barY), font: DebugFormat.font, color: .secondaryLabel)
            return
        }

        // What is buffered past the end of the current window, carried into the next ones.
        var carriedBuffer: Double = 0
        if let current = snapshot.currentWindowIndex, snapshot.windows.indices.contains(current),
           snapshot.totalBufferedDuration.isNumeric, snapshot.position.isNumeric, snapshot.bufferedPosition.isNumeric {
            let inCurrent = max(0, snapshot.bufferedPosition.seconds - snapshot.position.seconds)
            carriedBuffer = max(0, snapshot.totalBufferedDuration.seconds - inCurrent)
        }

        for window in snapshot.windows {
            let frame = windowFrame(at: window.index)
            guard frame.intersects(rect.insetBy(dx: -40, dy: 0)) else {
                continue
            }
            var buffered: ClosedRange<Double>?
            if window.index == snapshot.currentWindowIndex {
                if snapshot.position.isNumeric, snapshot.bufferedPosition.isNumeric {
                    buffered = snapshot.position.seconds ... max(snapshot.position.seconds, snapshot.bufferedPosition.seconds)
                }
            } else if let current = snapshot.currentWindowIndex, window.index > current, carriedBuffer > 0 {
                let length = displayDuration(window)
                buffered = 0 ... min(carriedBuffer, length)
                carriedBuffer -= min(carriedBuffer, length)
            }
            drawWindow(window, frame: frame, buffered: buffered, in: context)
        }
    }

    private func drawWindow(
        _ window: DebugTimelineSnapshot.WindowInfo,
        frame: CGRect,
        buffered: ClosedRange<Double>?,
        in context: CGContext
    ) {
        let isCurrent = window.index == snapshot.currentWindowIndex
        let bar = CGRect(x: frame.minX, y: Self.barY, width: frame.width, height: Self.barHeight)

        // Title and flags.
        var flags = [String]()
        if window.isLive { flags.append("LIVE") } else if window.isDynamic { flags.append("DYN") }
        if !window.isSeekable { flags.append("NO SEEK") }
        if window.isPlaceholder { flags.append("PLACEHOLDER") }
        let flagsText = flags.joined(separator: " · ")
        let flagsWidth = flags.isEmpty ? 0 : size(of: flagsText, font: DebugFormat.smallBoldFont).width + 6
        draw("W\(window.index)  \(window.title)", at: CGPoint(x: frame.minX, y: 2), font: DebugFormat.smallBoldFont,
             color: isCurrent ? .label : .secondaryLabel, maxWidth: frame.width - flagsWidth)
        if !flags.isEmpty {
            draw(flagsText, at: CGPoint(x: frame.maxX - flagsWidth + 6, y: 2), font: DebugFormat.smallBoldFont,
                 color: .systemOrange)
        }

        // The window.
        let barPath = UIBezierPath(roundedRect: bar, cornerRadius: 4)
        #if os(tvOS)
        (window.isPlaceholder ? UIColor.darkGray : UIColor.gray).setFill()
        #else
        (window.isPlaceholder ? UIColor.systemGray5 : UIColor.systemGray4).setFill()
        #endif
        barPath.fill()
        context.saveGState()
        barPath.addClip()

        if let buffered {
            let start = x(for: CMTime(seconds: buffered.lowerBound, preferredTimescale: 1000), in: window, frame: frame)
            let end = x(for: CMTime(seconds: buffered.upperBound, preferredTimescale: 1000), in: window, frame: frame)
            UIColor.systemTeal.withAlphaComponent(0.45).setFill()
            context.fill(CGRect(x: start, y: bar.minY, width: max(0, end - start), height: bar.height))
        }
        if isCurrent, snapshot.position.isNumeric {
            let end = x(for: snapshot.position, in: window, frame: frame)
            UIColor.systemBlue.withAlphaComponent(0.55).setFill()
            context.fill(CGRect(x: bar.minX, y: bar.minY, width: end - bar.minX, height: bar.height))
        } else if let current = snapshot.currentWindowIndex, window.index < current {
            UIColor.systemBlue.withAlphaComponent(0.25).setFill()
            context.fill(bar)
        }

        // Periods.
        for (offset, period) in window.periods.enumerated() {
            let range = periodRange(period, in: window, frame: frame)
            let isCurrentPeriod = period.index == snapshot.currentPeriodIndex
            if isCurrentPeriod {
                UIColor.systemYellow.setStroke()
                let outline = UIBezierPath(rect: CGRect(x: range.lowerBound, y: bar.minY, width: range.upperBound - range.lowerBound,
                                                        height: bar.height).insetBy(dx: 1, dy: 1))
                outline.lineWidth = 2
                outline.stroke()
            }
            if offset > 0 {
                UIColor.label.withAlphaComponent(0.6).setFill()
                context.fill(CGRect(x: range.lowerBound - 0.5, y: bar.minY, width: 1, height: bar.height))
            }
            if range.upperBound - range.lowerBound > 18 {
                draw("P\(period.index)", at: CGPoint(x: range.lowerBound + 3, y: bar.minY + 2), font: DebugFormat.smallFont,
                     color: .label, maxWidth: range.upperBound - range.lowerBound - 4)
            }
        }
        context.restoreGState()

        // Default position.
        if window.defaultPosition.isNumeric {
            let dx = x(for: window.defaultPosition, in: window, frame: frame)
            let diamond = UIBezierPath()
            let cy = bar.maxY
            diamond.move(to: CGPoint(x: dx, y: cy - 4))
            diamond.addLine(to: CGPoint(x: dx + 4, y: cy))
            diamond.addLine(to: CGPoint(x: dx, y: cy + 4))
            diamond.addLine(to: CGPoint(x: dx - 4, y: cy))
            diamond.close()
            UIColor.systemPink.setFill()
            diamond.fill()
        }

        // Playhead.
        if isCurrent, snapshot.position.isNumeric {
            let px = x(for: snapshot.position, in: window, frame: frame)
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: px - 1, y: bar.minY - 3, width: 2, height: bar.height + 6))
        }

        // Start, duration and the current values.
        let labelsY = bar.maxY + 4
        draw("0:00", at: CGPoint(x: frame.minX, y: labelsY), font: DebugFormat.smallFont, color: .secondaryLabel)
        let durationText = DebugFormat.time(window.duration, millis: false)
        let durationSize = size(of: durationText, font: DebugFormat.smallFont)
        draw(durationText, at: CGPoint(x: frame.maxX - durationSize.width, y: labelsY), font: DebugFormat.smallFont,
             color: .secondaryLabel)

        var details = ["def \(DebugFormat.time(window.defaultPosition, millis: false))", "\(window.periods.count)P"]
        if isCurrent {
            details.insert("pos \(DebugFormat.time(snapshot.position))", at: 0)
            if let buffered { details.insert("buf +\(String(format: "%.1fs", buffered.upperBound - buffered.lowerBound))", at: 1) }
        } else if let buffered {
            details.insert("buf \(String(format: "%.1fs", buffered.upperBound - buffered.lowerBound))", at: 0)
        }
        let detailsText = details.joined(separator: "  ")
        let detailsSize = size(of: detailsText, font: DebugFormat.smallFont)
        // Between the start and the end labels, truncated when it doesn't fit.
        let room = frame.width - 2 * max(durationSize.width, 26) - 8
        if room > 30 {
            let width = min(detailsSize.width, room)
            draw(detailsText, at: CGPoint(x: frame.midX - width / 2, y: labelsY), font: DebugFormat.smallFont,
                 color: isCurrent ? .label : .secondaryLabel, maxWidth: width + 1)
        }
    }

    private func draw(_ text: String, at point: CGPoint, font: UIFont, color: UIColor, maxWidth: CGFloat? = nil) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let maxWidth {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            var truncating = attributes
            truncating[.paragraphStyle] = style
            (text as NSString).draw(in: CGRect(x: point.x, y: point.y, width: maxWidth, height: font.lineHeight + 2),
                                    withAttributes: truncating)
        } else {
            (text as NSString).draw(at: point, withAttributes: attributes)
        }
    }

    private func size(of text: String, font: UIFont) -> CGSize {
        (text as NSString).size(withAttributes: [.font: font])
    }
}
