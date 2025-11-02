//
//  TrackGroup.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

public struct TrackGroup: Hashable {
    let id: String
    var length: Int { formats.count }
    let type: TrackType
    let formats: [Format]

    enum TrackGroupError: Error {
        case differentFormatsForTrackGroup
    }

    init(id: String? = nil, formats: [Format]) throws(TrackGroupError) {
        self.id = id ?? ""
        self.type = try! TrackGroup.verify(formats: formats)
        self.formats = formats
    }

    private static func verify(formats: [Format]) throws(TrackGroupError) -> TrackType {
        let types = Set(formats.map { $0.sampleMimeType })
        if types.count > 1 { throw TrackGroupError.differentFormatsForTrackGroup }

        // TODO: compare samples
        for type in types {
            guard let type else { continue }

            if type.isVideo {
                return .video
            } else if type.isAudio {
                return .audio
            } else {
                return .unknown
            }
        }

        return .none
    }

    public static func == (lhs: TrackGroup, rhs: TrackGroup) -> Bool {
        return lhs.id == rhs.id && lhs.formats == rhs.formats
    }
}

public enum TrackType {
    case unknown
    case `default`
    case video
    case audio
    case none
}

extension Array where Element == TrackGroup {
    func index(of group: TrackGroup) -> Int? {
        return self.firstIndex(where: { $0 == group })
    }
}
