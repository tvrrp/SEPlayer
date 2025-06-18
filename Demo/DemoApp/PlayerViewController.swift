//
//  ViewController.swift
//  DemoApp
//
//  Created by Damir Yackupov on 06.01.2025.
//

import AVFAudio
import UIKit
import SEPlayer

class PlayerViewController: UIViewController {
    let player: Player
    let playerView = SEPlayerView()
    var videoUrls = [URL]()
    var repeatMode: RepeatMode = .off

    let playButton = UIButton(type: .system)
    let backwardsButton = UIButton(type: .system)
    let forwardsButton = UIButton(type: .system)

    let currentTimeLabel = UILabel()
    let durationLabel = UILabel()
    let seekSlider = UISlider()
    private var playWhenReadyBeforeSlider = false

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

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        player.stop()
        player.release()
        timer?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.insertSubview(playerView, at: 0)

        view.addSubview(playButton)
        view.addSubview(backwardsButton)
        view.addSubview(forwardsButton)
        view.addSubview(currentTimeLabel)
        view.addSubview(durationLabel)
        view.addSubview(seekSlider)

        view.backgroundColor = .black
        playButton.translatesAutoresizingMaskIntoConstraints = false
        backwardsButton.translatesAutoresizingMaskIntoConstraints = false
        forwardsButton.translatesAutoresizingMaskIntoConstraints = false
        currentTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        seekSlider.translatesAutoresizingMaskIntoConstraints = false

        playButton.configuration = createButtonConfig(imageName: "pause.fill")
        playButton.addTarget(self, action: #selector(playPause), for: .touchUpInside)

        backwardsButton.configuration = createButtonConfig(imageName: "gobackward.10")
        backwardsButton.addTarget(self, action: #selector(backwardsTap), for: .touchUpInside)

        forwardsButton.configuration = createButtonConfig(imageName: "goforward.10")
        forwardsButton.addTarget(self, action: #selector(forwardsTap), for: .touchUpInside)

        [currentTimeLabel, durationLabel].forEach {
            $0.font = UIFont.monospacedDigitSystemFont(ofSize: UIFont.smallSystemFontSize, weight: .regular)
            $0.textAlignment = .natural
            $0.numberOfLines = 0
            $0.textColor = .white
            $0.text = "0"
        }

        seekSlider.minimumValue = .zero
        seekSlider.value = .zero
        seekSlider.minimumTrackTintColor = .white
        seekSlider.maximumTrackTintColor = .gray
        seekSlider.addTarget(self, action: #selector(sliderTouchDown), for: .touchDown)
        seekSlider.addTarget(self, action: #selector(sliderTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        seekSlider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)
        if #available(iOS 26, *) {
            seekSlider.sliderStyle = .thumbless
        }

        view.addGestureRecognizer(speedGestureRecogniser)
        speedGestureRecogniser.minimumPressDuration = 0.3
        speedGestureRecogniser.addTarget(self, action: #selector(handleLongPress))

        try? AVAudioSession.sharedInstance().setActive(true)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: .duckOthers)

        playerView.gravity = .resizeAspect
        player.set(mediaItems: videoUrls.map { MediaItem(url: $0) })
//        player.repeatMode = repeatMode
        player.delegate.addDelegate(self)
        player.prepare()
        player.playWhenReady = true

        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)

        NSLayoutConstraint.activate([
            playButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            backwardsButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            backwardsButton.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -60),

            forwardsButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            forwardsButton.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 60),

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
        print("🤬 sliderTouchDown")
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

    private func updateTime() {
        timer?.invalidate()

        let timer = Timer(timeInterval: 0.2, repeats: true, block: { [weak self] _ in
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
        let position = player.contentPosition
        currentTimeLabel.text = "\(player.bufferedPosition)|\(position)"
        seekSlider.setValue(Float(position), animated: true)
    }

    private func createButtonConfig(imageName: String) -> UIButton.Configuration {
        var config = UIButton.Configuration.borderless()

        config.image = UIImage(systemName: imageName)?.withTintColor(.white, renderingMode: .alwaysOriginal)
        config.buttonSize = .large
        return config
    }
}

extension PlayerViewController: SEPlayerDelegate {
    func player(_ player: any Player, didChangePlaybackState state: PlayerState) {
        if state == .ready {
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
