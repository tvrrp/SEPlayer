//
//  AudioSessionManager.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 19.07.2025.
//

import AVFAudio

public enum PlayerCommand {
    case doNotPlay
    case playWhenReady
}

public protocol AudioSessionObserver: AnyObject {
    func executePlayerCommand(_ command: PlayerCommand, isolation: isolated PlayerActor) async
    func audioDeviceDidChange()
}

public protocol IAudioSessionManager {
    var observers: MulticastDelegate<AudioSessionObserver> { get }
    func registerPlayer(_ player: AudioSessionObserver, playerId: UUID, playerIsolation: PlayerActor)
    func removePlayer(_ player: AudioSessionObserver, playerId: UUID)
    func setPrefferedStrategy(strategy: AudioCategoryStrategy, for playerId: UUID)
    func updateAudioState(playerId: UUID, for playerState: PlayerState, playWhenReady: Bool)
//    func registerObserver(_ observer: AudioSessionObserver, strategy: AudioCategoryStrategy)
//    func removeObserver(_ observer: AudioSessionObserver)
}

public final class AudioSessionManager: IAudioSessionManager {
    static let shared: IAudioSessionManager = AudioSessionManager()

    public let observers = MulticastDelegate<AudioSessionObserver>(isThreadSafe: true)
    private let audioSession = AVAudioSession.sharedInstance()
    private let lock = NSRecursiveLock()

    private var registeredPlayers = [UUID: PlayerActor]()
    private var strategies: [(playerId: UUID, strategy: AudioCategoryStrategy)] = []

    private var currentCategory: AudioCategoryStrategy = .default

    private init() {
        let center = NotificationCenter.default

        center.addObserver(self,
                           selector: #selector(handleRouteChange),
                           name: AVAudioSession.routeChangeNotification,
                           object: nil)
    }

    public func registerPlayer(_ player: AudioSessionObserver, playerId: UUID, playerIsolation: PlayerActor) {
        lock.withLock {
            observers.addDelegate(player)
            registeredPlayers[playerId] = playerIsolation
        }
    }

    public func removePlayer(_ player: AudioSessionObserver, playerId: UUID) {
        lock.withLock {
            observers.removeDelegate(player)
            registeredPlayers[playerId] = nil
        }
    }

    public func setPrefferedStrategy(strategy: AudioCategoryStrategy, for playerId: UUID) {
//        lock.lock(); defer { lock.unlock() }
//
//        if strategy == .mixWithOthers {
//            observers.invokeDelegates { $0.executePlayerCommand(.doNotPlay) }
//
//            if currentCategory == .playback {
//                try! audioSession.setActive(false, options: .notifyOthersOnDeactivation)
//            }
//
//            try! audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
//            try! audioSession.setActive(true)
//
//            observers.invokeDelegates { $0.executePlayerCommand(.playWhenReady) }
//        } else if strategy == .playback {
//            observers.invokeDelegates { $0.executePlayerCommand(.doNotPlay) }
//
//            try! audioSession.setCategory(.playback, mode: .moviePlayback, options: [])
//            try! audioSession.setActive(true)
//
//            observers.invokeDelegates { $0.executePlayerCommand(.playWhenReady) }
//        }
//
//        currentCategory = strategy
    }

    public func updateAudioState(playerId: UUID, for playerState: PlayerState, playWhenReady: Bool) {
//        lock.lock(); defer { lock.unlock() }
//
//        if playWhenReady {
//            
//        } else {
//            
//        }
    }

    private func updateAudioSessionState() {
        
    }

    @objc func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable:
            observers.invokeDelegates { $0.audioDeviceDidChange() }
        default:
            return
        }
    }
}
