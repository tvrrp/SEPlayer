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

class PlayerViewController: UIViewController {
    var seekParameters: SeekParameters = .default

    let player: SEPlayer

    let playerView = SEPlayerView()

    var videoUrls = [URL]()
    var repeatMode: RepeatMode = .off
    let volumeView = UISlider()

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

    var timer: Timer?

    init() {
        player = playerFactory.buildPlayer()
        playerView.player = player
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        player = playerFactory.buildPlayer()
        playerView.player = player
        super.init(coder: coder)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerView.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        player.stop()
        player.release()
        timer?.invalidate()
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.insertSubview(playerView, at: 0)
        view.addSubview(currentTimeLabel)
        view.addSubview(durationLabel)
        view.addSubview(seekSlider)
        view.addSubview(volumeView)
        view.addSubview(muteButton)

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
        view.addGestureRecognizer(speedGestureRecogniser)
        speedGestureRecogniser.minimumPressDuration = 0.3
        speedGestureRecogniser.addTarget(self, action: #selector(handleLongPress))

        try! AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        try! AVAudioSession.sharedInstance().setActive(true)

        playerView.gravity = .resizeAspect

        player.set(mediaItems: videoUrls.map { MediaItem.Builder().setUrl($0).build() })
        if videoUrls.count == 1 {
            player.repeatMode = .one
        }
        player.seekParameters = seekParameters
        player.delegate.addDelegate(self)
        player.prepare()
        player.playWhenReady = true

        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)

        buttonStackView.axis = .horizontal
        buttonStackView.alignment = .center
        buttonStackView.distribution = .equalSpacing
        buttonStackView.spacing = 24

        buttonStackView.addArrangedSubview(backwardsButton)
        buttonStackView.addArrangedSubview(seekBackwardsButton)
        buttonStackView.addArrangedSubview(playButton)
        buttonStackView.addArrangedSubview(seekForwardsButton)
        buttonStackView.addArrangedSubview(forwardsButton)

        view.addSubview(buttonStackView)

        NSLayoutConstraint.activate([
            volumeView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            volumeView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),

            muteButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            muteButton.leadingAnchor.constraint(equalTo: volumeView.trailingAnchor, constant: 16),
            muteButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),

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

    @objc private func sliderTouchDown(_ sender: UISlider) {
//        print("🤬 sliderTouchDown")
        timer?.invalidate()
        playWhenReadyBeforeSlider = player.playWhenReady
        player.pause()
    }

    @objc private func sliderTouchUp(_ sender: UISlider) {
        let newTime = Int64(sender.value)
        player.seek(to: newTime)
        player.playWhenReady = playWhenReadyBeforeSlider
        updateTime()
    }

    @objc private func sliderValueChanged(_ sender: UISlider) {
        currentTimeLabel.text = "\(player.bufferedPosition)" + "|" + "\(Int64(sender.value))"
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
        player.seekBack()
        handleTimer()
    }

    @objc func forwardsTap() {
        player.seekForward()
        handleTimer()
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
        timer?.invalidate()

        let timer = Timer(timeInterval: 1/30, repeats: true, block: { [weak self] _ in
            self?.handleTimer()
        })
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        let duration = player.duration
        if duration != .timeUnset {
            durationLabel.text = "\(player.duration)"
            seekSlider.maximumValue = Float(player.duration)
        }
    }

    private func handleTimer() {
        let position = player.currentPosition
        currentTimeLabel.text = "\(player.bufferedPosition)|\(position)"
        seekSlider.setValue(Float(position), animated: false)
    }

    private func createButtonConfig(imageName: String) -> UIButton.Configuration {
        var config = UIButton.Configuration.borderless()
        try! AVAudioSession.sharedInstance().setSupportsMultichannelContent(true)

        config.image = UIImage(systemName: imageName)?.withTintColor(.white, renderingMode: .alwaysOriginal)
        config.buttonSize = .large
        return config
    }
}

extension PlayerViewController: SEPlayerDelegate {
    func player(_ player: any Player, didChangePlaybackState state: PlayerState) {
        if state == .ready {
            seekSlider.isUserInteractionEnabled = true
            updateTime()
        }
    }

    func player(_ player: any Player, didTransitionMediaItem mediaItem: MediaItem?, reason: MediaItemTransitionReason?) {
        let duration = player.duration
        if duration != .timeUnset {
            durationLabel.text = "\(player.duration)"
            seekSlider.maximumValue = Float(player.duration)
        }
    }
}
