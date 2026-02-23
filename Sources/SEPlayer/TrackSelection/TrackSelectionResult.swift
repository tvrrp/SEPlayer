//
//  TrackSelectorResult.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 10.01.2025.
//

public struct TrackSelectorResult {
    let rendererConfigurations: [RendererConfiguration?]
    let selections: [SETrackSelection?]
    let tracks: Tracks
    let info: Any?

    init(
        rendererConfigurations: [RendererConfiguration?],
        selections: [SETrackSelection?],
        tracks: Tracks = .empty,
        info: Any? = nil
    ) {
        self.rendererConfigurations = rendererConfigurations
        self.selections = selections
        self.tracks = tracks
        self.info = info
    }

    func isRendererEnabled(for index: Int) -> Bool {
        selections[index] != nil
    }
}

extension TrackSelectorResult: Equatable {
    public static func == (lhs: TrackSelectorResult, rhs: TrackSelectorResult) -> Bool {
        guard lhs.selections.count == rhs.selections.count else { return false }

        for index in 0..<lhs.selections.count {
            if !isEquivalent(lhs: lhs, rhs: rhs, index: index) {
                return false
            }
        }

        return true
    }

    private static func isEquivalent(lhs: TrackSelectorResult, rhs: TrackSelectorResult, index: Int) -> Bool {
        guard let lhsRendererConfiguration = lhs.rendererConfigurations[index],
              let rhsRendererConfiguration = rhs.rendererConfigurations[index],
              let lhsSelections = lhs.selections[index],
              let rhsSelections = rhs.selections[index] else {
            return false
        }

        return lhsRendererConfiguration == rhsRendererConfiguration && lhsSelections.isEquals(to: rhsSelections)
    }
}
