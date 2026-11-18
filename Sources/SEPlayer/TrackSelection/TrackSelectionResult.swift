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
            if !lhs.isEquivalent(to: rhs, at: index) {
                return false
            }
        }

        return true
    }

    /// Whether the renderer at `index` is configured the same in both, disabled renderers included.
    func isEquivalent(to other: TrackSelectorResult?, at index: Int) -> Bool {
        guard let other, index < selections.count, index < other.selections.count else {
            return false
        }
        guard rendererConfigurations[index] == other.rendererConfigurations[index] else {
            return false
        }

        switch (selections[index], other.selections[index]) {
        case (nil, nil):
            return true
        case let (lhsSelection?, rhsSelection?):
            return lhsSelection.isEquals(to: rhsSelection)
        default:
            return false
        }
    }
}
