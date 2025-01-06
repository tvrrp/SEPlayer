//
//  TrackGroup.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

struct TrackGroup: Hashable {
    let id: String?
    let type: TrackType
    let formats: [CMFormatDescription]

    enum TrackGroupError: Error {
        case differentFormatsForTrackGroup
    }

    init(id: String? = nil, formats: [CMFormatDescription]) throws(TrackGroupError) {
        self.id = id
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
}

extension Set where Element == TrackGroup {
    func trackTypes() -> [TrackType] {
        return map { $0.type }
    }

    func indexOf(trackGroup: TrackGroup) {
        
    }
}

enum TrackType {
    case video
    case audio
    case unknown
}
