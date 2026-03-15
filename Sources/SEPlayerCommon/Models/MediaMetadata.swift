//
//  MediaMetadata.swift
//  SEPlayer
//
//  Created by tvrrp on 10.03.2026.
//

import Foundation

public struct MediaMetadata: Hashable, Sendable {
    public let title: String?
    public let artist: String?
    public let albumTitle: String?
    public let albumArtist: String?
    public let displayTitle: String?
    public let subtitle: String?
    public let description: String?
    public let durationMs: Int64?
//    public let overallRating: Rating
    public let artworkData: Data?
    public let artworkDataType: PictureType?
    public let artworkUrl: URL?
    public let trackNumber: Int?
    public let totalTrackCount: Int?
    public let isBrowsable: Bool?
    public let isPlayable: Bool?
    public let recordingDate: Date?
    public let releaseDate: Date?
    public let writer: String?
    public let author: String?
    public let composer: String?
    public let conductor: String?
    public let discNumber: Int?
    public let totalDiscCount: Int?
    public let genre: String?
    public let compilation: String?
    public let station: String?
    public let mediaType: MediaType?

    fileprivate init(builder: Builder) {
        title = builder.title
        artist = builder.artist
        albumTitle = builder.albumTitle
        albumArtist = builder.albumArtist
        displayTitle = builder.displayTitle
        subtitle = builder.subtitle
        description = builder.description
        durationMs = builder.durationMs
//        overallRating = builder.overallRating
        artworkData = builder.artworkData
        artworkDataType = builder.artworkDataType
        artworkUrl = builder.artworkUrl
        trackNumber = builder.trackNumber
        totalTrackCount = builder.totalTrackCount
        isBrowsable = builder.isBrowsable
        isPlayable = builder.isPlayable
        recordingDate = builder.recordingDate
        releaseDate = builder.releaseDate
        writer = builder.writer
        author = builder.author
        composer = builder.composer
        conductor = builder.conductor
        discNumber = builder.discNumber
        totalDiscCount = builder.totalDiscCount
        genre = builder.genre
        compilation = builder.compilation
        station = builder.station
        mediaType = builder.mediaType
    }

    public func buildUpon() -> Builder {
        Builder(mediaMetadata: self)
    }
}

public extension MediaMetadata {
    enum MediaType: Hashable, Sendable {
        case mixed
        case music
        case audioBookChapter
        case podcastEpisode
        case radioStation
        case news
        case video
        case trailer
        case movie
        case tvShow
        case album
        case artist
        case genre
        case playlist
        case year
        case audioBook
        case podcast
        case tvChannel
        case tvSeries
        case tvSeason
        case folderMixed
        case folderAlbums
        case folderArtists
        case folderGenres
        case folderPlaylists
        case folderYears
        case folderAudioBooks
        case folderPodcasts
        case folderTvChannels
        case folderTvSeries
        case folderTvShows
        case folderRadioStations
        case folderNews
        case folderVideos
        case folderTrailers
        case folderMovies
    }

    enum PictureType: Hashable, Sendable {
        case other
        case fileIcon
        case fileIconOther
        case frontCover
        case backCover
        case leafletPage
        case media
        case leadArtistPerformer
        case artistPerformer
        case conductor
        case bandOrchestra
        case composer
        case lyricist
        case recordingLocation
        case duringRecording
        case duringPerformance
        case movieVideoScreenCapture
        case aBrightColoredFish
        case illustration
        case bandArtistLogo
        case publisherStudioLogo
    }
}

public extension MediaMetadata {
    final class Builder {
        var title: String?
        var artist: String?
        var albumTitle: String?
        var albumArtist: String?
        var displayTitle: String?
        var subtitle: String?
        var description: String?
        var durationMs: Int64?
        var artworkData: Data?
        var artworkDataType: PictureType?
        var artworkUrl: URL?
        var trackNumber: Int?
        var totalTrackCount: Int?
        var isBrowsable: Bool?
        var isPlayable: Bool?
        var recordingDate: Date?
        var releaseDate: Date?
        var writer: String?
        var author: String?
        var composer: String?
        var conductor: String?
        var discNumber: Int?
        var totalDiscCount: Int?
        var genre: String?
        var compilation: String?
        var station: String?
        var mediaType: MediaType?

        public init() {}

        init(mediaMetadata: MediaMetadata) {
            title = mediaMetadata.title
            artist = mediaMetadata.artist
            albumTitle = mediaMetadata.albumTitle
            albumArtist = mediaMetadata.albumArtist
            displayTitle = mediaMetadata.displayTitle
            subtitle = mediaMetadata.subtitle
            description = mediaMetadata.description
            durationMs = mediaMetadata.durationMs
            artworkData = mediaMetadata.artworkData
            artworkDataType = mediaMetadata.artworkDataType
            artworkUrl = mediaMetadata.artworkUrl
            trackNumber = mediaMetadata.trackNumber
            totalTrackCount = mediaMetadata.totalTrackCount
            isBrowsable = mediaMetadata.isBrowsable
            isPlayable = mediaMetadata.isPlayable
            recordingDate = mediaMetadata.recordingDate
            releaseDate = mediaMetadata.releaseDate
            writer = mediaMetadata.writer
            author = mediaMetadata.author
            composer = mediaMetadata.composer
            conductor = mediaMetadata.conductor
            discNumber = mediaMetadata.discNumber
            totalDiscCount = mediaMetadata.totalDiscCount
            genre = mediaMetadata.genre
            compilation = mediaMetadata.compilation
            station = mediaMetadata.station
            mediaType = mediaMetadata.mediaType
        }

        @discardableResult
        public func setTitle(_ title: String?) -> Builder {
            self.title = title
            return self
        }

        @discardableResult
        public func setArtist(_ artist: String?) -> Builder {
            self.artist = artist
            return self
        }

        @discardableResult
        public func setAlbumTitle(_ albumTitle: String?) -> Builder {
            self.albumTitle = albumTitle
            return self
        }

        @discardableResult
        public func setAlbumArtist(_ albumArtist: String?) -> Builder {
            self.albumArtist = albumArtist
            return self
        }

        @discardableResult
        public func setDisplayTitle(_ displayTitle: String?) -> Builder {
            self.displayTitle = displayTitle
            return self
        }

        @discardableResult
        public func setSubtitle(_ subtitle: String?) -> Builder {
            self.subtitle = subtitle
            return self
        }

        @discardableResult
        public func setDescription(_ description: String?) -> Builder {
            self.description = description
            return self
        }

        @discardableResult
        public func setDurationMs(_ durationMs: Int64?) -> Builder {
            self.durationMs = durationMs
            return self
        }

        @discardableResult
        public func setArtworkData(_ artworkData: Data?) -> Builder {
            self.artworkData = artworkData
            return self
        }

        @discardableResult
        public func setArtworkDataType(_ artworkDataType: PictureType?) -> Builder {
            self.artworkDataType = artworkDataType
            return self
        }

        @discardableResult
        public func setArtworkUrl(_ artworkUrl: URL?) -> Builder {
            self.artworkUrl = artworkUrl
            return self
        }

        @discardableResult
        public func setTrackNumber(_ trackNumber: Int?) -> Builder {
            self.trackNumber = trackNumber
            return self
        }

        @discardableResult
        public func setTotalTrackCount(_ totalTrackCount: Int?) -> Builder {
            self.totalTrackCount = totalTrackCount
            return self
        }

        @discardableResult
        public func setIsBrowsable(_ isBrowsable: Bool?) -> Builder {
            self.isBrowsable = isBrowsable
            return self
        }

        @discardableResult
        public func setIsPlayable(_ isPlayable: Bool?) -> Builder {
            self.isPlayable = isPlayable
            return self
        }

        @discardableResult
        public func setRecordingDate(_ recordingDate: Date?) -> Builder {
            self.recordingDate = recordingDate
            return self
        }

        @discardableResult
        public func setReleaseDate(_ releaseDate: Date?) -> Builder {
            self.releaseDate = releaseDate
            return self
        }

        @discardableResult
        public func setWriter(_ writer: String?) -> Builder {
            self.writer = writer
            return self
        }

        @discardableResult
        public func setAuthor(_ author: String?) -> Builder {
            self.author = author
            return self
        }

        @discardableResult
        public func setComposer(_ composer: String?) -> Builder {
            self.composer = composer
            return self
        }

        @discardableResult
        public func setConductor(_ conductor: String?) -> Builder {
            self.conductor = conductor
            return self
        }

        @discardableResult
        public func setDiscNumber(_ discNumber: Int?) -> Builder {
            self.discNumber = discNumber
            return self
        }

        @discardableResult
        public func setTotalDiscCount(_ totalDiscCount: Int?) -> Builder {
            self.totalDiscCount = totalDiscCount
            return self
        }

        @discardableResult
        public func setGenre(_ genre: String?) -> Builder {
            self.genre = genre
            return self
        }

        @discardableResult
        public func setCompilation(_ compilation: String?) -> Builder {
            self.compilation = compilation
            return self
        }

        @discardableResult
        public func setStation(_ station: String?) -> Builder {
            self.station = station
            return self
        }

        @discardableResult
        public func setMediaType(_ mediaType: MediaType?) -> Builder {
            self.mediaType = mediaType
            return self
        }

        public func build() -> MediaMetadata {
            MediaMetadata(builder: self)
        }
    }
}
