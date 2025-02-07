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
    let player: SEPlayer
    let playerView = SEPlayerView()
    let slider = UISlider()

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
        slider.frame = CGRect(x: view.bounds.origin.x + 10, y: view.bounds.maxY - 50, width: view.bounds.width - 20, height: 50)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(playerView)
        try? AVAudioSession.sharedInstance().setActive(true)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: .duckOthers)
        playerView.gravity = .resizeAspect
        player.set(content: videoUrl)
        player.delegate.addDelegate(self)
    }
    
    @objc func sliderChanged(_ slider: UISlider) {
        player.playbackRate = slider.value
    }
}

extension ViewController: SEPlayerDelegate {
    func player(_ player: SEPlayer, didChangeTime time: Double) {
        
    }
}

let videoUrl: URL = URL(string: "https://html5demos.com/assets/dizzy.mp4")!
//let videoUrl = URL(string: "https://v.ozone.ru/vod/video-7/01GE7KG4C15DDZTZ065V4WNAXC/asset_3.mp4")!
//let videoUrl = URL(string: "https://streams.videolan.org/streams/mp4/GHOST_IN_THE_SHELL_V5_DOLBY%20-%203.m4v")!
//let videoUrl = URL(string: "https://github.com/chthomos/video-media-samples/raw/refs/heads/master/big-buck-bunny-1080p-60fps-30sec.mp4")!
//let videoUrl = URL(string: "https://www.sample-videos.com/video321/mp4/720/big_buck_bunny_720p_10mb.mp4")!
