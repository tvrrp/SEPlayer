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
    let player: SEPlayer.Player
    let playerView = SEPlayerView()
    let playImage = UIImageView()
    let tapGesture = UITapGestureRecognizer()

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
        playImage.frame.size = CGSize(width: 40, height: 40)
        playImage.center = view.center
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(playerView)
        view.addSubview(playImage)

        playImage.isHidden = true
        playImage.image = UIImage(systemName: "play.fill")?
            .withTintColor(.white, renderingMode: .alwaysOriginal)

        view.addGestureRecognizer(tapGesture)
        tapGesture.addTarget(self, action: #selector(playPause))

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
            playImage.isHidden = false
        } else {
            player.play()
            UIView.animate(withDuration: 0.5) {
                self.playImage.isHidden = true
            }
        }
    }
    var didSeek = false
}

extension ViewController: SEPlayerDelegate {
    
}

let videoUrls: [URL] = [
    "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/WeAreGoingOnBullrun.mp4",
    "https://html5demos.com/assets/dizzy.mp4",
    "https://storage.googleapis.com/exoplayer-test-media-0/BigBuckBunny_320x180.mp4",
    "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/WeAreGoingOnBullrun.mp4",
    "https://streams.videolan.org/streams/mp4/GHOST_IN_THE_SHELL_V5_DOLBY%20-%203.m4v",
    "https://norihiro.github.io/obs-audio-video-sync-dock/sync-pattern-2400.mp4",
    "https://www.sample-videos.com/video321/mp4/720/big_buck_bunny_720p_10mb.mp4",
    "https://github.com/chthomos/video-media-samples/raw/refs/heads/master/big-buck-bunny-1080p-60fps-30sec.mp4",
].map { URL(string: $0)! }
