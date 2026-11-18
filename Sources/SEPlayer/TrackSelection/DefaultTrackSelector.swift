//
//  DefaultTrackSelector.swift
//  SEPlayer
//
//  Created by tvrrp on 18.02.2026.
//

import AVFoundation
import SEPlayerCommon
#if canImport(MediaAccessibility)
import MediaAccessibility
#endif

public class DefaultTrackSelector: MappingTrackSelector, RendererCapabilitiesListener {
    private let trackSelectionFactory: SETrackSelectionFactory
    private let lock: UnfairLock
    private var parameters: Parameters
    /// What the codec and dynamic range rules of ``VariantFilters`` depend on, or `nil` to not apply them.
    var variantFilterEnvironment: (() -> VariantFilters.Environment)? = { .current() } {
        didSet { lock.withLock { cachedVariantFilterEnvironment = nil } }
    }
    /// The environment as of its last change. Asking for it is a call to the media server, too slow for every
    /// selection: it is asked once, ahead of the first one, and again after the system says it changed.
    private var cachedVariantFilterEnvironment: VariantFilters.Environment? // Guarded by lock.
    /// The size the video output shows the picture at, in pixels, or `nil` before it says.
    private var videoOutputSize: CGSize? // Guarded by lock.

    public convenience init(parameters: TrackSelectionParameters = .defaultParameters) {
        self.init(
            parameters: parameters,
            trackSelectionFactory: AdaptiveTrackSelection.Factory()
        )
    }

    public init(
        parameters: TrackSelectionParameters = .defaultParameters,
        trackSelectionFactory: SETrackSelectionFactory
    ) {
        self.trackSelectionFactory = trackSelectionFactory
        self.lock = UnfairLock()
        if let parameters = parameters as? Parameters {
            self.parameters = parameters
        } else {
            self.parameters = Parameters.default.buildUpon().set(parameters).build()
        }

        super.init()

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(audioCapabilitiesDidChange),
            name: AVAudioSession.spatialPlaybackCapabilitiesChangedNotification,
            object: nil
        )
        // The variants that can be played depend on these.
        center.addObserver(
            self,
            selector: #selector(variantFilterEnvironmentDidChange),
            name: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(variantFilterEnvironmentDidChange),
            name: AVPlayer.eligibleForHDRPlaybackDidChangeNotification,
            object: nil
        )
        if #available(iOS 17.2, tvOS 17.2, *) {
            center.addObserver(
                self,
                selector: #selector(audioCapabilitiesDidChange),
                name: AVAudioSession.renderingModeChangeNotification,
                object: nil
            )
            center.addObserver(
                self,
                selector: #selector(audioCapabilitiesDidChange),
                name: AVAudioSession.renderingCapabilitiesChangeNotification,
                object: nil
            )
        }
        // Ready before the first selection, which would otherwise wait for the media server.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = self?.currentVariantFilterEnvironment()
        }
    }

    @objc private func audioCapabilitiesDidChange() {
        invalidate()
    }

    @objc private func variantFilterEnvironmentDidChange() {
        lock.withLock { cachedVariantFilterEnvironment = nil }
        invalidate()
    }

    /// The environment of the variant rules, asked for once and kept until it changes.
    private func currentVariantFilterEnvironment() -> VariantFilters.Environment? {
        guard let provider = variantFilterEnvironment else { return nil }
        if let cached = lock.withLock({ cachedVariantFilterEnvironment }) { return cached }
        let environment = provider()
        lock.withLock { cachedVariantFilterEnvironment = environment }
        return environment
    }

    public override func release() {
        super.release()
    }

    public override func setVideoOutputSize(_ size: CGSize?) {
        let (changed, isUsed) = lock.withLock {
            defer { videoOutputSize = size }
            return (videoOutputSize != size, parameters.isViewportSizeLimitedByVideoOutputSize)
        }
        if changed, isUsed {
            invalidate()
        }
    }

    public override func getParameters() -> Parameters {
        lock.withLock { parameters }
    }

    public override func setParameters(_ parameters: TrackSelectionParameters) {
        setParameters(parameters, application: .deferred)
    }

    public override func setParameters(_ parameters: TrackSelectionParameters, application: TrackSelectionApplication) {
        if let parameters = parameters as? Parameters {
            setParametersInternal(parameters, application: application)
            return
        }

        let mergedParameters = Parameters.Builder(params: getParameters()).set(parameters).build()
        setParametersInternal(mergedParameters, application: application)
    }

    public func setParameters(_ parametersBuilder: Parameters.Builder) {
        setParametersInternal(parametersBuilder.build())
    }

    public func buildUponParameters() -> Parameters.Builder {
        getParameters().buildUpon()
    }

    private func setParametersInternal(_ parameters: Parameters, application: TrackSelectionApplication = .deferred) {
        let parametersChanged = lock.withLock {
            let parametersChanged = !self.parameters.isEqual(to: parameters)
            self.parameters = parameters
            return parametersChanged
        }

        if parametersChanged {
            // TODO: warn about audio
            invalidate(application: application)
        }
    }

    public override func getRendererCapabilitiesListener() -> RendererCapabilitiesListener? {
        self
    }

    public func onRendererCapabilitiesChanged(_ renderer: SERenderer) {
        maybeInvalidateForRendererCapabilitiesChange(renderer)
    }

    public override func selectTracks(
        mappedTrackInfo: MappingTrackSelector.MappedTrackInfo,
        rendererFormatSupports: [[[RendererCapabilities.Support]]],
        rendererMixedMimeTypeAdaptationSupport: [RendererCapabilities.Support.AdaptiveSupport],
        mediaPeriodId: MediaPeriodId,
        timeline: Timeline
    ) throws -> ([RendererConfiguration?], [SETrackSelection?]) {
        let parameters = lock.withLock { self.parameters }
        var definitions = try selectAllTracks(
            mappedTrackInfo: mappedTrackInfo,
            rendererFormatSupports: rendererFormatSupports,
            rendererMixedMimeTypeAdaptationSupport: rendererMixedMimeTypeAdaptationSupport,
            params: parameters
        )
        applyTrackSelectionOverrides(
            mappedTrackInfo: mappedTrackInfo,
            params: parameters,
            outDefinitions: &definitions
        )

        for index in 0..<mappedTrackInfo.rendererCount {
            if parameters.rendererDisabledFlags[index] == true || parameters.disabledTrackTypes.contains(mappedTrackInfo.rendererTrackTypes[index]) {
                definitions[index] = nil
            }
        }

        let rendererTrackSelections = trackSelectionFactory.createTrackSelections(
            definitions: definitions,
            bandwidthMeter: bandwidthMeter,
            mediaPeriodId: mediaPeriodId,
            timeline: timeline
        )

        var rendererConfigurations = [RendererConfiguration?]()
        for index in 0..<mappedTrackInfo.rendererCount {
            let rendererType = mappedTrackInfo.rendererTrackTypes[index]
            let forceRendererDisabled = parameters.rendererDisabledFlags[index] == true || parameters.disabledTrackTypes.contains(rendererType)
            let rendererEnabled = !forceRendererDisabled && (rendererType == .none || rendererTrackSelections[index] != nil)
            rendererConfigurations.append(rendererEnabled ? .init() : nil)
        }

        if parameters.tunnelingEnabled {
            
        }
        // TODO: tunneling and offload

        return (rendererConfigurations, rendererTrackSelections)
    }

    private func selectAllTracks(
        mappedTrackInfo: MappingTrackSelector.MappedTrackInfo,
        rendererFormatSupports: [[[RendererCapabilities.Support]]],
        rendererMixedMimeTypeAdaptationSupport: [RendererCapabilities.Support.AdaptiveSupport],
        params: Parameters
    ) throws -> [SETrackSelectionDefinition?] {
        let rendererCount = mappedTrackInfo.rendererCount
        var definitions = Array<SETrackSelectionDefinition?>(repeating: nil, count: rendererCount)

        let selectedAudio = try selectAudioTrack(
            mappedTrackInfo: mappedTrackInfo,
            rendererFormatSupports: rendererFormatSupports,
            rendererMixedMimeTypeAdaptationSupport: rendererMixedMimeTypeAdaptationSupport,
            params: params
        )

        var selectedAudioLanguage: String?
        if let (selectedAudio, index) = selectedAudio {
            definitions[index] = selectedAudio
            selectedAudioLanguage = selectedAudio.group[selectedAudio.tracks[0]].language
        }

        let selectedVideo = try selectVideoTrack(
            mappedTrackInfo: mappedTrackInfo,
            rendererFormatSupports: rendererFormatSupports,
            mixedMimeTypeSupports: rendererMixedMimeTypeAdaptationSupport,
            params: params,
            selectedAudioLanguage: selectedAudioLanguage
        )

        let selectedImage = params.isPrioritizeImageOverVideoEnabled || selectedVideo == nil
            ? try selectImageTrack(mappedTrackInfo: mappedTrackInfo, rendererFormatSupports: rendererFormatSupports, params: params)
            : nil

        if let (selectedImage, index) = selectedImage {
            definitions[index] = selectedImage
        } else if let (selectedVideo, index) = selectedVideo {
            definitions[index] = selectedVideo
        }

        let selectedText = try selectTextTrack(
            mappedTrackInfo: mappedTrackInfo,
            rendererFormatSupports: rendererFormatSupports,
            rendererMixedMimeTypeAdaptationSupport: rendererMixedMimeTypeAdaptationSupport,
            params: params,
            selectedAudioLanguage: selectedAudioLanguage
        )

        if let (selectedText, index) = selectedText {
            definitions[index] = selectedText
        }

        for index in 0..<rendererCount {
            let trackType = mappedTrackInfo.rendererTrackTypes[index]
            if ![.video, .audio, .text, .image].contains(trackType) {
                definitions[index] = try selectOtherTrack(
                    trackType: trackType,
                    groups: mappedTrackInfo.rendererTrackGroups[index],
                    formatSupport: rendererFormatSupports[index],
                    params: params
                )
            }
        }

        return definitions
    }

    /// The size video shows at, as the parameters say: the video output's, which is exact, or the one set.
    private func viewport(for params: Parameters) -> (size: CGSize, orientationMayChange: Bool) {
        if params.isViewportSizeLimitedByVideoOutputSize, let size = lock.withLock({ videoOutputSize }) {
            return (size, false)
        }
        // TODO: the physical display size, with isViewportSizeLimitedByPhysicalDisplaySize
        return (params.viewportSize, params.viewportOrientationMayChange)
    }

    private func selectVideoTrack(
        mappedTrackInfo: MappingTrackSelector.MappedTrackInfo,
        rendererFormatSupports: [[[RendererCapabilities.Support]]],
        mixedMimeTypeSupports: [RendererCapabilities.Support.AdaptiveSupport],
        params: Parameters,
        selectedAudioLanguage: String?
    ) throws -> (SETrackSelectionDefinition, Int)? {
        let (viewport, viewportOrientationMayChange) = viewport(for: params)
        let environment = currentVariantFilterEnvironment()
        return try selectTrackForType(
            .video,
            mappedTrackInfo: mappedTrackInfo,
            formatSupport: rendererFormatSupports,
            createTrackInfo: { rendererIndex, group, support in
                // The codec and dynamic range rules leave out some variants before any is picked.
                let allowedTracks = environment.map {
                    Set(VariantFilters.allowedIndices(of: group.map { $0 }, environment: $0))
                }
                return VideoTrackInfo.createForTrackGroup(
                    rendererIndex: rendererIndex,
                    trackGroup: group,
                    params: params,
                    formatSupport: support,
                    selectedAudioLanguage: selectedAudioLanguage,
                    mixedMimeTypeAdaptationSupport: mixedMimeTypeSupports[rendererIndex],
                    viewport: viewport,
                    viewportOrientationMayChange: viewportOrientationMayChange,
                    allowedTracks: allowedTracks
                )
            },
            comparator: VideoTrackInfo.compareSelections
        )
    }

    private func selectAudioTrack(
        mappedTrackInfo: MappingTrackSelector.MappedTrackInfo,
        rendererFormatSupports: [[[RendererCapabilities.Support]]],
        rendererMixedMimeTypeAdaptationSupport: [RendererCapabilities.Support.AdaptiveSupport],
        params: Parameters,
    ) throws -> (SETrackSelectionDefinition, Int)? {
        let hasVideoRendererWithMappedTracks = zip(
            mappedTrackInfo.rendererTrackTypes,
            mappedTrackInfo.rendererTrackGroups
        ).first(where: { (type, trackGroup) in
            if type == .video, trackGroup.count > 0 {
                return true
            }

            return false
        }) != nil

        return try selectTrackForType(
            .audio,
            mappedTrackInfo: mappedTrackInfo,
            formatSupport: rendererFormatSupports,
            createTrackInfo: { rendererIndex, group, support in
                AudioTrackInfo.createForTrackGroup(
                    rendererIndex: rendererIndex,
                    trackGroup: group,
                    params: params,
                    formatSupport: support,
                    hasMappedVideoTracks: hasVideoRendererWithMappedTracks,
                    withinAudioChannelCountConstraints: { _ in true }, // TODO: proper check
                    mixedMimeTypeAdaptationSupport: rendererMixedMimeTypeAdaptationSupport[rendererIndex]
                )
            },
            comparator: AudioTrackInfo.compareSelections
        )
    }

    private func selectTextTrack(
        mappedTrackInfo: MappingTrackSelector.MappedTrackInfo,
        rendererFormatSupports: [[[RendererCapabilities.Support]]],
        rendererMixedMimeTypeAdaptationSupport: [RendererCapabilities.Support.AdaptiveSupport],
        params: Parameters,
        selectedAudioLanguage: String?
    ) throws -> (SETrackSelectionDefinition, Int)? {
        let preferredCaptioningLanguage = params.usePreferredTextLanguagesAndRoleFlagsFromCaptioningManager
            ? Self.getPreferredLanguageFromCaptioningSettings()
            : nil

        return try selectTrackForType(
            .text,
            mappedTrackInfo: mappedTrackInfo,
            formatSupport: rendererFormatSupports,
            createTrackInfo: { rendererIndex, group, support in
                TextTrackInfo.createForTrackGroup(
                    rendererIndex: rendererIndex,
                    trackGroup: group,
                    params: params,
                    formatSupport: support,
                    selectedAudioLanguage: selectedAudioLanguage,
                    preferredCaptioningLanguage: preferredCaptioningLanguage
                )
            },
            comparator: TextTrackInfo.compareSelections
        )
    }

    /// The language of the subtitles the user asked to always show in Settings › Accessibility › Subtitles & Captioning,
    /// or `nil` if they didn't.
    private static func getPreferredLanguageFromCaptioningSettings() -> String? {
        #if canImport(MediaAccessibility)
        guard MACaptionAppearanceGetDisplayType(.user) == .alwaysOn else {
            return nil
        }
        let selectedLanguages = MACaptionAppearanceCopySelectedLanguages(.user).takeRetainedValue() as? [String] ?? []
        return Util.normalizeLanguageCode(selectedLanguages.first ?? Locale.preferredLanguages.first)
        #else
        return nil
        #endif
    }

    private func selectOtherTrack(
        trackType: TrackType,
        groups: TrackGroupArray,
        formatSupport: [[RendererCapabilities.Support]],
        params: Parameters,
    ) throws -> SETrackSelectionDefinition? {
        return nil
    }

    private func selectImageTrack(
        mappedTrackInfo: MappingTrackSelector.MappedTrackInfo,
        rendererFormatSupports: [[[RendererCapabilities.Support]]],
        params: Parameters,
    ) throws -> (SETrackSelectionDefinition, Int)? {
        return nil
    }

    private func selectTrackForType<T: TrackInfo>(
        _ type: TrackType,
        mappedTrackInfo: MappingTrackSelector.MappedTrackInfo,
        formatSupport: [[[RendererCapabilities.Support]]],
        createTrackInfo: (_ rendererIndex: Int, _ trackGroup: TrackGroup, _ formatSupports: [RendererCapabilities.Support]) -> [T],
        comparator: ([T], [T]) -> CFComparisonResult
    ) throws -> (SETrackSelectionDefinition, Int)? {
        var possibleSelections = [[T]]()
        for rendererIndex in 0..<mappedTrackInfo.rendererCount {
            guard type == mappedTrackInfo.rendererTrackTypes[rendererIndex] else {
                continue
            }
            let groups = mappedTrackInfo.rendererTrackGroups[rendererIndex]

            for (groupIndex, group) in groups.enumerated() {
                let groupSupport = formatSupport[rendererIndex][groupIndex]
                let trackInfos = createTrackInfo(rendererIndex, group, groupSupport)
                var usedTrackInSelection = Array(repeating: false, count: group.count)

                for (trackIndex, trackInfo) in trackInfos.enumerated() {
                    let eligibility = trackInfo.getSelectionEligibility()
                    if usedTrackInSelection[trackIndex] || eligibility == .none {
                        continue
                    }

                    var selection: [T]
                    if eligibility == .fixed {
                        selection = [trackInfo]
                    } else {
                        selection = []
                        selection.append(trackInfo)

                        for i in (trackIndex + 1)..<group.count {
                            let otherTrackInfo = trackInfos[i]
                            if otherTrackInfo.getSelectionEligibility() == .adaptive {
                                if trackInfo.isCompatibleForAdaptationWith(otherTrackInfo) {
                                    selection.append(otherTrackInfo)
                                    usedTrackInSelection[i] = true
                                }
                            }
                        }
                    }

                    possibleSelections.append(selection)
                }
            }
        }

        guard !possibleSelections.isEmpty,
              let bestSelection = possibleSelections.maxElement(comparator) else {
            return nil
        }

        let trackIndices = bestSelection.map { $0.trackIndex }

        return (
            SETrackSelectionDefinition(group: bestSelection[0].trackGroup, tracks: trackIndices),
            bestSelection[0].rendererIndex
        )
    }

    private func maybeInvalidateForRendererCapabilitiesChange(_ renderer: SERenderer) {
        if lock.withLock({ parameters.allowInvalidateSelectionsOnRendererCapabilitiesChange}) {
            invalidateForRendererCapabilitiesChange(renderer)
        }
    }

    private func applyTrackSelectionOverrides(
        mappedTrackInfo: MappingTrackSelector.MappedTrackInfo,
        params: TrackSelectionParameters,
        outDefinitions: inout [SETrackSelectionDefinition?]
    ) {
        var overridesByType = [TrackType: TrackSelectionOverride]()

        mappedTrackInfo.rendererTrackGroups.forEach {
            collectTrackSelectionOverrides(
                trackGroups: $0,
                params: params,
                overridesByType: &overridesByType
            )
        }

        collectTrackSelectionOverrides(
            trackGroups: mappedTrackInfo.unmappedTrackGroups,
            params: params,
            overridesByType: &overridesByType
        )

        for rendererIndex in 0..<mappedTrackInfo.rendererCount {
            let trackType = mappedTrackInfo.rendererTrackTypes[rendererIndex]
            guard let overrideForType = overridesByType[trackType] else {
                continue
            }

            let selection: SETrackSelectionDefinition? = if !overrideForType.trackIndices.isEmpty,
                mappedTrackInfo.rendererTrackGroups[rendererIndex].firstIndex(of: overrideForType.mediaTrackGroup) != nil {
                SETrackSelectionDefinition(group: overrideForType.mediaTrackGroup, tracks: overrideForType.trackIndices)
            } else {
                nil
            }

            outDefinitions[rendererIndex] = selection
        }
    }

    private func collectTrackSelectionOverrides(
        trackGroups: TrackGroupArray,
        params: TrackSelectionParameters,
        overridesByType: inout [TrackType: TrackSelectionOverride]
    ) {
        for trackGroup in trackGroups {
            guard let override = params.overrides[trackGroup] else {
                continue
            }

            let existingOverride = overridesByType[override.type]
            if existingOverride == nil ||
               (existingOverride?.trackIndices.isEmpty == true &&
                override.trackIndices.isEmpty == false) {
                overridesByType[override.type] = override
            }
        }
    }
}

public extension DefaultTrackSelector {
    enum SelectionEligibility {
        case none
        case fixed
        case adaptive
    }

    class TrackInfo {
        let rendererIndex: Int
        let trackGroup: TrackGroup
        let trackIndex: Int
        let format: Format

        init(rendererIndex: Int, trackGroup: TrackGroup, trackIndex: Int) {
            self.rendererIndex = rendererIndex
            self.trackGroup = trackGroup
            self.trackIndex = trackIndex
            self.format = trackGroup[trackIndex]
        }

        func getSelectionEligibility() -> SelectionEligibility {
            fatalError("To override")
        }

        func isCompatibleForAdaptationWith(_ otherTrack: TrackInfo) -> Bool {
            fatalError("To override")
        }

        static func getRoleFlagMatchScore(trackRoleFlags: RoleFlags, preferredRoleFlags: RoleFlags) -> Int {
            if !trackRoleFlags.isEmpty && trackRoleFlags == preferredRoleFlags {
                // Prefer perfect match over partial matches.
                return Int.max
            }

            return trackRoleFlags.intersection(preferredRoleFlags).rawValue.nonzeroBitCount
        }

        static func getBestLabelMatchIndex(format: Format, preferredLabels: [String]) -> Int {
            for i in 0..<preferredLabels.count {
                for label in format.labels {
                    if label == preferredLabels[i] { return i }
                }
            }
            return Int.max
        }

        static func getFormatLanguageScore(
            format: Format,
            language: String?,
            allowUndeterminedFormatLanguage: Bool
        ) -> Int {
            if language?.isEmpty == false && language == format.language {
                // Full literal match of non-empty languages, including matches of an explicit "und" query.
                return 4
            }

            let language = normalizeUndeterminedLanguageToNil(language)
            let formatLanguage = normalizeUndeterminedLanguageToNil(format.language)

            if formatLanguage == nil || language == nil {
                // At least one of the languages is undetermined.
                return allowUndeterminedFormatLanguage && formatLanguage == nil ? 1 : 0
            }

            // Partial match where one language is a subset of the other (e.g. "zh-hans" and "zh-hans-hk")
            if let language, formatLanguage?.hasPrefix(language) == true {
                return 3
            }

            if let formatLanguage, language?.hasPrefix(formatLanguage) == true {
                return 3
            }

            let formatMainLanguage = formatLanguage?.components(separatedBy: "-")[0]
            let queryMainLanguage = language?.components(separatedBy: "-")[0]

            if formatMainLanguage == queryMainLanguage {
                // Partial match where only the main language tag is the same (e.g. "fr-fr" and "fr-ca")
                return 2
            }

            return 0
        }

        static func normalizeUndeterminedLanguageToNil(_ language: String?) -> String? {
            if language?.isEmpty != false || language == "und" {
                return nil
            } else {
                return language
            }
        }

        static func formatValueOrderingReversed(_ first: Int, _ second: Int) -> CFComparisonResult {
            formatValueOrdering(second, first)
        }

        static func formatValueOrdering(_ first: Int, _ second: Int) -> CFComparisonResult {
            if first == Format.noValue {
                return (second == Format.noValue) ? .compareEqualTo : .compareLessThan
            }
            if second == Format.noValue {
                return .compareGreaterThan
            }
            if first < second { return .compareLessThan }
            if first > second { return .compareGreaterThan }
            return .compareEqualTo
        }
    }

    final class VideoTrackInfo: TrackInfo {
        private let isWithinMaxConstraints: Bool
        private let parameters: Parameters
        private let isWithinMinConstraints: Bool
        private let isWithinRendererCapabilities: Bool
        private let hasReasonableFrameRate: Bool
        private let bitrate: Int
        private let pixelCount: Int
        private let preferredMimeTypeMatchIndex: Int
        private let preferredLanguageIndex: Int
        private let preferredLanguageScore: Int
        private let preferredRoleFlagsScore: Int
        private let preferredLabelMatchIndex: Int
        private let hasMainOrNoRoleFlag: Bool
        private let selectedAudioLanguageScore: Int
        private let allowMixedMimeTypes: Bool
        private let selectionEligibility: SelectionEligibility
        private let usesPrimaryDecoder: Bool
        private let usesHardwareAcceleration: Bool
        private let codecPreferenceScore: Int

        init(
            rendererIndex: Int,
            trackGroup: TrackGroup,
            trackIndex: Int,
            parameters: Parameters,
            formatSupport: RendererCapabilities.Support,
            selectedAudioLanguage: String?,
            mixedMimeTypeAdaptationSupport: RendererCapabilities.Support.AdaptiveSupport,
            isSuitableForViewport: Bool,
            isAllowedByVariantFilters: Bool = true
        ) {
            let format = trackGroup[trackIndex]
            // TODO: a lot of stuff
            self.parameters = parameters
            let requiredAdaptiveSupport: RendererCapabilities.Support.AdaptiveSupport = if parameters.allowVideoNonSeamlessAdaptiveness {
                [.seamless, .notSeamless]
            } else {
                [.seamless]
            }

            allowMixedMimeTypes = parameters.allowVideoMixedMimeTypeAdaptiveness
                 && !mixedMimeTypeAdaptationSupport.intersection(requiredAdaptiveSupport).isEmpty

            // Unknown values are within the limits.
            isWithinMaxConstraints = isSuitableForViewport
                && (format.width <= 0 || CGFloat(format.width) <= parameters.maxVideoSize.width)
                && (format.height <= 0 || CGFloat(format.height) <= parameters.maxVideoSize.height)
                && (format.frameRate <= 0 || format.frameRate <= Float(parameters.maxVideoFrameRate))
                && (format.bitrate <= 0 || format.bitrate <= parameters.maxVideoBitrate)
            isWithinMinConstraints = true
            isWithinRendererCapabilities = formatSupport.isFormatSupported(allowExceedsCapabilities: false)
            hasReasonableFrameRate = true // TODO:
            bitrate = format.bitrate
            pixelCount = format.width > 0 && format.height > 0 ? format.width * format.height : Format.noValue

            var bestLanguageIndex = Int.max
            var bestLanguageScore = 0
            for (index, language) in parameters.preferredVideoLanguages.enumerated() {
                let score = TrackInfo.getFormatLanguageScore(
                    format: format,
                    language: language,
                    allowUndeterminedFormatLanguage: false
                )

                if score > 0 {
                    bestLanguageIndex = index
                    bestLanguageScore = score
                    break
                }
            }

            preferredLanguageIndex = bestLanguageIndex
            preferredLanguageScore = bestLanguageScore
            preferredRoleFlagsScore = TrackInfo.getRoleFlagMatchScore(
                trackRoleFlags: format.roleFlags,
                preferredRoleFlags: parameters.preferredVideoRoleFlags
            )
            hasMainOrNoRoleFlag = format.roleFlags.isEmpty || format.roleFlags.contains(.main)
            let selectedAudioLanguageUndetermined = TrackInfo.normalizeUndeterminedLanguageToNil(selectedAudioLanguage) == nil
            selectedAudioLanguageScore = TrackInfo.getFormatLanguageScore(
                format: format,
                language: selectedAudioLanguage,
                allowUndeterminedFormatLanguage: selectedAudioLanguageUndetermined
            )

            var bestMimeTypeMatchIndex = Int.max
            for (index, mimeType) in parameters.preferredVideoMimeTypes.enumerated() {
                if format.sampleMimeType?.rawValue == mimeType {
                    bestMimeTypeMatchIndex = index
                    break
                }
            }

            preferredMimeTypeMatchIndex = bestMimeTypeMatchIndex
            preferredLabelMatchIndex = TrackInfo.getBestLabelMatchIndex(
                format: format,
                preferredLabels: parameters.preferredVideoLabels
            )
            usesPrimaryDecoder = formatSupport.decoderSupport == .primary
            usesHardwareAcceleration = formatSupport.hardwareAccelerationSupport == .supported
            codecPreferenceScore = format.sampleMimeType.videoCodecPreferenceScore
            selectionEligibility = !isAllowedByVariantFilters ? .none : VideoTrackInfo.evaluateSelectionEligibility(
                format: format,
                params: parameters,
                isWithinMinConstraints: isWithinMinConstraints,
                isWithinMaxConstraints: isWithinMaxConstraints,
                rendererSupport: formatSupport,
                requiredAdaptiveSupport: requiredAdaptiveSupport
            )

            super.init(rendererIndex: rendererIndex, trackGroup: trackGroup, trackIndex: trackIndex)
        }

        static func createForTrackGroup(
            rendererIndex: Int,
            trackGroup: TrackGroup,
            params: Parameters,
            formatSupport: [RendererCapabilities.Support],
            selectedAudioLanguage: String?,
            mixedMimeTypeAdaptationSupport: RendererCapabilities.Support.AdaptiveSupport,
            viewport: CGSize,
            viewportOrientationMayChange: Bool,
            allowedTracks: Set<Int>? = nil
        ) -> [VideoTrackInfo] {
            let suitableTracks = tracksSuitableForViewport(
                in: trackGroup,
                viewport: viewport,
                orientationMayChange: viewportOrientationMayChange
            )

            return trackGroup.enumerated().map { index, format in
                VideoTrackInfo(
                    rendererIndex: rendererIndex,
                    trackGroup: trackGroup,
                    trackIndex: index,
                    parameters: params,
                    formatSupport: formatSupport[index],
                    selectedAudioLanguage: selectedAudioLanguage,
                    mixedMimeTypeAdaptationSupport: mixedMimeTypeAdaptationSupport,
                    isSuitableForViewport: suitableTracks?.contains(index) ?? true,
                    isAllowedByVariantFilters: allowedTracks?.contains(index) ?? true
                )
            }
        }

        /// How much larger than the size it shows at, in each dimension, a track may be and still be worth loading.
        /// Scaled down by up to this much, a picture still looks sharper than one scaled up to fill the viewport.
        private static let viewportSizeMargin = 1.35

        /// The tracks of `group` worth loading for `viewport`: those less than ``viewportSizeMargin`` times the size
        /// they show at in both dimensions, and those of unknown size. If every sized track is larger, the smallest
        /// ones. `nil` if the viewport is unbounded.
        static func tracksSuitableForViewport(
            in group: TrackGroup,
            viewport: CGSize,
            orientationMayChange: Bool
        ) -> Set<Int>? {
            guard viewport.width < .greatestFiniteMagnitude, viewport.height < .greatestFiniteMagnitude,
                  viewport.width > 0, viewport.height > 0 else {
                return nil
            }
            var suitable = Set<Int>()
            var hasSuitableSizedTrack = false
            var smallest: (pixels: Int, indices: [Int])?
            for (index, format) in group.enumerated() {
                guard format.width > 0, format.height > 0 else {
                    suitable.insert(index)
                    continue
                }
                let shown = maxVideoSizeInViewport(
                    video: CGSize(width: format.width, height: format.height),
                    viewport: viewport,
                    orientationMayChange: orientationMayChange
                )
                if Double(format.width) < shown.width * viewportSizeMargin,
                   Double(format.height) < shown.height * viewportSizeMargin {
                    suitable.insert(index)
                    hasSuitableSizedTrack = true
                }
                let pixels = format.width * format.height
                if pixels < smallest?.pixels ?? .max {
                    smallest = (pixels, [index])
                } else if pixels == smallest?.pixels {
                    smallest?.indices.append(index)
                }
            }
            if !hasSuitableSizedTrack, let smallest {
                suitable.formUnion(smallest.indices)
            }
            return suitable
        }

        /// The size a video of `video` shows at, fitted in `viewport`: turned with it, when it would be larger so and the
        /// orientation may change.
        private static func maxVideoSizeInViewport(video: CGSize, viewport: CGSize, orientationMayChange: Bool) -> CGSize {
            var viewport = viewport
            if orientationMayChange, (video.width > video.height) != (viewport.width > viewport.height) {
                viewport = CGSize(width: viewport.height, height: viewport.width)
            }
            if video.width * viewport.height >= video.height * viewport.width {
                // Bars above and below.
                return CGSize(width: viewport.width, height: (viewport.width * video.height / video.width).rounded(.up))
            } else {
                // Bars on the sides.
                return CGSize(width: (viewport.height * video.width / video.height).rounded(.up), height: viewport.height)
            }
        }

        override func getSelectionEligibility() -> DefaultTrackSelector.SelectionEligibility {
            selectionEligibility
        }

        public override func isCompatibleForAdaptationWith(_ otherTrack: TrackInfo) -> Bool {
            guard let otherTrack = otherTrack as? VideoTrackInfo else {
                return false
            }

            return allowMixedMimeTypes || format.sampleMimeType == otherTrack.format.sampleMimeType
                && (parameters.allowVideoMixedDecoderSupportAdaptiveness
                    || (usesPrimaryDecoder == otherTrack.usesPrimaryDecoder
                        && usesHardwareAcceleration == otherTrack.usesHardwareAcceleration))
        }

        static func evaluateSelectionEligibility(
            format: Format,
            params: Parameters,
            isWithinMinConstraints: Bool,
            isWithinMaxConstraints: Bool,
            rendererSupport: RendererCapabilities.Support,
            requiredAdaptiveSupport: RendererCapabilities.Support.AdaptiveSupport
        ) -> SelectionEligibility {
            if format.roleFlags.contains(.trickPlay) {
                return .none
            }
            if !rendererSupport.isFormatSupported(allowExceedsCapabilities: params.exceedRendererCapabilitiesIfNecessary) {
                return .none
            }
            if !isWithinMaxConstraints && !params.exceedVideoConstraintsIfNecessary {
                return .none
            }

            return rendererSupport.isFormatSupported(allowExceedsCapabilities: false)
                    && isWithinMinConstraints
                    && isWithinMaxConstraints
                    && format.bitrate != Format.noValue
                    && !params.forceHighestSupportedBitrate
                    && !params.forceLowestBitrate
                    // Any of the required kinds of adaptation will do.
                    && !rendererSupport.adaptiveSupport.intersection(requiredAdaptiveSupport).isEmpty
                ? .adaptive
                : .fixed
        }

        public static func compareNonQualityPreferences(_ info1: VideoTrackInfo, _ info2: VideoTrackInfo) -> CFComparisonResult {
            func compareReversed<V: Comparable>(_ lhs: V?, rhs: V?) -> CFComparisonResult {
                let first = rhs
                let second = lhs

                if first == second { return .compareEqualTo }
                guard let first else { return .compareLessThan }
                guard let second else { return .compareGreaterThan }

                return first < second ? .compareLessThan : .compareGreaterThan
            }

            var accumulatedComparison = AccumulatedComparison.start()
                .compareFalseFirst(info1.isWithinRendererCapabilities, info2.isWithinRendererCapabilities)
                .compare(
                    info1.preferredLanguageIndex,
                    info2.preferredLanguageIndex,
                    compareReversed
                )
                .compare(info1.preferredLanguageScore, info2.preferredLanguageScore)
                .compare(info1.preferredRoleFlagsScore, info2.preferredRoleFlagsScore)
                .compare(
                    info1.preferredLabelMatchIndex,
                    info2.preferredLabelMatchIndex,
                    compareReversed
                )
                .compareFalseFirst(info1.hasReasonableFrameRate, info2.hasReasonableFrameRate)
                .compareFalseFirst(info1.isWithinMaxConstraints, info2.isWithinMaxConstraints)
                .compareFalseFirst(info1.isWithinMinConstraints, info2.isWithinMinConstraints)
                .compare(
                    info1.preferredMimeTypeMatchIndex,
                    info2.preferredMimeTypeMatchIndex,
                    compareReversed
                )
                .compareFalseFirst(info1.usesPrimaryDecoder, info2.usesPrimaryDecoder)
                .compareFalseFirst(info1.usesHardwareAcceleration, info2.usesHardwareAcceleration)

            if info1.usesPrimaryDecoder, info1.usesHardwareAcceleration {
                accumulatedComparison = accumulatedComparison
                    .compare(info1.codecPreferenceScore, info2.codecPreferenceScore)
            }

            return accumulatedComparison.result()
        }

        public static func compareQualityPreferences(_ info1: VideoTrackInfo, _ info2: VideoTrackInfo) -> CFComparisonResult {
            let qualityOrdering = info1.isWithinMaxConstraints && info1.isWithinRendererCapabilities
                ? TrackInfo.formatValueOrdering
                : TrackInfo.formatValueOrderingReversed

            var accumulatedComparison = AccumulatedComparison.start()
            if info1.parameters.forceLowestBitrate {
                accumulatedComparison = accumulatedComparison
                    .compare(info1.bitrate, info2.bitrate, TrackInfo.formatValueOrderingReversed)
            }

            return accumulatedComparison
                .compare(info1.pixelCount, info2.pixelCount, qualityOrdering)
                .compare(info1.bitrate, info2.bitrate, qualityOrdering)
                .result()
        }

        public static func compareSelections(_ lhs: [VideoTrackInfo], _ rhs: [VideoTrackInfo]) -> CFComparisonResult {
            AccumulatedComparison.start()
                .compare(
                    lhs.maxElement(compareNonQualityPreferences),
                    rhs.maxElement(compareNonQualityPreferences),
                    compareNonQualityPreferences
                )
                .compare(lhs.count, rhs.count)
                .compare(
                    lhs.maxElement(compareQualityPreferences),
                    rhs.maxElement(compareQualityPreferences),
                    compareQualityPreferences
                )
                .result()
        }
    }

    final class TextTrackInfo: TrackInfo {
        private let selectionEligibility: SelectionEligibility
        private let isWithinRendererCapabilities: Bool
        private let isDefault: Bool
        private let isForced: Bool
        private let preferredLanguageIndex: Int
        private let preferredLanguageScore: Int
        private let preferredRoleFlagsScore: Int
        private let preferredLabelMatchIndex: Int
        private let selectedAudioLanguageScore: Int
        private let hasCaptionRoleFlags: Bool

        init(
            rendererIndex: Int,
            trackGroup: TrackGroup,
            trackIndex: Int,
            parameters: Parameters,
            formatSupport: RendererCapabilities.Support,
            selectedAudioLanguage: String?,
            preferredCaptioningLanguage: String?
        ) {
            let format = trackGroup[trackIndex]
            isWithinRendererCapabilities = formatSupport.isFormatSupported(allowExceedsCapabilities: false)

            let maskedSelectionFlags = format.selectionFlags.subtracting(parameters.ignoredTextSelectionFlags)
            isDefault = maskedSelectionFlags.contains(.default)
            isForced = maskedSelectionFlags.contains(.forced)

            // Compare against empty (unset) language if no preference is given to allow the selection of a text track
            // with undetermined language.
            let preferredLanguages = if let preferredCaptioningLanguage {
                [preferredCaptioningLanguage]
            } else if parameters.preferredTextLanguages.isEmpty {
                [""]
            } else {
                parameters.preferredTextLanguages
            }
            var bestLanguageIndex = Int.max
            var bestLanguageScore = 0
            for (index, language) in preferredLanguages.enumerated() {
                let score = TrackInfo.getFormatLanguageScore(
                    format: format,
                    language: language,
                    allowUndeterminedFormatLanguage: parameters.selectUndeterminedTextLanguage
                )
                if score > 0 {
                    bestLanguageIndex = index
                    bestLanguageScore = score
                    break
                }
            }
            preferredLanguageIndex = bestLanguageIndex
            preferredLanguageScore = bestLanguageScore

            let preferredRoleFlags: RoleFlags = preferredCaptioningLanguage != nil
                ? [.caption, .describesMusicAndSound]
                : parameters.preferredTextRoleFlags
            preferredRoleFlagsScore = TrackInfo.getRoleFlagMatchScore(
                trackRoleFlags: format.roleFlags,
                preferredRoleFlags: preferredRoleFlags
            )
            hasCaptionRoleFlags = !format.roleFlags.intersection([.caption, .describesMusicAndSound]).isEmpty
            preferredLabelMatchIndex = TrackInfo.getBestLabelMatchIndex(
                format: format,
                preferredLabels: parameters.preferredTextLabels
            )

            let selectedAudioLanguageUndetermined = TrackInfo.normalizeUndeterminedLanguageToNil(selectedAudioLanguage) == nil
            selectedAudioLanguageScore = TrackInfo.getFormatLanguageScore(
                format: format,
                language: selectedAudioLanguage,
                allowUndeterminedFormatLanguage: selectedAudioLanguageUndetermined
            )

            let isWithinConstraints = preferredLanguageScore > 0
                || (parameters.preferredTextLanguages.isEmpty && preferredRoleFlagsScore > 0)
                || (parameters.preferredTextLanguages.isEmpty && preferredLabelMatchIndex != Int.max)
                || isDefault
                || (isForced && selectedAudioLanguageScore > 0)
                || parameters.selectTextByDefault
            selectionEligibility = formatSupport.isFormatSupported(
                allowExceedsCapabilities: parameters.exceedRendererCapabilitiesIfNecessary
            ) && isWithinConstraints ? .fixed : .none

            super.init(rendererIndex: rendererIndex, trackGroup: trackGroup, trackIndex: trackIndex)
        }

        static func createForTrackGroup(
            rendererIndex: Int,
            trackGroup: TrackGroup,
            params: Parameters,
            formatSupport: [RendererCapabilities.Support],
            selectedAudioLanguage: String?,
            preferredCaptioningLanguage: String?
        ) -> [TextTrackInfo] {
            trackGroup.enumerated().map { index, _ in
                TextTrackInfo(
                    rendererIndex: rendererIndex,
                    trackGroup: trackGroup,
                    trackIndex: index,
                    parameters: params,
                    formatSupport: formatSupport[index],
                    selectedAudioLanguage: selectedAudioLanguage,
                    preferredCaptioningLanguage: preferredCaptioningLanguage
                )
            }
        }

        override func getSelectionEligibility() -> DefaultTrackSelector.SelectionEligibility {
            selectionEligibility
        }

        override func isCompatibleForAdaptationWith(_ otherTrack: TrackInfo) -> Bool {
            false
        }

        func compareTo(_ other: TextTrackInfo) -> CFComparisonResult {
            func compareReversed(_ lhs: Int, _ rhs: Int) -> CFComparisonResult {
                lhs == rhs ? .compareEqualTo : (lhs > rhs ? .compareLessThan : .compareGreaterThan)
            }

            var accumulated = AccumulatedComparison.start()
                .compareFalseFirst(isWithinRendererCapabilities, other.isWithinRendererCapabilities)
                // 1. Compare match with specific content preferences set by the parameters.
                .compare(preferredLanguageIndex, other.preferredLanguageIndex, compareReversed)
                .compare(preferredLanguageScore, other.preferredLanguageScore)
                .compare(preferredRoleFlagsScore, other.preferredRoleFlagsScore)
                .compare(preferredLabelMatchIndex, other.preferredLabelMatchIndex, compareReversed)
                // 2. Compare match with implicit content preferences set by the media.
                .compareFalseFirst(isDefault, other.isDefault)

            // Prefer non-forced to forced if a preferred text language has been matched. Where both are provided the
            // non-forced track will usually contain the forced subtitles as a subset. Otherwise, prefer a forced track.
            accumulated = preferredLanguageScore == 0
                ? accumulated.compareFalseFirst(isForced, other.isForced)
                : accumulated.compareTrueFirst(isForced, other.isForced)

            accumulated = accumulated.compare(selectedAudioLanguageScore, other.selectedAudioLanguageScore)
            if preferredRoleFlagsScore == 0 {
                accumulated = accumulated.compareTrueFirst(hasCaptionRoleFlags, other.hasCaptionRoleFlags)
            }
            return accumulated.result()
        }

        static func compareSelections(infos1: [TextTrackInfo], infos2: [TextTrackInfo]) -> CFComparisonResult {
            guard let first1 = infos1.first, let first2 = infos2.first else {
                return .compareEqualTo
            }
            return first1.compareTo(first2)
        }
    }

    final class AudioTrackInfo: TrackInfo, Comparable {
        private let selectionEligibility: SelectionEligibility
        private let isWithinConstraints: Bool
        private let language: String?
        private let parameters: Parameters
        private let isWithinRendererCapabilities: Bool
        private let preferredLanguageScore: Int
        private let preferredLanguageIndex: Int
        private let preferredRoleFlagsScore: Int
        private let preferredLabelMatchIndex: Int
        private let allowMixedMimeTypes: Bool
        private let hasMainOrNoRoleFlag: Bool
        private let localeLanguageMatchIndex: Int
        private let localeLanguageScore: Int
        private let isDefaultSelectionFlag: Bool
        private let channelCount: Int
        private let sampleRate: Int
        private let bitrate: Int
        private let preferredMimeTypeMatchIndex: Int
        private let usesPrimaryDecoder: Bool
        private let usesHardwareAcceleration: Bool
        private let isObjectBasedAudio: Bool

        init(
            rendererIndex: Int,
            trackGroup: TrackGroup,
            trackIndex: Int,
            parameters: Parameters,
            formatSupport: RendererCapabilities.Support,
            hasMappedVideoTracks: Bool,
            withinAudioChannelCountConstraints: (Format) -> Bool,
            mixedMimeTypeAdaptationSupport: RendererCapabilities.Support.AdaptiveSupport
        ) {
            let format = trackGroup[trackIndex]
            self.parameters = parameters

            let requiredAdaptiveSupport: RendererCapabilities.Support.AdaptiveSupport = if parameters.allowAudioNonSeamlessAdaptiveness {
                [.seamless, .notSeamless]
            } else {
                [.seamless]
            }

            allowMixedMimeTypes =
            parameters.allowAudioMixedMimeTypeAdaptiveness
            && !mixedMimeTypeAdaptationSupport.intersection(requiredAdaptiveSupport).isEmpty

            language = TrackInfo.normalizeUndeterminedLanguageToNil(format.language)

            isWithinRendererCapabilities = formatSupport.isFormatSupported(allowExceedsCapabilities: false)

            // Preferred audio language match (first match wins, lower index better)
            var bestLanguageIndex = Int.max
            var bestLanguageScore = 0
            for (index, lang) in parameters.preferredAudioLanguages.enumerated() {
                let score = TrackInfo.getFormatLanguageScore(
                    format: format,
                    language: lang,
                    allowUndeterminedFormatLanguage: false
                )
                if score > 0 {
                    bestLanguageIndex = index
                    bestLanguageScore = score
                    break
                }
            }
            preferredLanguageIndex = bestLanguageIndex
            preferredLanguageScore = bestLanguageScore

            preferredRoleFlagsScore = TrackInfo.getRoleFlagMatchScore(
                trackRoleFlags: format.roleFlags,
                preferredRoleFlags: parameters.preferredAudioRoleFlags
            )

            preferredLabelMatchIndex = TrackInfo.getBestLabelMatchIndex(
                format: format,
                preferredLabels: parameters.preferredAudioLabels
            )

            hasMainOrNoRoleFlag = format.roleFlags.isEmpty || format.roleFlags.contains(.main)
            isDefaultSelectionFlag = format.selectionFlags.contains(.default)

            isObjectBasedAudio = format.sampleMimeType.isObjectBasedAudio

            channelCount = format.channelCount
            sampleRate = format.sampleRate
            bitrate = format.bitrate

            isWithinConstraints =
            (format.bitrate == Format.noValue || format.bitrate <= parameters.maxAudioBitrate)
            && (format.channelCount == Format.noValue || format.channelCount <= parameters.maxAudioChannelCount)
            && withinAudioChannelCountConstraints(format)

            // Locale language match (first match wins)
            let localeLanguages = Locale.preferredLanguages.compactMap(Util.normalizeLanguageCode)
            var bestLocaleMatchIndex = Int.max
            var bestLocaleMatchScore = 0
            for (index, lang) in localeLanguages.enumerated() {
                let score = TrackInfo.getFormatLanguageScore(
                    format: format,
                    language: lang,
                    allowUndeterminedFormatLanguage: false
                )
                if score > 0 {
                    bestLocaleMatchIndex = index
                    bestLocaleMatchScore = score
                    break
                }
            }
            localeLanguageMatchIndex = bestLocaleMatchIndex
            localeLanguageScore = bestLocaleMatchScore

            // Preferred mime type match index (lower is better)
            var bestMimeTypeMatchIndex = Int.max
            for (index, mimeType) in parameters.preferredAudioMimeTypes.enumerated() {
                if format.sampleMimeType?.rawValue == mimeType {
                    bestMimeTypeMatchIndex = index
                    break
                }
            }
            preferredMimeTypeMatchIndex = bestMimeTypeMatchIndex

            usesPrimaryDecoder = (formatSupport.decoderSupport == .primary)
            usesHardwareAcceleration = (formatSupport.hardwareAccelerationSupport == .supported)

            selectionEligibility = AudioTrackInfo.evaluateSelectionEligibility(
                format: format,
                params: parameters,
                isWithinConstraints: isWithinConstraints,
                rendererSupport: formatSupport,
                hasMappedVideoTracks: hasMappedVideoTracks,
                requiredAdaptiveSupport: requiredAdaptiveSupport
            )
            
            super.init(rendererIndex: rendererIndex, trackGroup: trackGroup, trackIndex: trackIndex)
        }

        static func createForTrackGroup(
            rendererIndex: Int,
            trackGroup: TrackGroup,
            params: Parameters,
            formatSupport: [RendererCapabilities.Support],
            hasMappedVideoTracks: Bool,
            withinAudioChannelCountConstraints: (Format) -> Bool,
            mixedMimeTypeAdaptationSupport: RendererCapabilities.Support.AdaptiveSupport
        ) -> [AudioTrackInfo] {
            trackGroup.enumerated().map { index, _ in
                AudioTrackInfo(
                    rendererIndex: rendererIndex,
                    trackGroup: trackGroup,
                    trackIndex: index,
                    parameters: params,
                    formatSupport: formatSupport[index],
                    hasMappedVideoTracks: hasMappedVideoTracks,
                    withinAudioChannelCountConstraints: withinAudioChannelCountConstraints,
                    mixedMimeTypeAdaptationSupport: mixedMimeTypeAdaptationSupport
                )
            }
        }

        override func getSelectionEligibility() -> DefaultTrackSelector.SelectionEligibility {
            selectionEligibility
        }

        override func isCompatibleForAdaptationWith(_ otherTrack: TrackInfo) -> Bool {
            guard let otherTrack = otherTrack as? AudioTrackInfo else {
                return false
            }

            return (parameters.allowAudioMixedChannelCountAdaptiveness
                 || (format.channelCount != Format.noValue && format.channelCount == otherTrack.format.channelCount))
                && (allowMixedMimeTypes
                    || (format.sampleMimeType != nil && format.sampleMimeType == otherTrack.format.sampleMimeType))
                && (parameters.allowAudioMixedSampleRateAdaptiveness
                    || (format.sampleRate != Format.noValue && format.sampleRate == otherTrack.format.sampleRate))
                && (parameters.allowAudioMixedDecoderSupportAdaptiveness
                    || (usesPrimaryDecoder == otherTrack.usesPrimaryDecoder
                        && usesHardwareAcceleration == otherTrack.usesHardwareAcceleration))
        }

        func compareTo(_ other: AudioTrackInfo) -> CFComparisonResult {
            // If within constraints & renderer caps => prefer higher (ascending ordering with NO_VALUE first),
            // else prefer lower (reverse ordering).
            let qualityOrdering = (isWithinConstraints && isWithinRendererCapabilities)
                ? TrackInfo.formatValueOrdering
                : TrackInfo.formatValueOrderingReversed

            func compareReversed<V: Comparable>(_ lhs: V?, _ rhs: V?) -> CFComparisonResult {
                // Natural.reverse() semantics, including nil handling consistent with your VideoTrackInfo helper.
                let first = rhs
                let second = lhs

                if first == second { return .compareEqualTo }
                guard let first else { return .compareLessThan }
                guard let second else { return .compareGreaterThan }

                return first < second ? .compareLessThan : .compareGreaterThan
            }

            var accumulated = AccumulatedComparison.start()
                .compareFalseFirst(isWithinRendererCapabilities, other.isWithinRendererCapabilities)
                // 1) Explicit content prefs
                .compare(preferredLanguageIndex, other.preferredLanguageIndex, compareReversed)
                .compare(preferredLanguageScore, other.preferredLanguageScore)
                .compare(preferredRoleFlagsScore, other.preferredRoleFlagsScore)
                .compare(preferredLabelMatchIndex, other.preferredLabelMatchIndex, compareReversed)
                // 2) Implicit content prefs
                .compareFalseFirst(isDefaultSelectionFlag, other.isDefaultSelectionFlag)
                .compareFalseFirst(hasMainOrNoRoleFlag, other.hasMainOrNoRoleFlag)
                .compare(localeLanguageMatchIndex, other.localeLanguageMatchIndex, compareReversed)
                .compare(localeLanguageScore, other.localeLanguageScore)
                // 3) Technical prefs
                .compareFalseFirst(isWithinConstraints, other.isWithinConstraints)
                .compare(preferredMimeTypeMatchIndex, other.preferredMimeTypeMatchIndex, compareReversed)

            if parameters.forceLowestBitrate {
                accumulated = accumulated.compare(
                    bitrate,
                    other.bitrate,
                    TrackInfo.formatValueOrderingReversed
                )
            }

            accumulated = accumulated
                // 4) Renderer capability prefs
                .compareFalseFirst(usesPrimaryDecoder, other.usesPrimaryDecoder)
                .compareFalseFirst(usesHardwareAcceleration, other.usesHardwareAcceleration)
                // 5) Technical quality
                .compareFalseFirst(isObjectBasedAudio, other.isObjectBasedAudio)
                .compare(channelCount, other.channelCount, qualityOrdering)
                .compare(sampleRate, other.sampleRate, qualityOrdering)

            if language == other.language {
                accumulated = accumulated.compare(bitrate, other.bitrate, qualityOrdering)
            }

            return accumulated.result()
        }

        static func evaluateSelectionEligibility(
            format: Format,
            params: Parameters,
            isWithinConstraints: Bool,
            rendererSupport: RendererCapabilities.Support,
            hasMappedVideoTracks: Bool,
            requiredAdaptiveSupport: RendererCapabilities.Support.AdaptiveSupport
        ) -> SelectionEligibility {
            if !rendererSupport.isFormatSupported(allowExceedsCapabilities: params.exceedRendererCapabilitiesIfNecessary) {
                return .none
            }
            if !isWithinConstraints && !params.exceedAudioConstraintsIfNecessary {
                return .none
            }

            let supportsAdaptive = !rendererSupport.adaptiveSupport.intersection(requiredAdaptiveSupport).isEmpty

            return rendererSupport.isFormatSupported(allowExceedsCapabilities: false)
                && isWithinConstraints
                && format.bitrate != Format.noValue
                && !params.forceHighestSupportedBitrate
                && !params.forceLowestBitrate
                && (params.allowMultipleAdaptiveSelections || !hasMappedVideoTracks)
//                && params.audioOffloadPreferences.audioOffloadMode != .required
                && supportsAdaptive
                ? .adaptive
                : .fixed
        }

        public static func < (lhs: DefaultTrackSelector.AudioTrackInfo, rhs: DefaultTrackSelector.AudioTrackInfo) -> Bool {
            lhs.compareTo(rhs) == .compareLessThan
        }

        public static func == (lhs: DefaultTrackSelector.AudioTrackInfo, rhs: DefaultTrackSelector.AudioTrackInfo) -> Bool {
            lhs.compareTo(rhs) == .compareEqualTo
        }

        public static func compareSelections(infos1: [AudioTrackInfo], infos2: [AudioTrackInfo]) -> CFComparisonResult {
            guard let infos1max = infos1.max(), let infos2max = infos2.max() else {
                return .compareEqualTo
            }

            return infos1max.compareTo(infos2max)
        }
    }

    final class Parameters: TrackSelectionParameters {
        static let `default` = Builder().build()

        let exceedVideoConstraintsIfNecessary: Bool
        let allowVideoMixedMimeTypeAdaptiveness: Bool
        let allowVideoNonSeamlessAdaptiveness: Bool
        let allowVideoMixedDecoderSupportAdaptiveness: Bool
        let exceedAudioConstraintsIfNecessary: Bool
        let allowAudioMixedMimeTypeAdaptiveness: Bool
        let allowAudioMixedSampleRateAdaptiveness: Bool
        let allowAudioMixedChannelCountAdaptiveness: Bool
        let allowAudioMixedDecoderSupportAdaptiveness: Bool
        let allowAudioNonSeamlessAdaptiveness: Bool
        let constrainAudioChannelCountToDeviceCapabilities: Bool
        let exceedRendererCapabilitiesIfNecessary: Bool
        let tunnelingEnabled: Bool
        let allowMultipleAdaptiveSelections: Bool
        let allowInvalidateSelectionsOnRendererCapabilitiesChange: Bool
        let selectionOverrides: [[TrackGroupArray: SelectionOverride]]
        let rendererDisabledFlags: [Int: Bool]

        fileprivate init(builder: Builder) {
            exceedVideoConstraintsIfNecessary = builder.exceedVideoConstraintsIfNecessary
            allowVideoMixedMimeTypeAdaptiveness = builder.allowVideoMixedMimeTypeAdaptiveness
            allowVideoNonSeamlessAdaptiveness = builder.allowVideoNonSeamlessAdaptiveness
            allowVideoMixedDecoderSupportAdaptiveness = builder.allowVideoMixedDecoderSupportAdaptiveness
            exceedAudioConstraintsIfNecessary = builder.exceedAudioConstraintsIfNecessary
            allowAudioMixedMimeTypeAdaptiveness = builder.allowAudioMixedMimeTypeAdaptiveness
            allowAudioMixedSampleRateAdaptiveness = builder.allowAudioMixedSampleRateAdaptiveness
            allowAudioMixedChannelCountAdaptiveness = builder.allowAudioMixedChannelCountAdaptiveness
            allowAudioMixedDecoderSupportAdaptiveness = builder.allowAudioMixedDecoderSupportAdaptiveness
            allowAudioNonSeamlessAdaptiveness = builder.allowAudioNonSeamlessAdaptiveness
            constrainAudioChannelCountToDeviceCapabilities = builder.constrainAudioChannelCountToDeviceCapabilities
            exceedRendererCapabilitiesIfNecessary = builder.exceedRendererCapabilitiesIfNecessary
            tunnelingEnabled = builder.tunnelingEnabled
            allowMultipleAdaptiveSelections = builder.allowMultipleAdaptiveSelections
            allowInvalidateSelectionsOnRendererCapabilitiesChange = builder.allowInvalidateSelectionsOnRendererCapabilitiesChange
            selectionOverrides = builder.selectionOverrides
            rendererDisabledFlags = builder.rendererDisabledFlags
            super.init(builder: builder)
        }

        public override func buildUpon() -> Builder {
            Builder(params: self)
        }

        public override func isEqual(to other: TrackSelectionParameters) -> Bool {
            guard let other = other as? Parameters else { return false }

            return super.isEqual(to: other)
                && exceedVideoConstraintsIfNecessary == other.exceedVideoConstraintsIfNecessary
                && allowVideoMixedMimeTypeAdaptiveness == other.allowVideoMixedMimeTypeAdaptiveness
                && allowVideoNonSeamlessAdaptiveness == other.allowVideoNonSeamlessAdaptiveness
                && allowVideoMixedDecoderSupportAdaptiveness == other.allowVideoMixedDecoderSupportAdaptiveness
                && exceedAudioConstraintsIfNecessary == other.exceedAudioConstraintsIfNecessary
                && allowAudioMixedMimeTypeAdaptiveness == other.allowAudioMixedMimeTypeAdaptiveness
                && allowAudioMixedSampleRateAdaptiveness == other.allowAudioMixedSampleRateAdaptiveness
                && allowAudioMixedChannelCountAdaptiveness == other.allowAudioMixedChannelCountAdaptiveness
                && allowAudioMixedDecoderSupportAdaptiveness == other.allowAudioMixedDecoderSupportAdaptiveness
                && allowAudioNonSeamlessAdaptiveness == other.allowAudioNonSeamlessAdaptiveness
                && constrainAudioChannelCountToDeviceCapabilities == other.constrainAudioChannelCountToDeviceCapabilities
                && exceedRendererCapabilitiesIfNecessary == other.exceedRendererCapabilitiesIfNecessary
                && tunnelingEnabled == other.tunnelingEnabled
                && allowMultipleAdaptiveSelections == other.allowMultipleAdaptiveSelections
                && allowInvalidateSelectionsOnRendererCapabilitiesChange == other.allowInvalidateSelectionsOnRendererCapabilitiesChange
                && selectionOverrides == other.selectionOverrides
                && rendererDisabledFlags == other.rendererDisabledFlags
        }

        public override func hash(into hasher: inout Hasher) {
            super.hash(into: &hasher)
            hasher.combine(exceedVideoConstraintsIfNecessary)
            hasher.combine(allowVideoMixedMimeTypeAdaptiveness)
            hasher.combine(allowVideoNonSeamlessAdaptiveness)
            hasher.combine(allowVideoMixedDecoderSupportAdaptiveness)
            hasher.combine(exceedAudioConstraintsIfNecessary)
            hasher.combine(allowAudioMixedMimeTypeAdaptiveness)
            hasher.combine(allowAudioMixedSampleRateAdaptiveness)
            hasher.combine(allowAudioMixedChannelCountAdaptiveness)
            hasher.combine(allowAudioMixedDecoderSupportAdaptiveness)
            hasher.combine(allowAudioNonSeamlessAdaptiveness)
            hasher.combine(constrainAudioChannelCountToDeviceCapabilities)
            hasher.combine(exceedRendererCapabilitiesIfNecessary)
            hasher.combine(tunnelingEnabled)
            hasher.combine(allowMultipleAdaptiveSelections)
            hasher.combine(allowInvalidateSelectionsOnRendererCapabilitiesChange)
            hasher.combine(selectionOverrides)
            hasher.combine(rendererDisabledFlags)
        }

        public final class Builder: TrackSelectionParameters.Builder {
            var exceedVideoConstraintsIfNecessary: Bool = true
            var allowVideoMixedMimeTypeAdaptiveness: Bool = false
            var allowVideoNonSeamlessAdaptiveness: Bool = true
            var allowVideoMixedDecoderSupportAdaptiveness: Bool = false
            var exceedAudioConstraintsIfNecessary: Bool = true
            var allowAudioMixedMimeTypeAdaptiveness: Bool = false
            var allowAudioMixedSampleRateAdaptiveness: Bool = false
            var allowAudioMixedChannelCountAdaptiveness: Bool = false
            var allowAudioMixedDecoderSupportAdaptiveness: Bool = false
            var allowAudioNonSeamlessAdaptiveness: Bool = true
            var constrainAudioChannelCountToDeviceCapabilities: Bool = true
            var exceedRendererCapabilitiesIfNecessary: Bool = true
            var tunnelingEnabled: Bool = false
            var allowMultipleAdaptiveSelections: Bool = true
            var allowInvalidateSelectionsOnRendererCapabilitiesChange: Bool = false
            var selectionOverrides = [[TrackGroupArray: SelectionOverride]]()
            var rendererDisabledFlags = [Int: Bool]()

            public override init() { super.init() }

            init(params: Parameters) {
                super.init(params)
                exceedVideoConstraintsIfNecessary = params.exceedVideoConstraintsIfNecessary
                allowVideoMixedMimeTypeAdaptiveness = params.allowVideoMixedMimeTypeAdaptiveness
                allowVideoNonSeamlessAdaptiveness = params.allowVideoNonSeamlessAdaptiveness
                allowVideoMixedDecoderSupportAdaptiveness = params.allowVideoMixedDecoderSupportAdaptiveness
                exceedAudioConstraintsIfNecessary = params.exceedAudioConstraintsIfNecessary
                allowAudioMixedMimeTypeAdaptiveness = params.allowAudioMixedMimeTypeAdaptiveness
                allowAudioMixedSampleRateAdaptiveness = params.allowAudioMixedSampleRateAdaptiveness
                allowAudioMixedChannelCountAdaptiveness = params.allowAudioMixedChannelCountAdaptiveness
                allowAudioMixedDecoderSupportAdaptiveness = params.allowAudioMixedDecoderSupportAdaptiveness
                allowAudioNonSeamlessAdaptiveness = params.allowAudioNonSeamlessAdaptiveness
                constrainAudioChannelCountToDeviceCapabilities = params.constrainAudioChannelCountToDeviceCapabilities
                exceedRendererCapabilitiesIfNecessary = params.exceedRendererCapabilitiesIfNecessary
                tunnelingEnabled = params.tunnelingEnabled
                allowMultipleAdaptiveSelections = params.allowMultipleAdaptiveSelections
                allowInvalidateSelectionsOnRendererCapabilitiesChange = params.allowInvalidateSelectionsOnRendererCapabilitiesChange
                selectionOverrides = params.selectionOverrides
                rendererDisabledFlags = params.rendererDisabledFlags
            }

            public override func set(_ parameters: TrackSelectionParameters) -> Builder {
                super.set(parameters)
                return self
            }

            public override func build() -> Parameters { Parameters(builder: self) }

            public func setExceedVideoConstraintsIfNecessary(_ exceedVideoConstraintsIfNecessary: Bool) -> Builder {
                self.exceedVideoConstraintsIfNecessary = exceedVideoConstraintsIfNecessary
                return self
            }

            public func setAllowVideoMixedMimeTypeAdaptiveness(_ allowVideoMixedMimeTypeAdaptiveness: Bool) -> Builder {
                self.allowVideoMixedMimeTypeAdaptiveness = allowVideoMixedMimeTypeAdaptiveness
                return self
            }

            public func setAllowVideoNonSeamlessAdaptiveness(_ allowVideoNonSeamlessAdaptiveness: Bool) -> Builder {
                self.allowVideoNonSeamlessAdaptiveness = allowVideoNonSeamlessAdaptiveness
                return self
            }

            public func setAllowVideoMixedDecoderSupportAdaptiveness(_ allowVideoMixedDecoderSupportAdaptiveness: Bool) -> Builder {
                self.allowVideoMixedDecoderSupportAdaptiveness = allowVideoMixedDecoderSupportAdaptiveness
                return self
            }

            public func setExceedAudioConstraintsIfNecessary(_ exceedAudioConstraintsIfNecessary: Bool) -> Builder {
                self.exceedAudioConstraintsIfNecessary = exceedAudioConstraintsIfNecessary
                return self
            }

            public func setAllowAudioMixedMimeTypeAdaptiveness(_ allowAudioMixedMimeTypeAdaptiveness: Bool) -> Builder {
                self.allowAudioMixedMimeTypeAdaptiveness = allowAudioMixedMimeTypeAdaptiveness
                return self
            }

            public func setAllowAudioMixedSampleRateAdaptiveness(_ allowAudioMixedSampleRateAdaptiveness: Bool) -> Builder {
                self.allowAudioMixedSampleRateAdaptiveness = allowAudioMixedSampleRateAdaptiveness
                return self
            }

            public func setAllowAudioMixedChannelCountAdaptiveness(_ allowAudioMixedChannelCountAdaptiveness: Bool) -> Builder {
                self.allowAudioMixedChannelCountAdaptiveness = allowAudioMixedChannelCountAdaptiveness
                return self
            }

            public func setAllowAudioMixedDecoderSupportAdaptiveness(_ allowAudioMixedDecoderSupportAdaptiveness: Bool) -> Builder {
                self.allowAudioMixedDecoderSupportAdaptiveness = allowAudioMixedDecoderSupportAdaptiveness
                return self
            }

            public func setAllowAudioNonSeamlessAdaptiveness(_ allowAudioNonSeamlessAdaptiveness: Bool) -> Builder {
                self.allowAudioNonSeamlessAdaptiveness = allowAudioNonSeamlessAdaptiveness
                return self
            }

            public func setConstrainAudioChannelCountToDeviceCapabilities(_ enabled: Bool) -> Builder {
                constrainAudioChannelCountToDeviceCapabilities = enabled
                return self
            }

            public func setExceedRendererCapabilitiesIfNecessary(_ exceedRendererCapabilitiesIfNecessary: Bool) -> Builder {
                self.exceedRendererCapabilitiesIfNecessary = exceedRendererCapabilitiesIfNecessary
                return self
            }

            public func setTunnelingEnabled(_ tunnelingEnabled: Bool) -> Builder {
                self.tunnelingEnabled = tunnelingEnabled
                return self
            }

            public func setAllowMultipleAdaptiveSelections(_ allowMultipleAdaptiveSelections: Bool) -> Builder {
                self.allowMultipleAdaptiveSelections = allowMultipleAdaptiveSelections
                return self
            }

            public func setAllowInvalidateSelectionsOnRendererCapabilitiesChange(_ allowInvalidateSelectionsOnRendererCapabilitiesChange: Bool) -> Builder {
                self.allowInvalidateSelectionsOnRendererCapabilitiesChange = allowInvalidateSelectionsOnRendererCapabilitiesChange
                return self
            }
        }

        public struct SelectionOverride: Hashable {}
    }
}

private extension Optional where Wrapped == MimeTypes {
    var videoCodecPreferenceScore: Int {
        guard let self else { return 0 }

        switch self {
        case .videoDolbyVision:
            return 5
        case .videoAV1:
            return 4
        case .videoH265:
            return 3
        case .videoH264:
            return 2
        case .videoVP9:
            return 1
        default:
            return 0
        }
    }

    var isObjectBasedAudio: Bool {
        guard let self else { return false }

        switch self {
        case .audioEAC3JOC, .audioAC4, .audioIAMF:
            return true
        default:
            return false
        }
    }
}
