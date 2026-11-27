//
//  AudioSessionController.swift
//  SEPlayer
//
//  Created by tvrrp on 11.10.2026.
//

import AVFAudio
import SEPlayerCommon

/// Configures the app's audio session for its players and its other users, and tells the players when they may play.
///
/// The app has one audio session, so one controller serves it: players made by ``SEPlayerFactory`` share ``shared``.
/// See ``AudioSessionPolicy`` for how the players share the session. The app's other users of the session go through
/// the controller too: one that records activates the session with an ``AudioSessionRequest``, which says what the
/// players do meanwhile, and a client of the app's own can report playback to keep the session active, as between a
/// player that pauses and the next one that starts. When the session changes outside the controller, players pause or
/// play on, as ``externalChangeResponse`` says.
public final class AudioSessionController: @unchecked Sendable {
    /// What players do when something other than the controller changes or deactivates the session.
    public enum ExternalChangeResponse: Sendable {
        /// Audible players pause, as after an interruption that doesn't resume.
        case pausePlayers
        /// Players play on. The session is configured for them again when one starts.
        case keepPlaying
    }

    public static let shared = AudioSessionController()

    /// What players do when something other than the controller changes or deactivates the session. Changes of the
    /// category or mode are seen on every system, activation and deactivation from iOS 27 on.
    public var externalChangeResponse: ExternalChangeResponse {
        get { queue.sync { _externalChangeResponse } }
        set { queue.async { [self] in _externalChangeResponse = newValue } }
    }

    // Each player reports how it uses the session: its policy, whether it plays, and whether it can be heard. The
    // player whose playback is the most exclusive decides how the session is configured, unless a request holds the
    // session: the latest request decides then. When no player is audible any more, none keeps the session and no
    // request holds it, it is deactivated so that other apps' audio resumes.
    //
    // During an interruption, audible players wait, and play on if the system says so once it ends. Otherwise they
    // pause.

    /// Where the session is configured: its calls block.
    private let queue: DispatchQueue
    private let session: AudioSessionInterface

    /// Used on `queue` only.
    private var clients: [UUID: Client] = [:]
    /// The requests that hold the session, in the order they came.
    private var requests: [(id: UUID, request: AudioSessionRequest)] = []
    /// Counts the reports, so the latest report decides among players of equal exclusivity.
    private var reportCount = 0
    /// How the session was last configured, or `nil` when that isn't known, as after a reset.
    private var appliedConfiguration: SessionConfiguration?
    /// Whether something other than the controller configured the session last: it isn't configured over until a
    /// player or a request needs it.
    private var isConfiguredOutside = false
    /// When the controller last deactivated the session, in system uptime: a deactivation notified soon after may be
    /// its own.
    private var lastDeactivationTime: TimeInterval?
    private var notificationObservers: [NSObjectProtocol] = []
    private var _externalChangeResponse = ExternalChangeResponse.pausePlayers

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

    /// Adds a client that doesn't use the session yet.
    public func register(_ client: AudioSessionClient, id: UUID) {
        queue.async { [self] in
            startObservingNotifications()
            clients[id] = Client(client: client, usage: .unused, reportOrder: 0)
        }
    }

    /// Removes a client, and configures the session for the others.
    public func unregister(id: UUID) {
        queue.async { [self] in
            guard clients.removeValue(forKey: id) != nil else { return }

            applyRequiredConfiguration()
        }
    }

    /// Takes how a client uses the session now, and configures the session for all clients.
    public func report(_ usage: AudioSessionUsage, id: UUID) {
        queue.async { [self] in
            guard var client = clients[id], client.usage != usage else {
                return
            }

            reportCount += 1
            client.usage = usage
            client.reportOrder = reportCount
            if !usage.wantsToPlay {
                // A player that pauses on its own no longer waits for the interruption or the request to end.
                client.isWaitingForInterruptionEnd = false
                client.isWaitingForRequest = false
            }
            clients[id] = client

            applyRequiredConfiguration()

            // A player that was told to wait and is asked to play again plays, if the session could be configured.
            if let client = clients[id], !client.isWaiting, client.lastCommand == .wait {
                send(.play, to: id)
            }
        }
    }

    /// Lets a waiting client play again, when it is asked to play after an interruption that didn't end with a
    /// resume. The session is activated for it again, and the client is paused if that fails.
    public func resume(id: UUID) {
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

    /// Configures and activates the session for a request, and does with the players what the request says.
    ///
    /// Blocks while the system configures the session. A request with the same `id` is replaced.
    ///
    /// - Throws: The error of the session when the system refuses the configuration. The players play on then.
    public func activate(_ request: AudioSessionRequest, id: UUID) throws {
        try queue.sync { [self] in
            startObservingNotifications()
            let previousRequests = requests
            requests.removeAll { $0.id == id }
            requests.append((id, request))

            // Players stop before the session changes for the request, as for one that only records.
            let waitingIds = request.players == .keepPlaying ? [] : makePlayersWaitForRequest()
            do {
                try apply(requiredConfiguration())
            } catch {
                SELogger.warning(.audioSession, "The session refused the request for \(request.category.rawValue): \(error)")
                requests = previousRequests
                for id in waitingIds {
                    clients[id]?.isWaitingForRequest = false
                    send(.play, to: id)
                }
                applyRequiredConfiguration()
                throw error
            }

            SELogger.info(.audioSession, "Request for \(request.category.rawValue), mode \(request.mode.rawValue): players \(request.players)")
            updatePlayersForRequests()
        }
    }

    /// Ends a request: the session is configured for the players again, and the ones it made wait play on.
    public func deactivate(id: UUID) {
        queue.async { [self] in
            guard requests.contains(where: { $0.id == id }) else { return }

            requests.removeAll { $0.id == id }
            SELogger.info(.audioSession, "Request ended, \(requests.count) left")
            // The players that play on keep the session, so other audio isn't told to resume in between.
            updatePlayersForRequests()
            applyRequiredConfiguration()
        }
    }

    /// Configures the session for a client about to play, before it plays, so other audio stops first.
    ///
    /// Blocks while the system configures the session. Returns whether the client may play: when it may not, it is
    /// told to pause or wait.
    func activateForPlayback(id: UUID) -> Bool {
        queue.sync { [self] in
            guard var client = clients[id] else { return true }
            guard !client.isWaiting else { return false }

            switch requestedPlayerBehavior {
            case .pause:
                send(.pause(.audioSessionInterruption), to: id)
                return false
            case .waitAndResume:
                clients[id]?.isWaitingForRequest = true
                send(.wait, to: id)
                return false
            case .keepPlaying,
                 nil:
                break
            }

            reportCount += 1
            client.usage.hasMedia = true
            client.usage.wantsToPlay = true
            client.usage.isPlaying = true
            client.usage.isPaused = false
            client.reportOrder = reportCount
            clients[id] = client

            applyRequiredConfiguration()
            return appliedConfiguration?.isActive == true
        }
    }
}

// MARK: - Configuring the session

private extension AudioSessionController {
    /// How much a configuration takes the session from other audio. The player with the highest decides how the
    /// session is configured.
    enum Exclusivity: Int, Comparable {
        /// The player doesn't need the session.
        case none
        case mixWithOthers
        case duckOthers
        case exclusive

        var silencesOthers: Bool { self >= .duckOthers }

        var options: AVAudioSession.CategoryOptions {
            switch self {
            case .exclusive: []
            case .duckOthers: [.duckOthers]
            case .none,
                 .mixWithOthers: [.mixWithOthers]
            }
        }

        init(_ audibility: AudioSessionPolicy.Audibility) {
            switch audibility {
            case .exclusive: self = .exclusive
            case .duckOthers: self = .duckOthers
            case .mixWithOthers: self = .mixWithOthers
            }
        }

        init(_ options: AVAudioSession.CategoryOptions) {
            if options.contains(.duckOthers) {
                self = .duckOthers
            } else if options.contains(.mixWithOthers) {
                self = .mixWithOthers
            } else {
                self = .exclusive
            }
        }

        static func < (lhs: Exclusivity, rhs: Exclusivity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct SessionConfiguration: Equatable {
        /// An inactive session that mixes, so audio that plays without activating it doesn't stop other audio.
        static let idle = SessionConfiguration(
            category: .playback,
            mode: .default,
            routeSharingPolicy: .default,
            options: Exclusivity.none.options,
            isActive: false
        )

        var category: AVAudioSession.Category
        var mode: AVAudioSession.Mode
        var routeSharingPolicy: AVAudioSession.RouteSharingPolicy
        var options: AVAudioSession.CategoryOptions
        var isActive: Bool

        var exclusivity: Exclusivity { Exclusivity(options) }
    }

    /// The configuration needed now: the one of the latest request, or else of the player with the highest
    /// exclusivity.
    func requiredConfiguration() -> SessionConfiguration {
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

        if let request = requests.last?.request {
            return SessionConfiguration(
                category: request.category,
                mode: request.mode,
                routeSharingPolicy: request.routeSharingPolicy,
                options: request.options,
                isActive: true
            )
        }

        guard let deciding else { return .idle }

        let policy = deciding.client.usage.policy
        return SessionConfiguration(
            category: .playback,
            mode: policy.mode,
            routeSharingPolicy: deciding.exclusivity == .exclusive ? policy.routeSharingPolicy : .default,
            options: deciding.exclusivity.options,
            isActive: true
        )
    }

    /// Configures the session as needed now. When the system refuses, audible players pause.
    func applyRequiredConfiguration() {
        dispatchPrecondition(condition: .onQueue(queue))

        do {
            try apply(requiredConfiguration())
        } catch {
            // The system refuses, as during a call or from the background: audible playback can't go on.
            pauseAudiblePlayers(reason: .audioSessionInterruption)
        }
    }

    func apply(_ required: SessionConfiguration) throws {
        guard required != appliedConfiguration else { return }
        // What someone else configured stays until the session is needed here.
        guard required.isActive || !isConfiguredOutside else { return }

        if let appliedConfiguration, mustDeactivate(appliedConfiguration, before: required) {
            deactivateSession()
        }

        do {
            try session.setCategory(
                required.category,
                mode: required.mode,
                policy: required.routeSharingPolicy,
                options: required.options
            )
            if required.isActive {
                try session.setActive(true, options: [])
            }
        } catch {
            SELogger.warning(.audioSession, "Configuring the session for \(required.category.rawValue) failed: \(error)")
            appliedConfiguration = nil
            throw error
        }

        appliedConfiguration = required
        isConfiguredOutside = false
        if required.isActive {
            SELogger.info(.audioSession, "Session active for \(required.category.rawValue), \(required.exclusivity), mode \(required.mode.rawValue)")
        } else {
            SELogger.info(.audioSession, "Session inactive, mixing")
        }
    }

    /// Other apps' audio resumes only when the session that silenced it is deactivated, telling them so.
    func mustDeactivate(_ applied: SessionConfiguration, before required: SessionConfiguration) -> Bool {
        guard applied.isActive else { return false }

        let silencesOthersLess = applied.exclusivity.silencesOthers && required.exclusivity < applied.exclusivity
        return !required.isActive || silencesOthersLess
    }

    func deactivateSession() {
        lastDeactivationTime = ProcessInfo.processInfo.systemUptime
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
            client.isWaitingForRequest = false
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

// MARK: - Requests

private extension AudioSessionController {
    /// What the requests that hold the session make players do: the strictest of them.
    var requestedPlayerBehavior: AudioSessionRequest.PlayerBehavior? {
        requests.map(\.request.players).max()
    }

    /// Makes the players that want to play wait for the requests, and returns them.
    func makePlayersWaitForRequest() -> [UUID] {
        let ids = clients
            .filter { $0.value.usage.hasMedia && $0.value.usage.wantsToPlay && !$0.value.isWaitingForRequest }
            .map(\.key)
        for id in ids {
            clients[id]?.keepsSession = false
            clients[id]?.isWaitingForRequest = true
            send(.wait, to: id)
        }
        return ids
    }

    /// Lets the players that wait for the requests do what the requests that hold the session say: pause, wait, or
    /// play on.
    func updatePlayersForRequests() {
        let waitingIds = clients
            .filter { $0.value.isWaitingForRequest }
            .map(\.key)

        switch requestedPlayerBehavior {
        case .pause:
            for id in waitingIds {
                clients[id]?.isWaitingForRequest = false
                send(.pause(.audioSessionInterruption), to: id)
            }
        case .waitAndResume:
            break
        case .keepPlaying,
             nil:
            for id in waitingIds {
                clients[id]?.isWaitingForRequest = false
                guard clients[id]?.isWaitingForInterruptionEnd == false else {
                    continue
                }

                // As through a stall: the player keeps the session while it starts again.
                clients[id]?.keepsSession = true
                send(.play, to: id)
            }
        }
    }
}

// MARK: - System notifications

private extension AudioSessionController {
    func startObservingNotifications() {
        guard notificationObservers.isEmpty else { return }

        // Until a player plays, audio that plays without activating the session doesn't stop other audio.
        try? apply(.idle)

        // Interruptions keep the notification that every system posts: its replacements from iOS 27 on only tell the
        // controller of activations and deactivations made outside it.
        observe(AVAudioSession.interruptionNotification) { controller, notification in
            let interruption = Interruption(notification)
            controller.queue.async { controller.handleInterruption(interruption) }
        }
        if #available(iOS 27.0, tvOS 27.0, visionOS 27.0, *) {
            observe(AVAudioSession.didBecomeActiveNotification) { controller, _ in
                controller.queue.async { controller.handleActivation() }
            }
            observe(AVAudioSession.didBecomeInactiveNotification) { controller, notification in
                let key = AVAudioSession.deactivationContextKey
                let context = notification.userInfo?[key] as? AVAudioSession.DeactivationContext
                // The system deactivates the session for an interruption, which the interruption notification tells.
                guard context?.source != .system else { return }

                controller.queue.async { controller.handleDeactivationByApp() }
            }
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
            handleInterruptionBegan(wasCausedBySuspension: interruption.wasCausedBySuspension)
        case .ended:
            handleInterruptionEnded(shouldResume: interruption.shouldResume)
        case nil:
            break
        @unknown default:
            break
        }
    }

    func handleInterruptionBegan(wasCausedBySuspension: Bool) {
        guard !wasCausedBySuspension else {
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

    func handleInterruptionEnded(shouldResume: Bool) {
        let waitingIds = clients
            .filter { $0.value.isWaitingForInterruptionEnd }
            .map(\.key)
        for id in waitingIds {
            clients[id]?.isWaitingForInterruptionEnd = false
        }

        let action = shouldResume ? "resuming" : "not resuming"
        SELogger.info(.audioSession, "Interruption ended, \(action) \(waitingIds.count) players")

        guard shouldResume else {
            // Other audio may have started meanwhile, and isn't stopped again.
            for id in waitingIds {
                clients[id]?.keepsSession = false
                send(.pause(.audioSessionInterruption), to: id)
            }
            return
        }

        // If the session can't be configured, the players are paused instead.
        applyRequiredConfiguration()
        for id in waitingIds where clients[id]?.lastCommand == .wait && clients[id]?.isWaitingForRequest == false {
            send(.play, to: id)
        }
    }

    /// The session became active, from iOS 27 on: when the controller didn't activate it, someone else did.
    func handleActivation() {
        guard appliedConfiguration?.isActive != true else {
            SELogger.debug(.audioSession, "The session became active, as the controller activated it")
            return
        }

        SELogger.info(.audioSession, "The session was activated outside the controller")
        appliedConfiguration = nil
        isConfiguredOutside = true
    }

    /// The app deactivated the session, from iOS 27 on: the controller did, or someone else did while the
    /// controller had it active.
    func handleDeactivationByApp() {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastDeactivationTime, now - lastDeactivationTime < Self.ownDeactivationNoticeDuration {
            SELogger.debug(.audioSession, "The session became inactive, as the controller deactivated it")
        } else if appliedConfiguration?.isActive == true {
            respondToExternalChange("deactivated", isDeactivation: true)
        }
    }

    func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason?) {
        switch reason {
        case .oldDeviceUnavailable:
            // As when headphones are unplugged: audio would go on from the speaker.
            SELogger.info(.audioSession, "The audio route went away")
            pauseAudiblePlayers(reason: .routeChanged) { $0.usage.policy.pausesWhenRouteIsLost }
        case .categoryChange:
            // The controller's own changes leave the session as it configured it.
            guard let appliedConfiguration else { return }
            guard session.category != appliedConfiguration.category || session.mode != appliedConfiguration.mode else {
                return
            }

            respondToExternalChange(
                "configured for \(session.category.rawValue), mode \(session.mode.rawValue),",
                isDeactivation: false
            )
        default:
            break
        }
    }

    /// Players pause or play on, as ``externalChangeResponse`` says. The session isn't configured over what someone
    /// else configured until it is needed here.
    func respondToExternalChange(_ change: String, isDeactivation: Bool) {
        SELogger.info(.audioSession, "The session was \(change) outside the controller")
        appliedConfiguration = nil
        isConfiguredOutside = true

        switch _externalChangeResponse {
        case .pausePlayers:
            pauseAudiblePlayers(reason: .audioSessionInterruption)
        case .keepPlaying:
            // Deactivated, the session is activated again for the players that play.
            if isDeactivation {
                applyRequiredConfiguration()
            }
        }
    }

    func handleMediaServicesReset() {
        // The configuration of the session is lost. The audio outputs of the players rebuild themselves.
        SELogger.warning(.audioSession, "Media services were reset: configuring the session again")
        appliedConfiguration = nil
        isConfiguredOutside = false
        applyRequiredConfiguration()
    }
}

// MARK: - Interruptions before iOS 27

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
}

// MARK: - Clients

private extension AudioSessionController {
    struct Client {
        weak var client: AudioSessionClient?
        var usage: AudioSessionUsage
        var reportOrder: Int
        /// Whether the player played audibly and keeps the session: while it stalls, seeks or scrubs, and while it is
        /// paused or muted, as its policy says.
        var keepsSession = false
        var isWaitingForInterruptionEnd = false
        /// Whether the player waits until no request holds the session.
        var isWaitingForRequest = false
        var lastCommand: AudioSessionCommand = .play

        var isWaiting: Bool { isWaitingForInterruptionEnd || isWaitingForRequest }

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

            // Playback takes the session once it plays, not while it buffers to start. Having played, the player
            // keeps it through stalls, seeks and scrubbing, until it is paused.
            if usage.isPlaying || (keepsSession && !usage.isPaused) {
                if !usage.isInaudible {
                    keepsSession = true
                    return audibleExclusivity
                }
                if policy.whenMuted == .hold, keepsSession {
                    return audibleExclusivity
                }

                keepsSession = false
                // Muted audio still plays, so the session mixes with other audio for it.
                return usage.isPlaying ? .mixWithOthers : .none
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

// MARK: - The session

/// The calls of the audio session the controller makes.
protocol AudioSessionInterface: AnyObject {
    var category: AVAudioSession.Category { get }
    var mode: AVAudioSession.Mode { get }

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        policy: AVAudioSession.RouteSharingPolicy,
        options: AVAudioSession.CategoryOptions
    ) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: AudioSessionInterface {}

private extension AudioSessionController {
    /// How soon after the controller deactivated the session a deactivation notification is taken for its own.
    static let ownDeactivationNoticeDuration: TimeInterval = 1
}
