//
//  SEPlayerState.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

protocol SEPlayerStatable: AnyObject, MediaSourceDelegate, MediaPeriodCallback, LoadConditionCheckable, MediaSourceEventListener {
    func perform(_ state: SEPlayerState)
}

protocol SEPlayerState {
    var statable: (any SEPlayerStatable)? { get set }

    var state: SEPlayer.State { get }
    var dependencies: SEPlayerStateDependencies { get }

    func didLoad()
    func prepare()

    func performNext(_ next: SEPlayer.State)

    func idle()
    func play()
    func stall()
    func pause()
    func ready()
    func seek(to time: Double, completion: (() -> Void)?)
    func loading()
    func end()
    func error(_ error: Error?)
}
