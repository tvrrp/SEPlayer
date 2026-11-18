//
//  AudioSessionController.swift
//  SEPlayer
//
//  Created by tvrrp on 11.10.2026.
//

import AVFAudio
import SEPlayerCommon

/// Configures the app's audio session for all of its players, and tells them when the system interrupts it.
///
/// The app has one audio session, so one controller serves all players: players made by ``SEPlayerFactory`` share
/// ``shared``. See ``AudioSessionPolicy`` for how the players share the session. Apps don't configure the session
/// themselves while players use it.
public final class AudioSessionController: @unchecked Sendable {
    public static let shared = AudioSessionController()

    // Each player reports how it uses the session: its policy, whether it plays, and whether it can be heard. The
    // player whose playback is the most exclusive decides how the session is configured. When no player is audible
    // any more and none keeps the session, it is deactivated so that other apps' audio resumes.
    //
    // During an interruption, audible players wait, and play on if the system says so once it ends. Otherwise they
    // pause.

    /// Where the session is configured: its calls block.
    private let queue: DispatchQueue
    private let session: AudioSessionInterface

    /// Used on `queue` only.
    private var clients: [UUID: Client] = [:]
    /// Counts the reports, so the latest report decides among players of equal exclusivity.
    private var reportCount = 0
    /// How the session was last configured, or `nil` when that isn't known, as after a reset.
    private var appliedConfiguration: Configuration?
    private var notificationObservers: [NSObjectProtocol] = []

    init(
        session: AudioSessionInterface = AVAudioSession.sharedInstance(),
        queue: DispatchQueue = DispatchQueue(label: "com.seplayer.audiosession", qos: .userInitiated)
    ) {
        self.session = session
        self.queue = queue
    }

    deinit {
        // `shared` lives as long as the app. Only controllers that tests create are released.
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Adds a player that doesn't use the session yet.
    func register(_ client: AudioSessionClient, id: UUID) {
        queue.async { [self] in
            startObservingNotifications()
            clients[id] = Client(client: client, usage: .unused, reportOrder: 0)
        }
    }

    func unregister(id: UUID) {
        queue.async { [self] in
            guard clients.removeValue(forKey: id) != nil else { return }

            applyRequiredConfiguration()
        }
    }

    /// Takes how a player uses the session now, and configures the session for all players.
    func report(_ usage: AudioSessionUsage, id: UUID) {
        queue.async { [self] in
            guard var client = clients[id], client.usage != usage else {
                return
            }

            reportCount += 1
            client.usage = usage
            client.reportOrder = reportCount
            if !usage.wantsToPlay {
                // A player that pauses on its own no longer waits for the interruption to end.
                client.isWaitingForInterruptionEnd = false
            }
            clients[id] = client

            applyRequiredConfiguration()

            // A player that was told to wait and is asked to play again plays, if the session could be configured.
            if let client = clients[id], !client.isWaitingForInterruptionEnd, client.lastCommand == .wait {
                send(.play, to: id)
            }
        }
    }

    /// Lets a waiting player play again, when it is asked to play after an interruption that didn't end with a
    /// resume. The session is activated for it again, and the player is paused if that fails.
    func resume(id: UUID) {
        queue.async { [self] in
            guard var client = clients[id] else { return }

            client.isWaitingForInterruptionEnd = false
            client.lastCommand = .play
            clients[id] = client

            // The session may have been deactivated meanwhile.
            appliedConfiguration?.isActive = false
            applyRequiredConfiguration()
        }
    }
}

// MARK: - Configuring the session

private extension AudioSessionController {
    /// How much a player's playback takes the session from other audio. The player with the highest decides how
    /// the session is configured.
    enum Exclusivity: Int, Comparable {
        /// The player doesn't need the session.
        case none
        case mixWithOthers
        case duckOthers
        case exclusive

        var silencesOthers: Bool { self >= .duckOthers }

        init(_ audibility: AudioSessionPolicy.Audibility) {
            switch audibility {
            case .exclusive: self = .exclusive
            case .duckOthers: self = .duckOthers
            case .mixWithOthers: self = .mixWithOthers
            }
        }

        static func < (lhs: Exclusivity, rhs: Exclusivity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Configuration: Equatable {
        /// An inactive session that mixes, so audio that plays without activating it doesn't stop other audio.
        static let idle = Configuration(
            exclusivity: .none,
            mode: .default,
            routeSharingPolicy: .default,
            isActive: false
        )

        var exclusivity: Exclusivity
        var mode: AVAudioSession.Mode
        var routeSharingPolicy: AVAudioSession.RouteSharingPolicy
        var isActive: Bool

        var options: AVAudioSession.CategoryOptions {
            switch exclusivity {
            case .exclusive: []
            case .duckOthers: [.duckOthers]
            case .none,
                 .mixWithOthers: [.mixWithOthers]
            }
        }
    }

    /// The configuration the players need now: the one of the player with the highest exclusivity.
    func requiredConfiguration() -> Configuration {
        var deciding: (exclusivity: Exclusivity, client: Client)?

        for (id, var client) in clients {
            let exclusivity = client.updateExclusivity()
            clients[id] = client
            guard exclusivity > .none else { continue }

            if let deciding {
                let isLower = exclusivity < deciding.exclusivity
                let isSameButReportedEarlier = exclusivity == deciding.exclusivity
                    && client.reportOrder < deciding.client.reportOrder
                if isLower || isSameButReportedEarlier {
                    continue
                }
            }

            deciding = (exclusivity, client)
        }

        guard let deciding else { return .idle }

        let policy = deciding.client.usage.policy
        return Configuration(
            exclusivity: deciding.exclusivity,
            mode: policy.mode,
            routeSharingPolicy: deciding.exclusivity == .exclusive ? policy.routeSharingPolicy : .default,
            isActive: true
        )
    }

    func applyRequiredConfiguration() {
        dispatchPrecondition(condition: .onQueue(queue))

        let required = requiredConfiguration()
        guard required != appliedConfiguration else { return }

        if let appliedConfiguration, mustDeactivate(appliedConfiguration, before: required) {
            deactivateSession()
        }

        do {
            try session.setCategory(
                .playback,
                mode: required.mode,
                policy: required.routeSharingPolicy,
                options: required.options
            )
            if required.isActive {
                try session.setActive(true, options: [])
            }
            appliedConfiguration = required

            if required.isActive {
                SELogger.info(.audioSession, "Session active for \(required.exclusivity) playback, mode \(required.mode.rawValue)")
            } else {
                SELogger.info(.audioSession, "Session inactive, mixing")
            }
        } catch {
            // The system refuses, as during a call or from the background: audible playback can't go on.
            SELogger.warning(.audioSession, "Configuring the session for \(required.exclusivity) playback failed: \(error)")
            appliedConfiguration = required.isActive ? .idle : nil
            pauseAudiblePlayers(reason: .audioSessionInterruption)
        }
    }

    /// Other apps' audio resumes only when the session that silenced it is deactivated, telling them so.
    func mustDeactivate(_ applied: Configuration, before required: Configuration) -> Bool {
        guard applied.isActive else { return false }

        let silencesOthersLess = applied.exclusivity.silencesOthers && required.exclusivity < applied.exclusivity
        return !required.isActive || silencesOthersLess
    }

    func deactivateSession() {
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            SELogger.info(.audioSession, "Deactivated the session: other audio may resume")
        } catch {
            // Audio still plays, as of a muted player. The configuration changes, but other apps aren't told.
            SELogger.warning(.audioSession, "Deactivating the session failed: \(error)")
        }
    }

    /// Pauses the players that play audibly and match `condition`. They no longer keep the session.
    func pauseAudiblePlayers(
        reason: PlayWhenReadyChangeReason,
        where condition: (Client) -> Bool = { _ in true }
    ) {
        for (id, var client) in clients where client.isAudiblyPlaying && condition(client) {
            client.keepsSession = false
            client.isWaitingForInterruptionEnd = false
            clients[id] = client
            send(.pause(reason), to: id)
        }
    }

    func send(_ command: AudioSessionCommand, to id: UUID) {
        guard let client = clients[id] else { return }

        clients[id]?.lastCommand = command
        client.client?.audioSessionController(self, didSend: command)
    }
}

// MARK: - System notifications

private extension AudioSessionController {
    struct Interruption: Sendable {
        let type: AVAudioSession.InterruptionType?
        let shouldResume: Bool
        let wasCausedBySuspension: Bool

        init(_ notification: Notification) {
            let userInfo = notification.userInfo
            let rawType = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            let rawReason = userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt

            type = rawType.flatMap(AVAudioSession.InterruptionType.init)
            shouldResume = rawOptions.map(AVAudioSession.InterruptionOptions.init)?.contains(.shouldResume) ?? false
            wasCausedBySuspension = rawReason.flatMap(AVAudioSession.InterruptionReason.init) == .appWasSuspended
        }
    }

    func startObservingNotifications() {
        guard notificationObservers.isEmpty else { return }

        // Until a player plays, audio that plays without activating the session doesn't stop other audio.
        try? session.setCategory(.playback, mode: .default, policy: .default, options: [.mixWithOthers])
        appliedConfiguration = .idle

        observe(AVAudioSession.interruptionNotification) { controller, notification in
            let interruption = Interruption(notification)
            controller.queue.async { controller.handleInterruption(interruption) }
        }
        observe(AVAudioSession.routeChangeNotification) { controller, notification in
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = rawReason.flatMap(AVAudioSession.RouteChangeReason.init)
            controller.queue.async { controller.handleRouteChange(reason) }
        }
        observe(AVAudioSession.mediaServicesWereResetNotification) { controller, _ in
            controller.queue.async { controller.handleMediaServicesReset() }
        }
    }

    func observe(
        _ name: Notification.Name,
        handler: @escaping @Sendable (AudioSessionController, Notification) -> Void
    ) {
        let observer = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }

            handler(self, notification)
        }
        notificationObservers.append(observer)
    }

    func handleInterruption(_ interruption: Interruption) {
        switch interruption.type {
        case .began:
            handleInterruptionBegan(interruption)
        case .ended:
            handleInterruptionEnded(interruption)
        case nil:
            break
        @unknown default:
            break
        }
    }

    func handleInterruptionBegan(_ interruption: Interruption) {
        guard !interruption.wasCausedBySuspension else {
            SELogger.info(.audioSession, "The session was deactivated while the app was suspended")
            appliedConfiguration = nil
            return
        }

        SELogger.info(.audioSession, "Interruption began")
        // The system deactivated the session: it is activated again for the next playback.
        appliedConfiguration?.isActive = false

        for (id, var client) in clients {
            // No player keeps the session. The ones that played audibly wait for the end of the interruption.
            client.keepsSession = false
            client.isWaitingForInterruptionEnd = client.isAudiblyPlaying
            clients[id] = client

            if client.isWaitingForInterruptionEnd {
                send(.wait, to: id)
            }
        }
    }

    func handleInterruptionEnded(_ interruption: Interruption) {
        let waitingIds = clients
            .filter { $0.value.isWaitingForInterruptionEnd }
            .map(\.key)
        for id in waitingIds {
            clients[id]?.isWaitingForInterruptionEnd = false
        }

        let action = interruption.shouldResume ? "resuming" : "not resuming"
        SELogger.info(.audioSession, "Interruption ended, \(action) \(waitingIds.count) players")

        guard interruption.shouldResume else {
            // Other audio may have started meanwhile, and isn't stopped again.
            for id in waitingIds {
                clients[id]?.keepsSession = false
                send(.pause(.audioSessionInterruption), to: id)
            }
            return
        }

        // If the session can't be configured, the players are paused instead.
        applyRequiredConfiguration()
        for id in waitingIds where clients[id]?.lastCommand == .wait {
            send(.play, to: id)
        }
    }

    func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason?) {
        guard reason == .oldDeviceUnavailable else { return }

        // As when headphones are unplugged: audio would go on from the speaker.
        SELogger.info(.audioSession, "The audio route went away")
        pauseAudiblePlayers(reason: .routeChanged) { $0.usage.policy.pausesWhenRouteIsLost }
    }

    func handleMediaServicesReset() {
        // The configuration of the session is lost. The audio outputs of the players rebuild themselves.
        SELogger.warning(.audioSession, "Media services were reset: configuring the session again")
        appliedConfiguration = nil
        applyRequiredConfiguration()
    }
}

// MARK: - Clients

private extension AudioSessionController {
    struct Client {
        weak var client: AudioSessionClient?
        var usage: AudioSessionUsage
        var reportOrder: Int
        /// Whether the player played audibly and keeps the session while it isn't audible, as its policy says.
        var keepsSession = false
        var isWaitingForInterruptionEnd = false
        var lastCommand: AudioSessionCommand = .play

        var isAudiblyPlaying: Bool {
            usage.hasMedia && usage.wantsToPlay && !usage.isInaudible
        }

        init(client: AudioSessionClient, usage: AudioSessionUsage, reportOrder: Int) {
            self.client = client
            self.usage = usage
            self.reportOrder = reportOrder
        }

        /// The exclusivity the player needs now. Updates whether it keeps the session.
        mutating func updateExclusivity() -> Exclusivity {
            let policy = usage.policy
            let audibleExclusivity = Exclusivity(policy.audibility)

            guard usage.hasMedia else {
                keepsSession = false
                return .none
            }

            if usage.wantsToPlay {
                if !usage.isInaudible {
                    keepsSession = true
                    return audibleExclusivity
                }
                if policy.whenMuted == .hold, keepsSession {
                    return audibleExclusivity
                }

                keepsSession = false
                // Muted audio still plays, so the session mixes with other audio for it.
                return .mixWithOthers
            }

            let sharesWhenPaused = policy.whenPaused == .shareWithOthers
            let sharesWhenMuted = usage.isInaudible && policy.whenMuted == .shareWithOthers
            if keepsSession, !sharesWhenPaused, !sharesWhenMuted {
                return audibleExclusivity
            }

            keepsSession = false
            return .none
        }
    }
}

/// How a player uses the audio session now.
struct AudioSessionUsage: Equatable {
    var policy: AudioSessionPolicy
    /// Whether the player has media to play: it isn't idle.
    var hasMedia: Bool
    /// Whether the player plays, or will once it has buffered.
    var wantsToPlay: Bool
    /// Whether what the player plays can't be heard: it is muted, or its volume is zero.
    var isInaudible: Bool

    static let unused = AudioSessionUsage(policy: .movie, hasMedia: false, wantsToPlay: false, isInaudible: false)
}

/// What the controller tells a player to do with its audible playback.
enum AudioSessionCommand: Equatable {
    case play
    /// Wait, ready to play, as during an interruption.
    case wait
    case pause(PlayWhenReadyChangeReason)
}

/// A player that uses the shared audio session.
protocol AudioSessionClient: AnyObject, Sendable {
    /// Called on no particular thread when the session changes what the player's playback may do.
    func audioSessionController(_ controller: AudioSessionController, didSend command: AudioSessionCommand)
}

// MARK: - The session

/// The calls of the audio session the controller makes.
protocol AudioSessionInterface: AnyObject {
    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        policy: AVAudioSession.RouteSharingPolicy,
        options: AVAudioSession.CategoryOptions
    ) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: AudioSessionInterface {}
