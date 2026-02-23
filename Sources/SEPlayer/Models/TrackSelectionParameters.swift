//
//  TrackSelectionParameters.swift
//  SEPlayer
//
//  Created by tvrrp on 13.02.2026.
//

import CoreGraphics

// TODO: RoleFlags setters
public class TrackSelectionParameters: Hashable {
    public let maxVideoSize: CGSize
    public let maxVideoFrameRate: Int
    public let maxVideoBitrate: Int
    public let minVideoSize: CGSize
    public let minVideoFrameRate: Int
    public let minVideoBitrate: Int
    public let viewportSize: CGSize
    public let isViewportSizeLimitedByPhysicalDisplaySize: Bool
    public let viewportOrientationMayChange: Bool
    public let preferredVideoMimeTypes: [String]
    public let preferredVideoLabels: [String]
    public let preferredVideoLanguages: [String]
    public let preferredVideoRoleFlags: RoleFlags
    public let preferredAudioLanguages: [String]
    public let preferredAudioLabels: [String]
    public let preferredAudioRoleFlags: RoleFlags
    public let maxAudioChannelCount: Int
    public let maxAudioBitrate: Int
    public let preferredAudioMimeTypes: [String]
//    public let offloadPreferences: OffloadPreferences
    public let selectTextByDefault: Bool
    public let preferredTextLanguages: [String]
    public let preferredTextRoleFlags: RoleFlags
    public let usePreferredTextLanguagesAndRoleFlagsFromCaptioningManager: Bool
    public let preferredTextLabels: [String]
    // TODO: var ignoredTextSelectionFlags: SelectionFlags
    public let selectUndeterminedTextLanguage: Bool
    public let isPrioritizeImageOverVideoEnabled: Bool
    public let forceLowestBitrate: Bool
    public let forceHighestSupportedBitrate: Bool
    public let overrides: [TrackGroup: TrackSelectionOverride]
    public let disabledTrackTypes: Set<TrackType>

    public func buildUpon() -> Builder {
        Builder(self)
    }

    internal init(builder: Builder) {
        maxVideoSize = builder.maxVideoSize
        maxVideoFrameRate = builder.maxVideoFrameRate
        maxVideoBitrate = builder.maxVideoBitrate
        minVideoSize = builder.minVideoSize
        minVideoFrameRate = builder.minVideoFrameRate
        minVideoBitrate = builder.minVideoBitrate
        viewportSize = builder.viewportSize
        isViewportSizeLimitedByPhysicalDisplaySize = builder.isViewportSizeLimitedByPhysicalDisplaySize
        viewportOrientationMayChange = builder.viewportOrientationMayChange
        preferredVideoMimeTypes = builder.preferredVideoMimeTypes
        preferredVideoLabels = builder.preferredVideoLabels
        preferredVideoLanguages = builder.preferredVideoLanguages
        preferredVideoRoleFlags = builder.preferredVideoRoleFlags
        preferredAudioLanguages = builder.preferredAudioLanguages
        preferredAudioLabels = builder.preferredAudioLabels
        preferredAudioRoleFlags = builder.preferredAudioRoleFlags
        maxAudioChannelCount = builder.maxAudioChannelCount
        maxAudioBitrate = builder.maxAudioBitrate
        preferredAudioMimeTypes = builder.preferredAudioMimeTypes
        selectTextByDefault = builder.selectTextByDefault
        preferredTextLanguages = builder.preferredTextLanguages
        preferredTextRoleFlags = builder.preferredTextRoleFlags
        usePreferredTextLanguagesAndRoleFlagsFromCaptioningManager = builder.usePreferredTextLanguagesAndRoleFlagsFromCaptioningManager
        preferredTextLabels = builder.preferredTextLabels
        selectUndeterminedTextLanguage = builder.selectUndeterminedTextLanguage
        isPrioritizeImageOverVideoEnabled = builder.isPrioritizeImageOverVideoEnabled
        forceLowestBitrate = builder.forceLowestBitrate
        forceHighestSupportedBitrate = builder.forceHighestSupportedBitrate
        overrides = builder.overrides
        disabledTrackTypes = builder.disabledTrackTypes
    }

    public static func == (lhs: TrackSelectionParameters, rhs: TrackSelectionParameters) -> Bool {
        lhs === rhs || lhs.isEqual(to: rhs)
    }

    public func isEqual(to other: TrackSelectionParameters) -> Bool {
        maxVideoSize == other.maxVideoSize
            && maxVideoFrameRate == other.maxVideoFrameRate
            && maxVideoBitrate == other.maxVideoBitrate
            && minVideoFrameRate == other.minVideoFrameRate
            && minVideoBitrate == other.minVideoBitrate
            && viewportSize == other.viewportSize
            && isViewportSizeLimitedByPhysicalDisplaySize == other.isViewportSizeLimitedByPhysicalDisplaySize
            && viewportOrientationMayChange == other.viewportOrientationMayChange
            && preferredVideoMimeTypes == other.preferredVideoMimeTypes
            && preferredVideoLabels == other.preferredVideoLabels
            && preferredVideoLanguages == other.preferredVideoLanguages
            && preferredVideoRoleFlags == other.preferredVideoRoleFlags
            && preferredAudioLanguages == other.preferredAudioLanguages
            && preferredAudioLabels == other.preferredAudioLabels
            && preferredAudioRoleFlags == other.preferredAudioRoleFlags
            && maxAudioChannelCount == other.maxAudioChannelCount
            && maxAudioBitrate == other.maxAudioBitrate
            && preferredAudioMimeTypes == other.preferredAudioMimeTypes
            // && audioOffloadPreferences == other.audioOffloadPreferences // TODO
            && selectTextByDefault == other.selectTextByDefault
            && preferredTextLanguages == other.preferredTextLanguages
            && preferredTextRoleFlags == other.preferredTextRoleFlags
            && usePreferredTextLanguagesAndRoleFlagsFromCaptioningManager == other.usePreferredTextLanguagesAndRoleFlagsFromCaptioningManager
            && preferredTextLabels == other.preferredTextLabels
            // && ignoredTextSelectionFlags == other.ignoredTextSelectionFlags // TODO
            && selectUndeterminedTextLanguage == other.selectUndeterminedTextLanguage
            && isPrioritizeImageOverVideoEnabled == other.isPrioritizeImageOverVideoEnabled
            && forceLowestBitrate == other.forceLowestBitrate
            && forceHighestSupportedBitrate == other.forceHighestSupportedBitrate
            && overrides == other.overrides
            && disabledTrackTypes == other.disabledTrackTypes
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(maxVideoSize.width)
        hasher.combine(maxVideoSize.height)
        hasher.combine(maxVideoFrameRate)
        hasher.combine(maxVideoBitrate)
        hasher.combine(minVideoFrameRate)
        hasher.combine(minVideoBitrate)
        hasher.combine(viewportSize.width)
        hasher.combine(viewportSize.height)
        hasher.combine(isViewportSizeLimitedByPhysicalDisplaySize)
        hasher.combine(viewportOrientationMayChange)
        hasher.combine(preferredVideoMimeTypes)
        hasher.combine(preferredVideoLabels)
        hasher.combine(preferredVideoLanguages)
        hasher.combine(preferredVideoRoleFlags)
        hasher.combine(preferredAudioLanguages)
        hasher.combine(preferredAudioLabels)
        hasher.combine(preferredAudioRoleFlags)
        hasher.combine(maxAudioChannelCount)
        hasher.combine(maxAudioBitrate)
        hasher.combine(preferredAudioMimeTypes)
        // hasher.combine(audioOffloadPreferences) // TODO
        hasher.combine(selectTextByDefault)
        hasher.combine(preferredTextLanguages)
        hasher.combine(preferredTextRoleFlags)
        hasher.combine(usePreferredTextLanguagesAndRoleFlagsFromCaptioningManager)
        hasher.combine(preferredTextLabels)
        // hasher.combine(ignoredTextSelectionFlags) // TODO
        hasher.combine(selectUndeterminedTextLanguage)
        hasher.combine(isPrioritizeImageOverVideoEnabled)
        hasher.combine(forceLowestBitrate)
        hasher.combine(forceHighestSupportedBitrate)
        hasher.combine(overrides)
        hasher.combine(disabledTrackTypes)
    }
}

public extension TrackSelectionParameters {
    static let defaultParameters = TrackSelectionParameters.Builder().build()

    enum OffloadPreferences {
        case required
        case enabled
        case disabled
    }

    class Builder {
        fileprivate var maxVideoSize: CGSize
        fileprivate var maxVideoFrameRate = Int.max
        fileprivate var maxVideoBitrate = Int.max
        fileprivate var minVideoSize: CGSize
        fileprivate var minVideoFrameRate = 0
        fileprivate var minVideoBitrate = 0
        fileprivate var viewportSize: CGSize
        fileprivate var isViewportSizeLimitedByPhysicalDisplaySize = true
        fileprivate var viewportOrientationMayChange = true
        fileprivate var preferredVideoMimeTypes = [String]()
        fileprivate var preferredVideoLabels = [String]()
        fileprivate var preferredVideoLanguages = [String]()
        fileprivate var preferredVideoRoleFlags = RoleFlags()
        fileprivate var preferredAudioLanguages = [String]()
        fileprivate var preferredAudioLabels = [String]()
        fileprivate var preferredAudioRoleFlags = RoleFlags()
        fileprivate var maxAudioChannelCount = Int.max
        fileprivate var maxAudioBitrate = Int.max
        fileprivate var preferredAudioMimeTypes = [String]()
        // TODO: private var audioOffloadPreferences: AudioOffloadPreferences
        fileprivate var selectTextByDefault = false
        fileprivate var preferredTextLanguages = [String]()
        fileprivate var preferredTextRoleFlags = RoleFlags()
        fileprivate var usePreferredTextLanguagesAndRoleFlagsFromCaptioningManager = true
        fileprivate var preferredTextLabels = [String]()
        // TODO: var ignoredTextSelectionFlags: SelectionFlags
        fileprivate var selectUndeterminedTextLanguage = false
        fileprivate var isPrioritizeImageOverVideoEnabled = false
        fileprivate var forceLowestBitrate = false
        fileprivate var forceHighestSupportedBitrate = false
        fileprivate var overrides = [TrackGroup: TrackSelectionOverride]()
        fileprivate var disabledTrackTypes = Set<TrackType>()

        public init() {
            maxVideoSize = CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            minVideoSize = CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            viewportSize = CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }

        public init(_ initialValues: TrackSelectionParameters) {
            self.maxVideoSize = initialValues.maxVideoSize
            self.maxVideoFrameRate = initialValues.maxVideoFrameRate
            self.maxVideoBitrate = initialValues.maxVideoBitrate
            self.minVideoSize = initialValues.minVideoSize
            self.minVideoFrameRate = initialValues.minVideoFrameRate
            self.minVideoBitrate = initialValues.minVideoBitrate
            self.viewportSize = initialValues.viewportSize
            self.isViewportSizeLimitedByPhysicalDisplaySize = initialValues.isViewportSizeLimitedByPhysicalDisplaySize
            self.viewportOrientationMayChange = initialValues.viewportOrientationMayChange
            self.preferredVideoMimeTypes = initialValues.preferredVideoMimeTypes
            self.preferredVideoLabels = initialValues.preferredVideoLabels
            self.preferredVideoLanguages = initialValues.preferredVideoLanguages
            self.preferredVideoRoleFlags = initialValues.preferredVideoRoleFlags

            self.preferredAudioLanguages = initialValues.preferredAudioLanguages
            self.preferredAudioLabels = initialValues.preferredAudioLabels
            self.preferredAudioRoleFlags = initialValues.preferredAudioRoleFlags
            self.maxAudioChannelCount = initialValues.maxAudioChannelCount
            self.maxAudioBitrate = initialValues.maxAudioBitrate
            self.preferredAudioMimeTypes = initialValues.preferredAudioMimeTypes
//            self.audioOffloadPreferences = initialValues.audioOffloadPreferences

            self.selectTextByDefault = initialValues.selectTextByDefault
            self.preferredTextLanguages = initialValues.preferredTextLanguages
            self.preferredTextRoleFlags = initialValues.preferredTextRoleFlags
            self.usePreferredTextLanguagesAndRoleFlagsFromCaptioningManager = initialValues.usePreferredTextLanguagesAndRoleFlagsFromCaptioningManager
            self.preferredTextLabels = initialValues.preferredTextLabels
//            self.ignoredTextSelectionFlags = initialValues.ignoredTextSelectionFlags
            self.selectUndeterminedTextLanguage = initialValues.selectUndeterminedTextLanguage

            self.isPrioritizeImageOverVideoEnabled = initialValues.isPrioritizeImageOverVideoEnabled

            self.forceLowestBitrate = initialValues.forceLowestBitrate
            self.forceHighestSupportedBitrate = initialValues.forceHighestSupportedBitrate
            self.overrides = initialValues.overrides
            self.disabledTrackTypes = initialValues.disabledTrackTypes
        }

        private func initialise(_ parameters: TrackSelectionParameters) {
            maxVideoSize = parameters.maxVideoSize
            maxVideoFrameRate = parameters.maxVideoFrameRate
            maxVideoBitrate = parameters.maxVideoBitrate
            minVideoSize = parameters.minVideoSize
            minVideoFrameRate = parameters.minVideoFrameRate
            minVideoBitrate = parameters.minVideoBitrate
            viewportSize = parameters.viewportSize
            isViewportSizeLimitedByPhysicalDisplaySize = parameters.isViewportSizeLimitedByPhysicalDisplaySize
            viewportOrientationMayChange = parameters.viewportOrientationMayChange
            preferredVideoMimeTypes = parameters.preferredVideoMimeTypes
            preferredVideoLabels = parameters.preferredVideoLabels
            preferredVideoLanguages = parameters.preferredVideoLanguages
            preferredVideoRoleFlags = parameters.preferredVideoRoleFlags
            preferredAudioLanguages = parameters.preferredAudioLanguages
            preferredAudioLabels = parameters.preferredAudioLabels
            preferredAudioRoleFlags = parameters.preferredAudioRoleFlags
            maxAudioChannelCount = parameters.maxAudioChannelCount
            maxAudioBitrate = parameters.maxAudioBitrate
            preferredAudioMimeTypes = parameters.preferredAudioMimeTypes
            // audioOffloadPreferences = parameters.audioOffloadPreferences
            selectTextByDefault = parameters.selectTextByDefault
            preferredTextLanguages = parameters.preferredTextLanguages
            preferredTextRoleFlags = parameters.preferredTextRoleFlags
            usePreferredTextLanguagesAndRoleFlagsFromCaptioningManager = parameters.usePreferredTextLanguagesAndRoleFlagsFromCaptioningManager
            preferredTextLabels = parameters.preferredTextLabels
//            ignoredTextSelectionFlags = parameters.ignoredTextSelectionFlags
            selectUndeterminedTextLanguage = parameters.selectUndeterminedTextLanguage
            isPrioritizeImageOverVideoEnabled = parameters.isPrioritizeImageOverVideoEnabled
            forceLowestBitrate = parameters.forceLowestBitrate
            forceHighestSupportedBitrate = parameters.forceHighestSupportedBitrate
            overrides = parameters.overrides
            disabledTrackTypes = parameters.disabledTrackTypes
        }

        @discardableResult
        public func set(_ parameters: TrackSelectionParameters) -> Builder {
            initialise(parameters)
            return self
        }

        @discardableResult
        public func setMaxVideoSizeSd() -> Builder {
            setMaxVideoSize(.init(width: 1279, height: 719))
        }

        @discardableResult
        public func clearVideoSizeConstraints() -> Builder {
            setMaxVideoSize(CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            ))
        }

        @discardableResult
        public func setMaxVideoSize(_ size: CGSize) -> Builder {
            self.maxVideoSize = size
            return self
        }

        @discardableResult
        public func setMaxVideoFrameRate(_ maxVideoFrameRate: Int) -> Builder {
            self.maxVideoFrameRate = maxVideoFrameRate
            return self
        }

        @discardableResult
        public func setMaxVideoBitrate(_ maxVideoBitrate: Int) -> Builder {
            self.maxVideoBitrate = maxVideoBitrate
            return self
        }

        @discardableResult
        public func setMinVideoSize(_ minVideoSize: CGSize) -> Builder {
            self.minVideoSize = minVideoSize
            return self
        }

        @discardableResult
        public func setMinVideoFrameRate(_ minVideoFrameRate: Int) -> Builder {
            self.minVideoFrameRate = minVideoFrameRate
            return self
        }

        @discardableResult
        public func setMinVideoBitrate(_ minVideoBitrate: Int) -> Builder {
            self.minVideoBitrate = minVideoBitrate
            return self
        }

        @discardableResult
        public func setViewportSizeToPhysicalDisplaySize(viewportOrientationMayChange: Bool) -> Builder {
            self.isViewportSizeLimitedByPhysicalDisplaySize = true
            self.viewportOrientationMayChange = viewportOrientationMayChange
            self.viewportSize = CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            return self
        }

        @discardableResult
        public func clearViewportSizeConstraints() -> Builder {
            setViewportSize(
                CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                viewportOrientationMayChange: true
            )
        }

        @discardableResult
        public func setViewportSize(
            _ size: CGSize,
            viewportOrientationMayChange: Bool
        ) -> Builder {
            self.viewportSize = size
            self.viewportOrientationMayChange = viewportOrientationMayChange
            self.isViewportSizeLimitedByPhysicalDisplaySize = false
            return self
        }

        @discardableResult
        public func setPreferredVideoMimeType(_ mimeType: String?) -> Builder {
            mimeType == nil ? setPreferredVideoMimeTypes([]) : setPreferredVideoMimeTypes([mimeType!])
        }

        @discardableResult
        public func setPreferredVideoMimeTypes(_ mimeTypes: [String]) -> Builder {
            self.preferredVideoMimeTypes = mimeTypes
            return self
        }

        @discardableResult
        public func setPreferredVideoMimeTypes(_ mimeTypes: String...) -> Builder {
            setPreferredVideoMimeTypes(mimeTypes)
        }

        @discardableResult
        public func setPreferredVideoLanguage(_ preferredVideoLanguage: String?) -> Builder {
            preferredVideoLanguage == nil ? setPreferredVideoLanguages([]) : setPreferredVideoLanguages([preferredVideoLanguage!])
        }

        @discardableResult
        public func setPreferredVideoLanguages(_ preferredVideoLanguages: [String]) -> Builder {
            self.preferredVideoLanguages = normalizeLanguageCodes(preferredVideoLanguages)
            return self
        }

        @discardableResult
        public func setPreferredVideoLanguages(_ preferredVideoLanguages: String...) -> Builder {
            setPreferredVideoLanguages(preferredVideoLanguages)
        }

        @discardableResult
        public func setPreferredVideoLabels(_ preferredVideoLabels: [String]) -> Builder {
            self.preferredVideoLabels = preferredVideoLabels
            return self
        }

        @discardableResult
        public func setPreferredVideoLabels(_ preferredVideoLabels: String...) -> Builder {
            setPreferredVideoLabels(preferredVideoLabels)
        }

        @discardableResult
        public func setPreferredAudioLanguage(_ preferredAudioLanguage: String?) -> Builder {
            preferredAudioLanguage == nil ? setPreferredAudioLanguages([]) : setPreferredAudioLanguages([preferredAudioLanguage!])
        }

        @discardableResult
        public func setPreferredAudioLanguages(_ preferredAudioLanguages: [String]) -> Builder {
            self.preferredAudioLanguages = normalizeLanguageCodes(preferredAudioLanguages)
            return self
        }

        @discardableResult
        public func setPreferredAudioLanguages(_ preferredAudioLanguages: String...) -> Builder {
            setPreferredAudioLanguages(preferredAudioLanguages)
        }

        @discardableResult
        public func setPreferredAudioLabels(_ preferredAudioLabels: [String]) -> Builder {
            self.preferredAudioLabels = preferredAudioLabels
            return self
        }

        @discardableResult
        public func setPreferredAudioLabels(_ preferredAudioLabels: String...) -> Builder {
            setPreferredAudioLabels(preferredAudioLabels)
        }

        @discardableResult
        public func setMaxAudioChannelCount(_ maxAudioChannelCount: Int) -> Builder {
            self.maxAudioChannelCount = maxAudioChannelCount
            return self
        }

        @discardableResult
        public func setMaxAudioBitrate(_ maxAudioBitrate: Int) -> Builder {
            self.maxAudioBitrate = maxAudioBitrate
            return self
        }

        @discardableResult
        public func setPreferredAudioMimeType(_ mimeType: String?) -> Builder {
            mimeType == nil ? setPreferredAudioMimeTypes([]) : setPreferredAudioMimeTypes([mimeType!])
        }

        @discardableResult
        public func setPreferredAudioMimeTypes(_ mimeTypes: [String]) -> Builder {
            self.preferredAudioMimeTypes = mimeTypes
            return self
        }

        @discardableResult
        public func setPreferredAudioMimeTypes(_ mimeTypes: String...) -> Builder {
            setPreferredAudioMimeTypes(mimeTypes)
        }

        @discardableResult
        public func setSelectTextByDefault(_ selectTextByDefault: Bool) -> Builder {
            self.selectTextByDefault = selectTextByDefault
            return self
        }

        @discardableResult
        public func setPreferredTextLanguage(_ preferredTextLanguage: String?) -> Builder {
            preferredTextLanguage == nil ? setPreferredTextLanguages([]) : setPreferredTextLanguages([preferredTextLanguage!])
        }

        @discardableResult
        public func setPreferredTextLanguages(_ preferredTextLanguages: [String]) -> Builder {
            self.preferredTextLanguages = normalizeLanguageCodes(preferredTextLanguages)
            self.usePreferredTextLanguagesAndRoleFlagsFromCaptioningManager = false
            return self
        }

        @discardableResult
        public func setPreferredTextLanguages(_ preferredTextLanguages: String...) -> Builder {
            setPreferredTextLanguages(preferredTextLanguages)
        }

        @discardableResult
        public func setPreferredTextRoleFlags(_ preferredTextRoleFlags: RoleFlags) -> Builder {
            self.preferredTextRoleFlags = preferredTextRoleFlags
            return self
        }

        @discardableResult
        public func setPreferredTextLabels(_ preferredTextLabels: [String]) -> Builder {
            self.preferredTextLabels = preferredTextLabels
            return self
        }

        @discardableResult
        public func setPreferredTextLabels(_ preferredTextLabels: String...) -> Builder {
            setPreferredTextLabels(preferredTextLabels)
        }

        @discardableResult
        public func setSelectUndeterminedTextLanguage(_ selectUndeterminedTextLanguage: Bool) -> Builder {
            self.selectUndeterminedTextLanguage = selectUndeterminedTextLanguage
            return self
        }

        @discardableResult
        public func setPrioritizeImageOverVideoEnabled(_ isPrioritizeImageOverVideoEnabled: Bool) -> Builder {
            self.isPrioritizeImageOverVideoEnabled = isPrioritizeImageOverVideoEnabled
            return self
        }

        @discardableResult
        public func setForceLowestBitrate(_ forceLowestBitrate: Bool) -> Builder {
            self.forceLowestBitrate = forceLowestBitrate
            return self
        }

        @discardableResult
        public func setForceHighestSupportedBitrate(_ forceHighestSupportedBitrate: Bool) -> Builder {
            self.forceHighestSupportedBitrate = forceHighestSupportedBitrate
            return self
        }

        @discardableResult
        public func addOverride(_ override: TrackSelectionOverride) -> Builder {
            overrides[override.mediaTrackGroup] = override
            return self
        }

        @discardableResult
        public func setOverrideForType(_ override: TrackSelectionOverride) -> Builder {
            clearOverridesOfType(override.type)
            overrides[override.mediaTrackGroup] = override
            return self
        }

        @discardableResult
        public func clearOverride(_ mediaTrackGroup: TrackGroup) -> Builder {
            overrides.removeValue(forKey: mediaTrackGroup)
            return self
        }

        @discardableResult
        public func clearOverridesOfType(_ trackType: TrackType) -> Builder {
            overrides = overrides.filter { $0.value.type != trackType }
            return self
        }

        @discardableResult
        public func clearOverrides() -> Builder {
            overrides.removeAll(keepingCapacity: true)
            return self
        }

        @discardableResult
        public func setDisabledTrackTypes(_ disabledTrackTypes: Set<TrackType>) -> Builder {
            self.disabledTrackTypes.removeAll(keepingCapacity: true)
            self.disabledTrackTypes.formUnion(disabledTrackTypes)
            return self
        }

        @discardableResult
        public func setTrackTypeDisabled(_ trackType: TrackType, _ disabled: Bool) -> Builder {
            if disabled {
                disabledTrackTypes.insert(trackType)
            } else {
                disabledTrackTypes.remove(trackType)
            }
            return self
        }

        public func build() -> TrackSelectionParameters {
            TrackSelectionParameters(builder: self)
        }

        private func normalizeLanguageCode(_ s: String) -> String {
            s.replacingOccurrences(of: "_", with: "-").lowercased()
        }

        private func normalizeLanguageCodes(_ languages: [String]) -> [String] {
            languages.map(normalizeLanguageCode)
        }
    }
}

