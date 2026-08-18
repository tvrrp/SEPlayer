//
//  MimeTypeResolver.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 10.08.2026.
//

import SEPlayerCommon

extension MimeTypes {
    init(from trackSampleTables: [TrackSampleTable]) {
        var hasAudio = false
        var imageMimeType: MimeTypes?

        for trackSampleTable in trackSampleTables {
            guard let sampleMimeType = trackSampleTable.track.format.sampleMimeType else {
                continue
            }

            if sampleMimeType.isVideo {
                self = .videoMP4; return
            }

            if sampleMimeType.isAudio {
                hasAudio = true
            } else if sampleMimeType.isImage {
                if sampleMimeType == .imageHEIC {
                    imageMimeType = .imageHEIF
                } else if sampleMimeType == .imageAVIF {
                    imageMimeType = sampleMimeType
                }
            }
        }

        if hasAudio {
            self = .audioMP4; return
        } else if let imageMimeType {
            self = imageMimeType; return
        }

        self = .applicationMP4; return
    }

    init(format: Format) {
        guard let sampleMimeType = format.sampleMimeType else {
            self = .applicationMP4; return
        }

        if sampleMimeType.isVideo == true {
            self = .videoMP4; return
        }

        if sampleMimeType.isAudio {
            self = .audioMP4; return
        }

        if sampleMimeType.isImage {
            if sampleMimeType == .imageHEIC {
                self = .imageHEIF; return
            } else if sampleMimeType == .imageAVIF {
                self = .imageAVIF; return
            }
        }

        self = .applicationMP4
    }
}
