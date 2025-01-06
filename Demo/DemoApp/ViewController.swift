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
    
    init() {
        player = factory.buildPlayer()
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        player = factory.buildPlayer()
        super.init(coder: coder)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        player.set(content: videoUrl)
    }
}

let videoUrl: URL = URL(string: "https://html5demos.com/assets/dizzy.mp4")!
