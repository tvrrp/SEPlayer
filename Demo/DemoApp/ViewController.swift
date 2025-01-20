//
//  ViewController.swift
//  DemoApp
//
//  Created by Damir Yackupov on 06.01.2025.
//

import UIKit
import SEPlayer

class ViewController: UIViewController {

    let factory = SEPlayerFactory()
    let player: SEPlayer
    let layer: CALayer
    
    init() {
        player = factory.buildPlayer()
        layer = player.videoRenderer
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        player = factory.buildPlayer()
        layer = player.videoRenderer
        super.init(coder: coder)
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layer.frame = view.bounds
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.layer.addSublayer(player.videoRenderer)
        player.set(content: videoUrl)
    }
}

//let videoUrl: URL = URL(string: "https://html5demos.com/assets/dizzy.mp4")!
let videoUrl = URL(string: "https://v.ozone.ru/vod/video-7/01GE7KG4C15DDZTZ065V4WNAXC/asset_3.mp4")!
//let videoUrl = URL(string: "https://streams.videolan.org/streams/mp4/GHOST_IN_THE_SHELL_V5_DOLBY%20-%203.m4v")!
//let videoUrl = URL(string: "https://streams.videolan.org/streams/mp4/Mr_MrsSmith-h264_aac.mp4")!
