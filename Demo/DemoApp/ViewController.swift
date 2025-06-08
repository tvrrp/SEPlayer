//
//  ViewController.swift
//  DemoApp
//
//  Created by Damir Yackupov on 06.01.2025.
//

import AVFAudio
import UIKit
import SEPlayer

class ViewController: UIViewController {
    let factory = SEPlayerFactory()
    let player: Player
    let playerView = SEPlayerView()

    @IBOutlet weak var playImage: UIImageView!
    @IBOutlet weak var backwards: UIImageView!
    @IBOutlet weak var forwards: UIImageView!

    @IBOutlet weak var currentTimeLabel: UILabel!
    @IBOutlet weak var durationLabel: UILabel!
    @IBOutlet weak var seekSlider: UISlider!

    let tapGesture = UITapGestureRecognizer()
    let backwardsTapGesture = UITapGestureRecognizer()
    let forwardsTapGesture = UITapGestureRecognizer()

    var timer: Timer?
    var dontUpdateValue = false

    init() {
        player = factory.buildPlayer()
        playerView.player = player
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        player = factory.buildPlayer()
        playerView.player = player
        super.init(coder: coder)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerView.frame = view.bounds
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.insertSubview(playerView, at: 0)

//        backwards.isHidden = true
//        forwards.isHidden = true

        playImage.image = UIImage(systemName: "pause.fill")
        playImage.isUserInteractionEnabled = true
        playImage.addGestureRecognizer(tapGesture)
        tapGesture.addTarget(self, action: #selector(playPause))

        backwards.isUserInteractionEnabled = true
        backwards.addGestureRecognizer(backwardsTapGesture)
        backwardsTapGesture.addTarget(self, action: #selector(backwardsTap))

        forwards.isUserInteractionEnabled = true
        forwards.addGestureRecognizer(forwardsTapGesture)
        forwardsTapGesture.addTarget(self, action: #selector(forwardsTap))

        [currentTimeLabel, durationLabel].forEach {
            $0?.font = UIFont.monospacedDigitSystemFont(ofSize: UIFont.smallSystemFontSize, weight: .regular)
            $0?.textAlignment = .natural
            $0?.numberOfLines = 1
            $0?.textColor = .white
            $0?.text = "0"
        }

        seekSlider.minimumValue = .zero
        seekSlider.value = .zero
        seekSlider.addTarget(self, action: #selector(sliderTouchDown), for: .touchDown)
        seekSlider.addTarget(self, action: #selector(sliderTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        seekSlider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)

        try? AVAudioSession.sharedInstance().setActive(true)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: .duckOthers)

        playerView.gravity = .resizeAspect
        player.set(mediaItems: videoUrls.map { MediaItem(url: $0) })
        player.delegate.addDelegate(self)
        player.prepare()
        player.playWhenReady = true

        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)

//        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForegroud), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func sliderTouchDown(_ sender: UISlider) {
        dontUpdateValue = true
    }

    @objc private func sliderTouchUp(_ sender: UISlider) {
        dontUpdateValue = false
        let newTime = Int64(sender.value)
        player.seek(to: newTime)
    }

    @objc private func sliderValueChanged(_ sender: UISlider) {
        // Optional: show preview or current time label update
    }

    @objc
    func didEnterBackground() {
        player.pause()
        playImage.isHidden = false
    }

//    @objc
//    func willEnterForegroud() {
//        if !player.isPlaying {
//            player.play()
//        }
//    }

    @objc func playPause() {
        if player.playWhenReady {
            player.pause()
            playImage.image = UIImage(systemName: "play.fill")
        } else {
            player.play()
            playImage.image = UIImage(systemName: "pause.fill")
        }
    }

    @objc func backwardsTap() {
        player.seekToPreviousMediaItem()
    }

    @objc func forwardsTap() {
        player.seekToNextMediaItem()
    }

    private func updateTime() {
        let timer = Timer(timeInterval: 1 / 30, repeats: true, block: { [weak self] _ in
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
        currentTimeLabel.text = "\(player.currentPosition)"
        if !dontUpdateValue {
            seekSlider.setValue(Float(player.currentPosition), animated: true)
        }
    }
}

extension ViewController: SEPlayerDelegate {
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

let videoUrls: [URL] = [
    "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/WeAreGoingOnBullrun.mp4",
//    "https://html5demos.com/assets/dizzy.mp4",
//    "https://streams.videolan.org/streams/mp4/GHOST_IN_THE_SHELL_V5_DOLBY%20-%203.m4v",
//    "https://storage.googleapis.com/exoplayer-test-media-0/BigBuckBunny_320x180.mp4",
//    "https://norihiro.github.io/obs-audio-video-sync-dock/sync-pattern-2400.mp4",
//    "https://www.sample-videos.com/video321/mp4/720/big_buck_bunny_720p_10mb.mp4",
//    "https://github.com/chthomos/video-media-samples/raw/refs/heads/master/big-buck-bunny-1080p-60fps-30sec.mp4",
].map { URL(string: $0)! }
