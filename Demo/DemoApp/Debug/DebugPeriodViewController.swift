//
//  DebugPeriodViewController.swift
//  DemoApp
//

import CoreMedia
import SEPlayer
import UIKit

/// Everything about one window and period of the timeline, and the tracks when the period is the playing one.
/// Kept up to date while shown.
final class DebugPeriodViewController: UIViewController {
    private let player: SEPlayer
    private let windowIndex: Int
    private let periodIndex: Int?
    private let textView = UITextView()
    private var refreshTimer: Timer?

    init(player: SEPlayer, windowIndex: Int, periodIndex: Int?) {
        self.player = player
        self.windowIndex = windowIndex
        self.periodIndex = periodIndex
        super.init(nibName: nil, bundle: nil)
        title = periodIndex.map { "W\(windowIndex) · P\($0)" } ?? "W\(windowIndex)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        #if os(tvOS)
        view.backgroundColor = .black
        #else
        view.backgroundColor = .systemBackground
        textView.isEditable = false
        #endif
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        textView.frame = view.bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(textView)
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func render() {
        let offset = textView.contentOffset
        textView.attributedText = makeText().text
        textView.contentOffset = offset
    }

    private func makeText() -> DebugText {
        var text = DebugText()
        let timeline = player.timeline
        guard windowIndex < timeline.windowCount() else {
            text.line("The window is no longer in the timeline.", color: .secondaryLabel)
            return text
        }

        let window = timeline.getWindow(windowIndex: windowIndex, window: Window(), defaultPositionProjection: .zero)
        let isCurrentWindow = windowIndex == player.currentMediaItemIndex
        text.header("Window \(windowIndex)\(isCurrentWindow ? " · playing" : "")")
        text.row("title", window.mediaItem.mediaMetadata.title ?? "—")
        text.row("media id", window.mediaItem.mediaId.isEmpty ? "—" : window.mediaItem.mediaId)
        text.row("url", window.mediaItem.localConfiguration?.url.absoluteString ?? "—")
        text.row("mime", window.mediaItem.localConfiguration?.mimeType ?? "—")
        text.row("id", DebugFormat.id(window.id))
        text.row("duration", DebugFormat.time(window.duration))
        text.row("default pos", DebugFormat.time(window.defaultPosition))
        text.row("pos in 1st P", DebugFormat.time(window.positionInFirstPeriod))
        text.row("periods", "\(window.firstPeriodIndex)…\(window.lastPeriodIndex)")
        text.row("seekable", "\(window.isSeekable)")
        text.row("dynamic", "\(window.isDynamic)")
        text.row("live", "\(window.isLive)")
        text.row("placeholder", "\(window.isPlaceholder)")
        if window.presentationStartTime.isNumeric, window.presentationStartTime != .zero {
            text.row("presentation", DebugFormat.time(window.presentationStartTime))
        }
        if window.windowStartTime.isNumeric, window.windowStartTime != .zero {
            text.row("window start", DebugFormat.time(window.windowStartTime))
        }
        if let live = window.liveConfiguration {
            text.row("live config", "\(live)")
        }
        if let manifest = window.manifest {
            text.row("manifest", "\(type(of: manifest))")
        }
        if isCurrentWindow {
            text.row("position", DebugFormat.time(player.currentPosition))
            text.row("buffered to", DebugFormat.time(player.bufferedPosition))
            text.row("buffered", "\(player.bufferedPercentage)%")
        }

        guard let periodIndex, periodIndex < timeline.periodCount() else { return text }
        let period = timeline.getPeriod(periodIndex: periodIndex, period: Period(), setIds: true)
        let isCurrentPeriod = periodIndex == player.currentPeriodIndex
        text.header("Period \(periodIndex)\(isCurrentPeriod ? " · playing" : "")")
        text.row("uid", period.uid.map(DebugFormat.id) ?? "—")
        text.row("id", period.id.map(DebugFormat.id) ?? "—")
        text.row("duration", DebugFormat.time(period.duration))
        text.row("pos in window", DebugFormat.time(period.positionInWindow))
        text.row("placeholder", "\(period.isPlaceholder)")

        guard isCurrentPeriod else {
            text.line("")
            text.line("Tracks are known for the playing period only.", color: .secondaryLabel)
            return text
        }
        appendTracks(player.currentTracks, to: &text)
        return text
    }

    private func appendTracks(_ tracks: Tracks, to text: inout DebugText) {
        if tracks.isEmpty {
            text.header("Tracks")
            text.line("No tracks yet.", color: .secondaryLabel)
            return
        }

        for (groupIndex, group) in tracks.groups.enumerated() {
            let groupId = group.mediaTrackGroup.id.isEmpty ? "" : " “\(group.mediaTrackGroup.id)”"
            text.header("\(group.type) group \(groupIndex)\(groupId)")
            text.row("tracks", "\(group.length)")
            text.row("adaptive", "\(group.adaptiveSupported)")
            text.row("selected", "\(group.isSelected)")
            let playing: AnyFormat? = switch group.type {
            case .video: player.videoFormat
            case .audio: player.audioFormat
            default: nil
            }
            for trackIndex in 0 ..< group.length {
                let (line, color, bold) = DebugFormat.trackLine(group, trackIndex: trackIndex, playing: playing)
                text.line(line, color: color, bold: bold)
            }
            // The details of the track that plays, as read from the media; else of the one selected.
            if let playing, let playingIndex = DebugFormat.playingTrackIndex(in: group, playing: playing) {
                text.line("")
                text.line("▶ track \(playingIndex), as played", color: .systemGreen)
                for (key, value) in DebugFormat.formatDetails(playing) {
                    text.row("  " + key, value)
                }
            } else if let selectedIndex = (0 ..< group.length).first(where: { group.isTrackSelected(for: $0) }),
                      (0 ..< group.length).filter({ group.isTrackSelected(for: $0) }).count == 1 {
                text.line("")
                text.line("track \(selectedIndex)", color: .systemTeal)
                for (key, value) in DebugFormat.formatDetails(group.format(trackIndex: selectedIndex)) {
                    text.row("  " + key, value)
                }
            }
        }
    }
}
