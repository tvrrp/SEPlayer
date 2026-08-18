//
//  ViewController.swift
//  DemoApp
//
//  Created by Damir Yackupov on 06.01.2025.
//

import AVFAudio
import UIKit
import SEPlayer
import MediaPlayer
import DataSource

class PlayerViewController: UIViewController {
    var seekParameters: SeekParameters = .default

    let player: SEPlayer
    let mediaTimeInterpolator: MediaTimeInterpolator

    let playerView = SEPlayerView()
    let playerView2 = SEPlayerView()

    var videoUrls = [URL]()
    var repeatMode: RepeatMode = .off
    let volumeView = UISlider()

    let controlsContainerView = UIView()
    var controlsContainerViewIsHidden = false
    let backwardsButton = UIButton(type: .system)
    let forwardsButton = UIButton(type: .system)
    let seekBackwardsButton = UIButton(type: .system)
    let seekForwardsButton = UIButton(type: .system)
    let playButton = UIButton(type: .system)
    let muteButton = UIButton(type: .system)
    let buttonStackView = UIStackView()

    let currentTimeLabel = UILabel()
    let durationLabel = UILabel()
    let seekSlider = UISlider()
    private var playWhenReadyBeforeSlider = true

    let speedGestureRecogniser = UILongPressGestureRecognizer()
    let feedback = UIImpactFeedbackGenerator()

    private var seekContinuation: AsyncStream<(Float, SeekParameters)>.Continuation?
    private var shouldObserveTimer = true
    private var displayLink: CADisplayLink?

    private var workingWithSlider = false
    private var runningSeek = false

    init() {
        player = playerFactory.buildPlayer()
        playerView.player = player
        mediaTimeInterpolator = MediaTimeInterpolator(player: player)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        player = playerFactory.buildPlayer()
        playerView.player = player
        mediaTimeInterpolator = MediaTimeInterpolator(player: player)
        super.init(coder: coder)
    }

    deinit {
        player.release()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerView.frame = view.bounds
        controlsContainerView.frame = view.bounds

        playerView2.frame = CGRect(x: 0, y: 0, width: 100, height: 300)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        shouldObserveTimer = false
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        player.stop()
        player.release()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        displayLink?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(controlsContainerView)
        controlsContainerView.addSubview(currentTimeLabel)
        controlsContainerView.addSubview(durationLabel)
        controlsContainerView.addSubview(seekSlider)

        view.insertSubview(playerView, at: 0)
        view.insertSubview(playerView2, at: 1)
//        controlsContainerView.addSubview(volumeView)
//        controlsContainerView.addSubview(muteButton)

        currentTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        seekSlider.translatesAutoresizingMaskIntoConstraints = false
        buttonStackView.translatesAutoresizingMaskIntoConstraints = false
        volumeView.translatesAutoresizingMaskIntoConstraints = false
        muteButton.translatesAutoresizingMaskIntoConstraints = false

        backwardsButton.configuration = createButtonConfig(imageName: "backward.fill")
        backwardsButton.addTarget(self, action: #selector(backwardsButtonTap), for: .touchUpInside)

        forwardsButton.configuration = createButtonConfig(imageName: "forward.fill")
        forwardsButton.addTarget(self, action: #selector(forwardsButtonTap), for: .touchUpInside)

        seekBackwardsButton.configuration = createButtonConfig(imageName: "gobackward.10")
        seekBackwardsButton.addTarget(self, action: #selector(backwardsTap), for: .touchUpInside)

        seekForwardsButton.configuration = createButtonConfig(imageName: "goforward.10")
        seekForwardsButton.addTarget(self, action: #selector(forwardsTap), for: .touchUpInside)

        playButton.configuration = createButtonConfig(imageName: "pause.fill")
        playButton.addTarget(self, action: #selector(playPause), for: .touchUpInside)

        muteButton.configuration = createButtonConfig(imageName: "speaker.slash.fill")
        muteButton.addTarget(self, action: #selector(muteTapped), for: .touchUpInside)

        volumeView.minimumValue = .zero
        volumeView.maximumValue = 1.0
        volumeView.value = 1.0

        [currentTimeLabel, durationLabel].forEach {
            $0.font = UIFont.monospacedDigitSystemFont(ofSize: UIFont.smallSystemFontSize, weight: .regular)
            $0.textAlignment = .natural
            $0.numberOfLines = 0
            $0.textColor = .white
            $0.text = "0"
        }

        seekSlider.isUserInteractionEnabled = false
        seekSlider.minimumValue = .zero
        seekSlider.value = .zero
        seekSlider.minimumTrackTintColor = .white
        seekSlider.maximumTrackTintColor = .gray
        seekSlider.addTarget(self, action: #selector(sliderTouchDown), for: .touchDown)
        seekSlider.addTarget(self, action: #selector(sliderTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        seekSlider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)

        volumeView.addTarget(self, action: #selector(volumeSliderDidChange), for: .valueChanged)

        if #available(iOS 26, *) {
            seekSlider.sliderStyle = .thumbless
            volumeView.sliderStyle = .thumbless
        }

        view.addGestureRecognizer(speedGestureRecogniser)
        speedGestureRecogniser.minimumPressDuration = 0.3
        speedGestureRecogniser.addTarget(self, action: #selector(handleLongPress))

//        try! AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        try! AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        try! AVAudioSession.sharedInstance().setActive(true)

        playerView.gravity = .resizeAspect

        player.set(mediaItems: videoUrls.map { MediaItem.Builder().setUrl($0).build() })
        if videoUrls.count == 1 {
            player.repeatMode = .one
            backwardsButton.isHidden = true
            forwardsButton.isHidden = true
        }
        player.delegate.addDelegate(self)
        player.prepare()
        player.playWhenReady = true

        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)

        buttonStackView.axis = .horizontal
        buttonStackView.alignment = .fill
        buttonStackView.distribution = .fill
//        buttonStackView.spacing = 0

        buttonStackView.addArrangedSubview(backwardsButton)
        buttonStackView.addArrangedSubview(seekBackwardsButton)
        buttonStackView.addArrangedSubview(playButton)
        buttonStackView.addArrangedSubview(seekForwardsButton)
        buttonStackView.addArrangedSubview(forwardsButton)

        controlsContainerView.addSubview(buttonStackView)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(hideControls))
        view.addGestureRecognizer(tapGesture)

        NSLayoutConstraint.activate([
//            volumeView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
//            volumeView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
//
//            muteButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
//            muteButton.leadingAnchor.constraint(equalTo: volumeView.trailingAnchor, constant: 16),
//            muteButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),

            buttonStackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            buttonStackView.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            seekSlider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            seekSlider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            seekSlider.bottomAnchor.constraint(equalTo: currentTimeLabel.topAnchor),

            currentTimeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            currentTimeLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),

            durationLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            durationLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32)
        ])
    }

    @objc private func hideControls() {
        controlsContainerViewIsHidden.toggle()

        UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState]) { [self] in
            if controlsContainerViewIsHidden {
                controlsContainerView.alpha = 0
                navigationController?.navigationBar.alpha = 0
                displayLink?.isPaused = true
            } else {
                updateTime()
                controlsContainerView.alpha = 1
                navigationController?.navigationBar.alpha = 1
                controlsContainerView.isHidden = false
            }
        } completion: { [weak self] didFinish in
            if let self, didFinish {
                controlsContainerView.isHidden = controlsContainerViewIsHidden
            }
        }
    }

    @objc private func sliderTouchDown(_ sender: UISlider) {
//        print("🤬 sliderTouchDown")
//        timer?.invalidate()
        shouldObserveTimer = false
        displayLink?.isPaused = true
        playWhenReadyBeforeSlider = player.playWhenReady
        player.pause()

        Task {
            let (stream, continuation) = AsyncStream<(Float, SeekParameters)>.makeStream(bufferingPolicy: .bufferingNewest(1))
            seekContinuation = continuation

            for await (value, _) in stream {
                if seekContinuation == nil { break }
                let time = CMTime(seconds: Double(value), preferredTimescale: 1000)
                print("🌈 WIIIL SEEEK TO position \(time.seconds)")
                await withCheckedContinuation { seekCont in
                    player.seek(to: time, seekParameters: .exact) { _ in
                        print("🌈 seek position FINISHHHHHH")
                        seekCont.resume()
                    }
                }
            }

            seekContinuation = nil
            shouldObserveTimer = true
            player.playWhenReady = playWhenReadyBeforeSlider
            updateTime()
        }
    }

    @objc private func sliderTouchUp(_ sender: UISlider) {
        print("🌈 FIIIIINISH value, = \(sender.value)")
//        seekContinuation?.yield((sender.value, .exact))
        seekContinuation?.finish()
        seekContinuation = nil
        let time = CMTime(seconds: Double(sender.value), preferredTimescale: 1000)
        player.seek(to: time, seekParameters: .exact)
        print("🌈 seek position EEEEEEEEEEEENDNDNNDNDNDNND")

        currentTimeLabel.text = "\(Int(player.bufferedPosition.seconds))" + "|" + "\(Int64(sender.value))"
//        updateTime()
    }

    @objc private func sliderValueChanged(_ sender: UISlider) {
        currentTimeLabel.text = "\(Int(player.bufferedPosition.seconds))" + "|" + "\(Int64(sender.value))"

        let yieldResult = seekContinuation?.yield((sender.value, .closestSync))
        if case .enqueued = yieldResult {
            print("🌈 YIEEEEEEEELD value, = \(sender.value)")
        }
//        print("🫟 seek position YIEEEEEEEEEEEEEEEEEELD = \(result)")
//        player.seek(to: Int64(sender.value))
    }

    @objc private func volumeSliderDidChange(_ sender: UISlider) {
        player.volume = sender.value
    }

    @objc func handleLongPress(_ sender: UILongPressGestureRecognizer) {
        switch sender.state {
        case .possible:
            feedback.prepare()
        case .began:
            let location = sender.location(in: view)
            if location.x < 50 || location.x > (view.bounds.width - 50) {
                feedback.impactOccurred()
                player.playbackParameters = PlaybackParameters(playbackRate: 2.0)
            }
        case .ended, .cancelled, .failed:
            player.playbackParameters = PlaybackParameters(playbackRate: 1)
        default:
            return
        }
    }

    @objc
    func didEnterBackground() {
        player.pause()
        playButton.isHidden = false
    }

    @objc func playPause() {
        if player.playWhenReady {
            player.pause()
            playButton.configuration?.image = UIImage(systemName: "play.fill")?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
        } else {
            player.play()
            playButton.configuration?.image = UIImage(systemName: "pause.fill")?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
        }
    }

    @objc func backwardsTap() {
        player.seekBack(seekParameters: .exact)
//        handleTimer()
    }

    @objc func forwardsTap() {
        player.seekForward(seekParameters: .exact)
//        handleTimer()
    }

    @objc func backwardsButtonTap() {
        player.seekToPreviousMediaItem()
    }

    @objc func forwardsButtonTap() {
        player.seekToNextMediaItem()
    }

    @objc func muteTapped() {
        if player.isMuted {
            muteButton.configuration = createButtonConfig(imageName: "speaker.wave.2.fill")
            player.isMuted = false
        } else {
            muteButton.configuration = createButtonConfig(imageName: "speaker.slash.fill")
            player.isMuted = true
        }
    }

    private func updateTime() {
        guard displayLink == nil else {
            displayLink?.isPaused = false
            return
        }

        displayLink = CADisplayLink(target: self, selector: #selector(handleTimer))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc
    private func handleTimer(displayLink: CADisplayLink) {
//        let position = player.currentPosition.seconds
        let position = mediaTimeInterpolator.time(at: displayLink.targetTimestamp)
        currentTimeLabel.text = "\(Int(player.bufferedPosition.seconds))|\(Int(position))"
        seekSlider.setValue(Float(position), animated: false)
    }

    private func createButtonConfig(imageName: String) -> UIButton.Configuration {
        var config = if #available(iOS 26, *) {
            UIButton.Configuration.clearGlass()
        } else {
            UIButton.Configuration.borderless()
        }

        config.image = UIImage(systemName: imageName)?.withTintColor(.white, renderingMode: .alwaysOriginal)
//        config.buttonSize = .small
        return config
    }
}

extension PlayerViewController: SEPlayerDelegate {
    func player(_ player: any Player, onPlayerError error: any Error) {
        print("❌❌❌ onPlayerError = \(error)")
//        player.clearMediaItems()
//        player.set(mediaItems: videoUrls.map { MediaItem.Builder().setUrl($0).build() })
//        player.prepare()
//        player.play()
    }

    func player(_ player: any Player, didChangePlaybackState state: PlayerState) {
        print("🫟 seek position REEEEDYYYYYYY")
        if state == .ready, seekContinuation == nil {
            if player.duration.isValid {
                let duration = player.duration.seconds
                durationLabel.text = "\(Int(duration))"
                seekSlider.maximumValue = Float(duration)
                seekSlider.isUserInteractionEnabled = true
                updateTime()
            }

//            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
//                self.playerView2.player = player as? SEPlayer
//
//                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
//                    self.playerView2.player = nil
//                    self.playerView2.removeFromSuperview()
//                }
//            }
        }
    }

    func player(_ player: any Player, didChangeTimeline timeline: any Timeline, reason: TimelineChangeReason) {
        if player.duration.isValid {
            let duration = player.duration.seconds
            durationLabel.text = "\(Int(duration))"
            seekSlider.maximumValue = Float(duration)
            seekSlider.isUserInteractionEnabled = true
            updateTime()
        }
    }

    func player(_ player: any Player, didTransitionMediaItem mediaItem: MediaItem?, reason: MediaItemTransitionReason?) {
        let duration = player.duration
        if duration.isValid {
            durationLabel.text = "\(Int(player.duration.seconds))"
            seekSlider.maximumValue = Float(player.duration.seconds)
        }
    }
}
