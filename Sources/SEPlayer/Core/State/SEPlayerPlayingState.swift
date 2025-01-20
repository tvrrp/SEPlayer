//
//  SEPlayerPlayingState.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 19.01.2025.
//

final class SEPlayerPlayingState: SEPlayerBaseState {
    override var state: SEPlayer.State { .playing }

    override func didLoad() {
        super.didLoad()
        dependencies.renderSynchronizer.setRate(1, time: .zero)
    }

    override func play() {}
}
