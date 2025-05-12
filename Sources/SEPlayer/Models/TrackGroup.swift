//
//  TrackGroup.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

struct TrackGroup: Hashable {
    let id: String
    var length: Int { formats.count }
    let type: TrackType
    let formats: [CMFormatDescription]

    enum TrackGroupError: Error {
        case differentFormatsForTrackGroup
    }

    init(id: String? = nil, formats: [CMFormatDescription]) throws(TrackGroupError) {
        self.id = id ?? ""
        self.type = try TrackGroup.verify(formats: formats)
        self.formats = formats
    }

    private static func verify(formats: [CMFormatDescription]) throws(TrackGroupError) -> TrackType {
        let types = Set(formats.map { $0.mediaType })
        if types.count > 1 { throw TrackGroupError.differentFormatsForTrackGroup }
        for type in types {
            switch type {
            case .video:
                return TrackType.video
            case .audio:
                return TrackType.audio
            default:
                return TrackType.unknown
            }
        }
        throw TrackGroupError.differentFormatsForTrackGroup
    }

    static func == (lhs: TrackGroup, rhs: TrackGroup) -> Bool {
        return lhs.id == rhs.id && lhs.formats == rhs.formats
    }
}

enum TrackType {
    case video
    case audio
    case unknown
}

extension Array where Element == TrackGroup {
    func index(of group: TrackGroup) -> Int? {
        return self.firstIndex(where: { $0 == group })
    }
}
