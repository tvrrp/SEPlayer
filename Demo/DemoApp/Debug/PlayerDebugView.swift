//
//  PlayerDebugView.swift
//  DemoApp
//

import CoreMedia
import SEPlayer
import UIKit

/// A debug overlay for an ``SEPlayer``, drawn over the video.
///
/// Always shown: the state, the position against the duration and the buffer, the bandwidth with its recent history,
/// the selected video and audio, the last error, and the timeline bar. Behind the section buttons: the playback
/// settings with controls for them, all the tracks, the track selection parameters, and the recent player events.
/// Tapping a period on the timeline opens everything about it.
///
/// Only the buttons, the timeline and an open section take touches; elsewhere they go through to the player.
final class PlayerDebugView: UIView {
    private enum Section: Int, CaseIterable {
        case playback
        case tracks
        case parameters
        case events

        var title: String {
            switch self {
            case .playback: "Playback"
            case .tracks: "Tracks"
            case .parameters: "Params"
            case .events: "Events"
            }
        }
    }

    private static let spacing: CGFloat = 4
    private static let graphSize = CGSize(width: 112, height: 34)
    private static let buttonHeight: CGFloat = 22
    /// Below this, an open section takes the place of the timeline.
    private static let minimumSectionHeight: CGFloat = 90
    private static let backdrop = UIColor.black.withAlphaComponent(0.45)

    private let player: SEPlayer
    private let summaryLabel = PaddedLabel()
    private let bandwidthGraph = BandwidthGraphView()
    private let timelineView = DebugTimelineView()
    private var sectionButtons: [UIButton] = []
    private let controlsStack = UIStackView()
    private let repeatButton = UIButton(type: .system)
    private let shuffleButton = UIButton(type: .system)
    private let speedButton = UIButton(type: .system)
    private let sectionView = UITextView()

    private var openSection: Section?
    private var refreshTimer: Timer?
    private var events: [(Date, String)] = []
    private var lastError: (Date, String)?
    private static let eventTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    init(player: SEPlayer) {
        self.player = player
        super.init(frame: .zero)
        // Over the video, whatever the appearance of the app.
        overrideUserInterfaceStyle = .dark
        setUpViews()
        player.delegate.addDelegate(self)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The overlay refreshes while it is on screen.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard window != nil else { return }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isHidden else { return }
                self.refresh()
            }
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        return view === self ? nil : view
    }

    // MARK: - Layout

    private func setUpViews() {
        summaryLabel.numberOfLines = 0
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.backgroundColor = Self.backdrop
        summaryLabel.layer.cornerRadius = 6
        summaryLabel.clipsToBounds = true
        addSubview(summaryLabel)

        bandwidthGraph.isUserInteractionEnabled = false
        addSubview(bandwidthGraph)

        timelineView.onSelectPeriod = { [weak self] windowIndex, periodIndex in
            self?.showPeriod(windowIndex: windowIndex, periodIndex: periodIndex)
        }
        addSubview(timelineView)

        for section in Section.allCases {
            let button = UIButton(type: .system)
            button.setTitle(section.title, for: .normal)
            Self.style(button)
            button.addAction(UIAction { [weak self] _ in self?.toggle(section) }, for: .primaryActionTriggered)
            sectionButtons.append(button)
            addSubview(button)
        }

        controlsStack.axis = .horizontal
        controlsStack.spacing = Self.spacing
        controlsStack.distribution = .fillEqually
        for button in [repeatButton, shuffleButton, speedButton] {
            Self.style(button)
            controlsStack.addArrangedSubview(button)
        }
        repeatButton.addAction(UIAction { [weak self] _ in self?.cycleRepeatMode() }, for: .primaryActionTriggered)
        shuffleButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            player.shuffleModeEnabled.toggle()
            refreshSection()
        }, for: .primaryActionTriggered)
        speedButton.showsMenuAsPrimaryAction = true
        speedButton.menu = UIMenu(children: [0.5, 1, 1.25, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5].map { (speed: Float) in
            UIAction(title: "\(speed)×") { [weak self] _ in self?.player.setPlaybackSpeed(new: speed) }
        })
        controlsStack.isHidden = true
        addSubview(controlsStack)

        #if !os(tvOS)
        sectionView.isEditable = false
        #endif
        sectionView.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        sectionView.layer.cornerRadius = 6
        sectionView.textContainerInset = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        sectionView.indicatorStyle = .white
        sectionView.isHidden = true
        addSubview(sectionView)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = bounds.inset(by: safeAreaInsets).insetBy(dx: 6, dy: 6)
        guard area.width > 0, area.height > 0 else { return }
        let spacing = Self.spacing

        // The values, with the bandwidth graph on their right and the section buttons under it.
        let graphFrame = CGRect(x: area.maxX - Self.graphSize.width, y: area.minY,
                                width: Self.graphSize.width, height: Self.graphSize.height)
        bandwidthGraph.frame = graphFrame
        let summaryWidth = graphFrame.minX - spacing - area.minX
        let summaryHeight = min(summaryLabel.sizeThatFits(CGSize(width: summaryWidth, height: .greatestFiniteMagnitude)).height,
                                area.height)
        summaryLabel.frame = CGRect(x: area.minX, y: area.minY, width: summaryWidth, height: summaryHeight)

        let buttonsY = graphFrame.maxY + spacing
        let buttonWidth = (Self.graphSize.width - spacing) / 2
        for (index, button) in sectionButtons.enumerated() {
            button.frame = CGRect(x: graphFrame.minX + CGFloat(index % 2) * (buttonWidth + spacing),
                                  y: buttonsY + CGFloat(index / 2) * (Self.buttonHeight + spacing),
                                  width: buttonWidth, height: Self.buttonHeight)
        }
        let buttonsBottom = sectionButtons.last?.frame.maxY ?? buttonsY

        var y = max(summaryLabel.frame.maxY, buttonsBottom) + spacing
        let timelineHeight = DebugTimelineView.height
        let sectionFitsBelowTimeline = area.maxY - (y + timelineHeight + spacing) >= Self.minimumSectionHeight
        timelineView.isHidden = openSection != nil && !sectionFitsBelowTimeline
        if !timelineView.isHidden {
            timelineView.frame = CGRect(x: area.minX, y: y, width: area.width, height: timelineHeight)
            y = timelineView.frame.maxY + spacing
        }

        if openSection == .playback {
            controlsStack.frame = CGRect(x: area.minX, y: y, width: area.width, height: Self.buttonHeight)
            y = controlsStack.frame.maxY + spacing
        }
        sectionView.frame = CGRect(x: area.minX, y: y, width: area.width, height: max(0, area.maxY - y))
    }

    private static func style(_ button: UIButton) {
        button.titleLabel?.font = DebugFormat.smallBoldFont
        button.tintColor = .white
        button.backgroundColor = backdrop
        button.layer.cornerRadius = 5
    }

    // MARK: - Refresh

    private func refresh() {
        let snapshot = DebugTimelineSnapshot(player: player)
        summaryLabel.attributedText = makeSummary(snapshot: snapshot)
        bandwidthGraph.add(estimate: player.bandwidthMeter.getBitrateEstimate(),
                           prediction: player.bandwidthMeter.predict()?.bitrate,
                           selected: selectedBitrate(of: .video).map { $0 + (selectedBitrate(of: .audio) ?? 0) })
        timelineView.update(snapshot)
        refreshSection()
        setNeedsLayout()
    }

    private func makeSummary(snapshot: DebugTimelineSnapshot) -> NSAttributedString {
        var text = DebugText()
        text.keyWidth = 6
        text.font = DebugFormat.hudFont
        text.boldFont = DebugFormat.hudBoldFont

        let state = player.playbackState
        let result = NSMutableAttributedString(string: " \(state.description.uppercased()) ", attributes: [
            .font: DebugFormat.hudBoldFont, .foregroundColor: UIColor.white,
            .backgroundColor: DebugFormat.stateColor(state),
        ])
        var flags = [player.isPlaying ? "▶︎" : "❚❚", "pwr \(player.playWhenReady)"]
        if player.isLoading { flags.append("loading") }
        flags.append("\(player.playbackParameters.playbackRate)×")
        let itemCount = player.numberOfMediaItemsInPlaylist
        if itemCount > 1 { flags.append("item \(player.currentMediaItemIndex + 1)/\(itemCount)") }
        if let period = snapshot.currentPeriodIndex { flags.append("P\(period)") }
        result.append(NSAttributedString(string: " " + flags.joined(separator: " · ") + "\n", attributes: [
            .font: DebugFormat.hudFont, .foregroundColor: UIColor.white,
        ]))

        let duration = player.duration
        let position = snapshot.position
        var positionText = "\(DebugFormat.time(position)) / \(DebugFormat.time(duration))"
        if position.isNumeric, duration.isNumeric, duration.seconds > 0 {
            positionText += String(format: " %.1f%%", position.seconds / duration.seconds * 100)
        }
        text.row("pos", positionText)
        let ahead = snapshot.bufferedPosition.isNumeric && position.isNumeric
            ? snapshot.bufferedPosition - position : .invalid
        text.row("buf", "\(DebugFormat.time(snapshot.bufferedPosition, millis: false)) +\(DebugFormat.seconds(ahead)) "
            + "total \(DebugFormat.seconds(snapshot.totalBufferedDuration)) \(player.bufferedPercentage)%")

        let meter = player.bandwidthMeter
        var bandwidth = "safe \(DebugFormat.bitrate(meter.getBitrateEstimate()))"
        if let prediction = meter.predict() {
            bandwidth += " pred \(DebugFormat.bitrate(prediction.bitrate))"
            bandwidth += String(format: " ×%.2f", prediction.safetyMultiplier)
        } else {
            bandwidth += " (initial)"
        }
        text.row("bw", bandwidth, color: .systemTeal)

        text.row("video", selectionSummary(of: .video))
        text.row("audio", selectionSummary(of: .audio))
        if player.currentTracks.containsType(.text) { text.row("text", selectionSummary(of: .text)) }

        if let (date, event) = events.last {
            text.row("event", "\(Self.eventTimeFormatter.string(from: date)) \(event)", color: .secondaryLabel)
        }
        if let (date, error) = lastError {
            text.row("error", "\(Self.eventTimeFormatter.string(from: date)) \(error)", color: .systemRed)
        }

        result.append(text.text)
        return result
    }

    private func playingFormat(of type: TrackType) -> AnyFormat? {
        switch type {
        case .video: player.videoFormat
        case .audio: player.audioFormat
        default: nil
        }
    }

    /// The track that plays, or the selected ones: the format of a single one, or the range of an adaptive selection.
    private func selectionSummary(of type: TrackType) -> String {
        let selected = selectedFormats(of: type)
        if let playing = playingFormat(of: type) {
            let summary = "▶ " + DebugFormat.formatSummary(playing, type: type)
            return selected.count > 1 ? summary + " · of \(selected.count)" : summary
        }
        guard let first = selected.first else {
            return player.currentTracks.containsType(type) ? "off" : "—"
        }
        if selected.count == 1 { return DebugFormat.formatSummary(first, type: type) }
        let bitrates = selected.map(\.bitrateValue).filter { $0 > 0 }
        let heights = selected.map(\.height).filter { $0 > 0 }
        var parts = ["adaptive \(selected.count)"]
        if let low = heights.min(), let high = heights.max() { parts.append("\(low)p…\(high)p") }
        if let low = bitrates.min(), let high = bitrates.max() {
            parts.append("\(DebugFormat.shortBitrate(low))…\(DebugFormat.shortBitrate(high))")
        }
        return parts.joined(separator: " · ")
    }

    private func selectedFormats(of type: TrackType) -> [AnyFormat] {
        player.currentTracks.groups.filter { $0.type == type && $0.isSelected }.flatMap { group in
            (0 ..< group.length).filter { group.isTrackSelected(for: $0) }.map { group.format(trackIndex: $0) }
        }
    }

    /// The bitrate of a single selected track, which the graph compares with the bandwidth.
    private func selectedBitrate(of type: TrackType) -> Int? {
        let selected = selectedFormats(of: type)
        guard selected.count == 1, selected[0].bitrateValue > 0 else {
            return nil
        }
        return selected[0].bitrateValue
    }

    // MARK: - Sections

    private func toggle(_ section: Section) {
        openSection = openSection == section ? nil : section
        for (index, button) in sectionButtons.enumerated() {
            let isOpen = index == openSection?.rawValue
            button.backgroundColor = isOpen ? UIColor.systemTeal.withAlphaComponent(0.7) : Self.backdrop
        }
        controlsStack.isHidden = openSection != .playback
        sectionView.isHidden = openSection == nil
        sectionView.contentOffset = .zero
        refreshSection()
        setNeedsLayout()
    }

    private func refreshSection() {
        guard let openSection else { return }
        var text = DebugText()
        switch openSection {
        case .playback:
            updateControls()
            appendPlayback(to: &text)
        case .tracks:
            appendTracks(to: &text)
        case .parameters:
            let parameters = player.trackSelectionParameters
            text.header("Track selection parameters")
            text.line(String(describing: type(of: parameters)), color: .secondaryLabel)
            text.keyWidth = 0
            for (key, value) in DebugFormat.properties(of: parameters) {
                text.row(key, value, color: value == "—" || value == "∞" ? .secondaryLabel : .label)
            }
        case .events:
            text.header("Recent events")
            if events.isEmpty { text.line("None yet.", color: .secondaryLabel) }
            for (date, event) in events.reversed() {
                text.row(Self.eventTimeFormatter.string(from: date), event)
            }
        }
        // Keep the place the reader scrolled to.
        let offset = sectionView.contentOffset
        sectionView.attributedText = text.text
        sectionView.contentOffset = offset
    }

    private func updateControls() {
        repeatButton.setTitle("Repeat \(player.repeatMode)", for: .normal)
        shuffleButton.setTitle("Shuffle \(player.shuffleModeEnabled ? "on" : "off")", for: .normal)
        speedButton.setTitle("Speed \(player.playbackParameters.playbackRate)×", for: .normal)
    }

    private func cycleRepeatMode() {
        player.repeatMode = switch player.repeatMode {
        case .off: .one
        case .one: .all
        case .all: .off
        }
        refreshSection()
    }

    private func appendPlayback(to text: inout DebugText) {
        text.header("Playback")
        text.row("state", player.playbackState.description.uppercased())
        text.row("play when ready", "\(player.playWhenReady)")
        text.row("is playing", "\(player.isPlaying)")
        text.row("is loading", "\(player.isLoading)")
        text.row("repeat", player.repeatMode.description)
        text.row("shuffle", "\(player.shuffleModeEnabled)")
        text.row("speed", "\(player.playbackParameters.playbackRate)")
        text.row("pitch", "\(player.playbackParameters.pitch)")
        text.row("volume", String(format: "%.2f", player.volume))
        text.row("muted", "\(player.isMuted)")
        text.row("pause at end", "\(player.pauseAtTheEndOfMediaItem)")
        let preload = player.preloadConfiguration.targetPreloadDuration
        text.row("preload", preload.isNumeric ? DebugFormat.seconds(preload) : "off")

        text.header("Position")
        text.row("position", DebugFormat.time(player.currentPosition))
        text.row("duration", DebugFormat.time(player.duration))
        text.row("content pos", DebugFormat.time(player.contentPosition))
        text.row("content dur", DebugFormat.time(player.contentDuration))
        text.row("buffered to", DebugFormat.time(player.bufferedPosition))
        text.row("content buf", DebugFormat.time(player.contentBufferedPosition))
        text.row("total buffer", DebugFormat.seconds(player.totalBufferedDuration))
        text.row("timebase", DebugFormat.time(player.timebase.time))
        text.row("timebase rate", String(format: "%.2f", player.timebase.rate))

        text.header("Playlist")
        text.row("items", "\(player.numberOfMediaItemsInPlaylist)")
        text.row("current", "\(player.currentMediaItemIndex)")
        text.row("previous", player.previousMediaItemIndex.map { "\($0)" } ?? "—")
        text.row("next", player.nextMediaItemIndex.map { "\($0)" } ?? "—")
        text.row("has prev/next", "\(player.hasPreviousMediaItem) / \(player.hasNextMediaItem)")
        text.row("period", player.currentPeriodIndex.map { "\($0)" } ?? "—")
        text.row("dynamic", "\(player.isCurrentMediaItemDynamic)")
        text.row("seekable", "\(player.isCurrentMediaItemSeekable)")
        text.row("seek back", DebugFormat.seconds(player.seekBackIncrement))
        text.row("seek forward", DebugFormat.seconds(player.seekForwardIncrement))
        text.row("max to prev", DebugFormat.seconds(player.maxSeekToPreviousPosition))

        let rates = player.bandwidthMeter.transferRates()
        text.header("Bandwidth")
        text.row("estimate", DebugFormat.bitrate(player.bandwidthMeter.getBitrateEstimate()))
        if let prediction = player.bandwidthMeter.predict() {
            text.row("prediction", DebugFormat.bitrate(prediction.bitrate))
            text.row("safe", DebugFormat.bitrate(prediction.safeBitrate))
            text.row("safety", String(format: "×%.2f", prediction.safetyMultiplier))
            text.row("σ", DebugFormat.bitrate(prediction.standardDeviation))
            text.row("σ lower", DebugFormat.bitrate(prediction.lowerStandardDeviation))
        }
        text.row("avg rate", DebugFormat.bitrate(rates.average * 8))
        text.row("moving avg", DebugFormat.bitrate(rates.movingAverage * 8))
    }

    private func appendTracks(to text: inout DebugText) {
        let tracks = player.currentTracks
        if tracks.isEmpty {
            text.header("Tracks")
            text.line("No tracks yet.", color: .secondaryLabel)
            return
        }
        for (groupIndex, group) in tracks.groups.enumerated() {
            let groupId = group.mediaTrackGroup.id.isEmpty ? "" : " “\(group.mediaTrackGroup.id)”"
            text.header("\(group.type) \(groupIndex)\(groupId)\(group.adaptiveSupported ? " · adaptive" : "")")
            for trackIndex in 0 ..< group.length {
                let (line, color, bold) = DebugFormat.trackLine(group, trackIndex: trackIndex, playing: playingFormat(of: group.type))
                text.line(line, color: color, bold: bold)
            }
        }
    }

    private func showPeriod(windowIndex: Int, periodIndex: Int?) {
        // In full screen the player is presented itself: present over whatever is on top.
        guard var presenter = window?.rootViewController else { return }
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed { presenter = presented }

        let details = DebugPeriodViewController(player: player, windowIndex: windowIndex, periodIndex: periodIndex)
        let navigation = UINavigationController(rootViewController: details)
        #if !os(tvOS)
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        #endif
        presenter.present(navigation, animated: true)
    }

    // MARK: - Events

    private func log(_ event: String) {
        events.append((Date(), event))
        if events.count > 100 { events.removeFirst(events.count - 100) }
    }
}

extension PlayerDebugView: SEPlayerDelegate {
    func player(_ player: any Player, didChangeTimeline timeline: any Timeline, reason: TimelineChangeReason) {
        log("timeline \(reason): \(timeline.windowCount())W \(timeline.periodCount())P")
    }

    func player(_ player: any Player, didTransitionMediaItem mediaItem: MediaItem?, reason: MediaItemTransitionReason?) {
        log("item → \(mediaItem.map(DebugFormat.host(of:)) ?? "nil") (\(reason.map { "\($0)" } ?? "—"))")
    }

    func player(_ player: any Player, didChangeIsLoading isLoading: Bool) {
        log("loading \(isLoading)")
    }

    func player(_ player: any Player, didChangePlaybackState state: PlayerState) {
        log("state \(state.description.uppercased())")
        refresh()
    }

    func player(_ player: any Player, didChangePlayWhenReady playWhenReady: Bool, reason: PlayWhenReadyChangeReason) {
        log("playWhenReady \(playWhenReady) (\(reason))")
    }

    func player(_ player: any Player, didChangePlaybackSuppressionReason reason: PlaybackSuppressionReason) {
        log("suppression \(reason)")
    }

    func player(_ player: any Player, didChangeIsPlaying isPlaying: Bool) {
        log("isPlaying \(isPlaying)")
        refresh()
    }

    func player(_ player: any Player, didChangeRepeatMode repeatMode: RepeatMode) {
        log("repeat \(repeatMode)")
    }

    func player(_ player: any Player, didChangeShuffleMode shuffleModeEnabled: Bool) {
        log("shuffle \(shuffleModeEnabled)")
    }

    func player(_ player: any Player, onPlayerError error: any Error) {
        lastError = (Date(), "\(error)")
        log("error \(error)")
    }

    func player(
        _ player: any Player,
        didChangePositionDiscontinuity oldPosition: PositionInfo,
        newPosition: PositionInfo,
        reason: DiscontinuityReason
    ) {
        log("discontinuity \(reason)")
    }

    func player(_ player: any Player, didChangePlaybackParameters playbackParameters: PlaybackParameters) {
        log("speed \(playbackParameters.playbackRate)")
    }

    func player(_ player: any Player, didChangeTracks tracks: Tracks) {
        log("tracks: \(tracks.groups.count) groups")
    }

    func player(_ player: any Player, didChangeTrackSelectionParameters parameters: TrackSelectionParameters) {
        log("track selection parameters changed")
    }

    func player(_ player: any Player, didChangeMediaMetadata mediaMetadata: MediaMetadata) {
        log("media metadata: \(mediaMetadata.title ?? "no title")")
    }

    func player(_ player: any Player, didChangePlaylistMetadata playlistMetadata: MediaMetadata) {
        log("playlist metadata: \(playlistMetadata.title ?? "no title")")
    }

    func player(_ player: any Player, didChangeVolume volume: Float) {
        log(String(format: "volume %.2f", volume))
    }

    func player(_ player: any Player, didChangeIsMuted isMuted: Bool) {
        log("muted \(isMuted)")
    }

    func player(_ player: any Player, didChangeVideoSize videoSize: VideoSize) {
        log("video size \(videoSize.width)×\(videoSize.height)"
            + (videoSize.pixelWidthHeightRatio != 1 ? String(format: " par %.3f", videoSize.pixelWidthHeightRatio) : ""))
    }

    func playerDidRenderFirstFrame(_ player: any Player) {
        log("first frame rendered")
    }
}

// MARK: - Views

/// A label with some room around its text.
private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fitting = super.sizeThatFits(CGSize(width: size.width - insets.left - insets.right, height: size.height))
        return CGSize(width: fitting.width + insets.left + insets.right, height: fitting.height + insets.top + insets.bottom)
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: numberOfLines)
    }
}

/// The recent bandwidth estimate and prediction, against the bitrate of the selected tracks.
private final class BandwidthGraphView: UIView {
    private struct Sample {
        let estimate: Int
        let prediction: Int?
        let selected: Int?
    }

    private static let capacity = 240 // 60 s at the refresh rate.
    private var samples: [Sample] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.45)
        layer.cornerRadius = 6
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func add(estimate: Int, prediction: Int?, selected: Int?) {
        samples.append(Sample(estimate: estimate, prediction: prediction, selected: selected))
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        let top = Double(max(samples.map { max($0.estimate, $0.prediction ?? 0, $0.selected ?? 0) }.max() ?? 1, 1)) * 1.1
        let attributes: [NSAttributedString.Key: Any] = [.font: DebugFormat.smallFont, .foregroundColor: UIColor.secondaryLabel]
        ("max \(DebugFormat.bitrate(Int(top)))" as NSString).draw(at: CGPoint(x: 4, y: 1), withAttributes: attributes)
        guard samples.count > 1 else { return }

        let plot = CGRect(x: 4, y: 13, width: bounds.width - 8, height: bounds.height - 16)
        let step = plot.width / CGFloat(Self.capacity - 1)
        let start = plot.maxX - CGFloat(samples.count - 1) * step

        func path(_ value: (Sample) -> Int?) -> UIBezierPath {
            let path = UIBezierPath()
            var drawing = false
            for (index, sample) in samples.enumerated() {
                guard let value = value(sample) else {
                    drawing = false; continue
                }
                let point = CGPoint(x: start + CGFloat(index) * step,
                                    y: plot.maxY - plot.height * CGFloat(Double(value) / top))
                if drawing { path.addLine(to: point) } else { path.move(to: point) }
                drawing = true
            }
            path.lineWidth = 1.2
            return path
        }

        // Orange: the selected bitrate; faint teal: the prediction; teal: the safe estimate.
        UIColor.systemOrange.withAlphaComponent(0.8).setStroke()
        path(\.selected).stroke()
        UIColor.systemTeal.withAlphaComponent(0.5).setStroke()
        path(\.prediction).stroke()
        UIColor.systemTeal.setStroke()
        path { $0.estimate }.stroke()
    }
}
