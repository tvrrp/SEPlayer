//
//  MappingTrackSelector.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 09.06.2025.
//

private typealias Support = RendererCapabilities.Support

public class MappingTrackSelector: TrackSelector {
    public var currentMappedTrackInfo: MappedTrackInfo?

    public final override func onSelectionActivated(info: Any?) {
        guard let info = info as? MappedTrackInfo else {
            return
        }

        currentMappedTrackInfo = info
    }

    override func selectTracks(
        rendererCapabilities: [RendererCapabilitiesResolver],
        trackGroups: TrackGroupArray,
        periodId: MediaPeriodId,
        timeline: Timeline
    ) throws -> TrackSelectorResult {
        var rendererTrackGroupCounts = Array(repeating: 0, count: rendererCapabilities.count + 1)
        var rendererTrackGroups = Array<[TrackGroup?]>(
            repeating: Array(repeating: nil, count: trackGroups.count),
            count: rendererCapabilities.count + 1
        )
        var rendererFormatSupports = Array<[[Support?]]>(
            repeating: Array(
                repeating: Array(repeating: nil, count: trackGroups.count),
                count: trackGroups.count
            ),
            count: rendererCapabilities.count + 1
        )
        let rendererMixedMimeTypeAdaptationSupports = try rendererCapabilities.map { try $0.supportsMixedMimeTypeAdaptation() }

        for group in trackGroups {
            let preferUnassociatedRenderer = group.type == .metadata
            let rendererIndex = try findRenderer(
                rendererCapabilities: rendererCapabilities,
                group: group,
                rendererTrackGroupCounts: rendererTrackGroupCounts,
                preferUnassociatedRenderer: preferUnassociatedRenderer
            )

            let rendererFormatSupport: [Support] = if rendererIndex == rendererCapabilities.count {
                Array(repeating: Support(), count: group.count)
            } else {
                try getFormatSupport(rendererCapabilities[rendererIndex], group: group)
            }

            let rendererTrackGroupCount = rendererTrackGroupCounts[rendererIndex]
            rendererTrackGroups[rendererIndex][rendererTrackGroupCount] = group
            rendererFormatSupports[rendererIndex][rendererTrackGroupCount] = rendererFormatSupport
            rendererTrackGroupCounts[rendererIndex] += 1
        }

        var rendererTrackGroupArrays = [TrackGroupArray]()
        var rendererNames = [String]()
        var rendererTrackTypes = [TrackType]()

        for index in 0..<rendererCapabilities.count {
            let rendererTrackGroupCount = rendererTrackGroupCounts[index]
            rendererTrackGroupArrays.append(TrackGroupArray(
                trackGroups: rendererTrackGroups[index][0..<rendererTrackGroupCount].compactMap { $0 }
            ))
            rendererFormatSupports.append(Array(rendererFormatSupports[index][0..<rendererTrackGroupCount]))
            rendererNames.append(rendererCapabilities[index].name)
            rendererTrackTypes.append(rendererCapabilities[index].trackType)
        }

        let unmappedTrackGroupArray = TrackGroupArray(
            trackGroups: rendererTrackGroups[rendererCapabilities.count][0..<rendererTrackGroupCounts[rendererCapabilities.count]]
                .compactMap { $0 }
        )

        let rendererFormatSupportsMapped = rendererFormatSupports
            .compactMap { $0.compactMap { $0.compactMap { $0 } } }

        let mappedTrackInfo = MappedTrackInfo(
            rendererNames: rendererNames,
            rendererTrackTypes: rendererTrackTypes,
            rendererTrackGroups: rendererTrackGroupArrays,
            rendererMixedMimeTypeAdaptiveSupports: rendererMixedMimeTypeAdaptationSupports,
            rendererFormatSupports: rendererFormatSupportsMapped,
            unmappedTrackGroups: unmappedTrackGroupArray
        )

        let (rendererConfigurations, selections) = try selectTracks(
            mappedTrackInfo: mappedTrackInfo,
            rendererFormatSupports: rendererFormatSupportsMapped,
            rendererMixedMimeTypeAdaptationSupport: rendererMixedMimeTypeAdaptationSupports,
            mediaPeriodId: periodId,
            timeline: timeline
        )

        return TrackSelectorResult(
            rendererConfigurations: rendererConfigurations,
            selections: selections,
            tracks: buildTracks(
                mappedTrackInfo: mappedTrackInfo,
                selections: selections
            ),
            info: mappedTrackInfo
        )
    }

    func selectTracks(
        mappedTrackInfo: MappedTrackInfo,
        rendererFormatSupports: [[[RendererCapabilities.Support]]],
        rendererMixedMimeTypeAdaptationSupport: [RendererCapabilities.Support.AdaptiveSupport],
        mediaPeriodId: MediaPeriodId,
        timeline: Timeline
    ) throws -> ([RendererConfiguration?], [SETrackSelection?]) {
        fatalError("To override")
    }

    private func buildTracks(
        mappedTrackInfo: MappedTrackInfo,
        selections: [TrackSelection?]
    ) -> Tracks {
        let selections: [[TrackSelection]] = selections.map { selection in
            selection.map { [$0] } ?? []
        }
        return buildTracks(mappedTrackInfo: mappedTrackInfo, selections: selections)
    }

    private func buildTracks(
        mappedTrackInfo: MappedTrackInfo,
        selections: [[TrackSelection]]
    ) -> Tracks {
        var groups: [Tracks.Group] = []

        for rendererIndex in 0..<mappedTrackInfo.rendererCount {
            let trackGroupArray = mappedTrackInfo.rendererTrackGroups[rendererIndex]
            let rendererTrackSelections = rendererIndex < selections.count ? selections[rendererIndex] : []

            for (groupIndex, trackGroup) in trackGroupArray.enumerated() {
                let adaptiveSupported = mappedTrackInfo.rendererMixedMimeTypeAdaptiveSupports[rendererIndex] != .notSupported

                let trackCount = trackGroup.length
                var trackSupport = Array<Support.FormatSupport>(repeating: .unsupportedType, count: trackCount)
                var selected = Array(repeating: false, count: trackCount)

                for trackIndex in 0..<trackCount {
                    trackSupport[trackIndex] = mappedTrackInfo.rendererFormatSupports[rendererIndex][groupIndex][trackIndex].formatSupport

                    var isTrackSelected = false
                    for trackSelection in rendererTrackSelections {
                        if trackSelection.trackGroup == trackGroup,
                           trackSelection.indexOf(indexInTrackGroup: trackIndex) != nil {
                            isTrackSelected = true
                            break
                        }
                    }
                    selected[trackIndex] = isTrackSelected
                }

                groups.append(.init(
                    mediaTrackGroup: trackGroup,
                    adaptiveSupported: adaptiveSupported,
                    trackSupport: trackSupport,
                    trackSelected: selected
                ))
            }
        }

        for trackGroup in mappedTrackInfo.unmappedTrackGroups {
            let trackCount = trackGroup.length
            let trackSupport = Array<Support.FormatSupport>(
                repeating: .unsupportedType,
                count: trackCount
            )
            let selected = Array(repeating: false, count: trackCount)

            groups.append(
                Tracks.Group(
                    mediaTrackGroup: trackGroup,
                    adaptiveSupported: false,
                    trackSupport: trackSupport,
                    trackSelected: selected
                )
            )
        }

        return Tracks(groups: groups)
    }

    private func findRenderer(
        rendererCapabilities: [RendererCapabilitiesResolver],
        group: TrackGroup,
        rendererTrackGroupCounts: [Int],
        preferUnassociatedRenderer: Bool
    ) throws -> Int {
        var bestRendererIndex = rendererCapabilities.count
        var bestFormatSupportLevel = Support.FormatSupport.unsupportedType
        var bestRendererIsUnassociated = true

        for (rendererIndex, rendererCapability) in rendererCapabilities.enumerated() {
            let formatSupportLevel: Support.FormatSupport = try group.reduce(.unsupportedType, {
                try max($0, rendererCapability.supportsFormat($1).formatSupport)
            })
            let rendererIsUnassociated = rendererTrackGroupCounts[rendererIndex] == 0

            if formatSupportLevel > bestFormatSupportLevel ||
                (formatSupportLevel == bestFormatSupportLevel
                 && preferUnassociatedRenderer
                 && !bestRendererIsUnassociated
                 && rendererIsUnassociated) {
                bestRendererIndex = rendererIndex
                bestFormatSupportLevel = formatSupportLevel
                bestRendererIsUnassociated = rendererIsUnassociated
            }
        }

        return bestRendererIndex
    }

    private func getFormatSupport(
        _ rendererCapabilities: RendererCapabilitiesResolver,
        group: TrackGroup
    ) throws -> [Support] {
        try group.map { try rendererCapabilities.supportsFormat($0) }
    }
}

public extension MappingTrackSelector {
    struct MappedTrackInfo {
        let rendererCount: Int
        let rendererNames: [String]
        let rendererTrackTypes: [TrackType]
        let rendererTrackGroups: [TrackGroupArray]
        let rendererMixedMimeTypeAdaptiveSupports: [RendererCapabilities.Support.AdaptiveSupport]
        let rendererFormatSupports: [[[RendererCapabilities.Support]]]
        let unmappedTrackGroups: TrackGroupArray

        enum RendererSupport: Comparable {
            case noTracks
            case unsupportedTracks
            case exceedCapabilitiesTracks
            case playableTraks
        }

        init(
            rendererNames: [String],
            rendererTrackTypes: [TrackType],
            rendererTrackGroups: [TrackGroupArray],
            rendererMixedMimeTypeAdaptiveSupports: [RendererCapabilities.Support.AdaptiveSupport],
            rendererFormatSupports: [[[RendererCapabilities.Support]]],
            unmappedTrackGroups: TrackGroupArray
        ) {
            self.rendererNames = rendererNames
            self.rendererTrackTypes = rendererTrackTypes
            self.rendererTrackGroups = rendererTrackGroups
            self.rendererMixedMimeTypeAdaptiveSupports = rendererMixedMimeTypeAdaptiveSupports
            self.rendererFormatSupports = rendererFormatSupports
            self.unmappedTrackGroups = unmappedTrackGroups
            self.rendererCount = rendererTrackTypes.count
        }

        func getRendererSupport(rendererIndex: Int) -> RendererSupport {
            var bestRendererSupport = RendererSupport.noTracks
            let rendererFormatSupport = rendererFormatSupports[rendererIndex]

            for trackGroupFormatSupport in rendererFormatSupport {
                for trackFormatSupport in trackGroupFormatSupport {
                    let trackRendererSupport: RendererSupport = switch trackFormatSupport.formatSupport {
                    case .handled:
                        .playableTraks
                    case .exceedCapabilities:
                        .exceedCapabilitiesTracks
                    case .unsupportedType, .unsupportedSubtype, .unsupportedDrm:
                        .unsupportedTracks
                    }

                    bestRendererSupport = max(bestRendererSupport, trackRendererSupport)
                }
            }

            return bestRendererSupport
        }

        func getTypeSupport(_ trackType: TrackType) -> RendererSupport {
            var bestRendererSupport = RendererSupport.noTracks
            for (index, rendererTrackType) in rendererTrackTypes.enumerated() {
                if rendererTrackType == trackType {
                    bestRendererSupport = max(bestRendererSupport, getRendererSupport(rendererIndex: index))
                }
            }

            return bestRendererSupport
        }
    }
}
