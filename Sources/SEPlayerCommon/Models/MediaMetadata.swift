//
//  MediaMetadata.swift
//  SEPlayer
//
//  Created by tvrrp on 10.03.2026.
//

import CoreMedia
import Foundation

public struct MediaMetadata: Hashable, Sendable {
    public let title: String?
    public let artist: String?
    public let albumTitle: String?
    public let albumArtist: String?
    public let displayTitle: String?
    public let subtitle: String?
    public let description: String?
    public let duration: CMTime?
//    public let overallRating: Rating
    public let artworkData: Data?
    public let artworkDataType: PictureType?
    public let artworkUrl: URL?
    public let trackNumber: Int?
    public let totalTrackCount: Int?
    public let isBrowsable: Bool?
    public let isPlayable: Bool?
    /// When the media was recorded: the year, or the year and the month, when no more is known.
    public let recordingDate: DateComponents?
    /// When the media was released: the year, or the year and the month, when no more is known.
    public let releaseDate: DateComponents?
    public let writer: String?
    public let author: String?
    public let composer: String?
    public let conductor: String?
    public let discNumber: Int?
    public let totalDiscCount: Int?
    public let discSubtitle: String?
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
        duration = builder.duration
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
        discSubtitle = builder.discSubtitle
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

    /// The type of a picture, numbered as in ID3 APIC frames.
    enum PictureType: Int, Hashable, Sendable {
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
    /// No metadata.
    static let empty = Builder().build()

    final class Builder {
        var title: String?
        var artist: String?
        var albumTitle: String?
        var albumArtist: String?
        var displayTitle: String?
        var subtitle: String?
        var description: String?
        var duration: CMTime?
        var artworkData: Data?
        var artworkDataType: PictureType?
        var artworkUrl: URL?
        var trackNumber: Int?
        var totalTrackCount: Int?
        var isBrowsable: Bool?
        var isPlayable: Bool?
        var recordingDate: DateComponents?
        var releaseDate: DateComponents?
        var writer: String?
        var author: String?
        var composer: String?
        var conductor: String?
        var discNumber: Int?
        var totalDiscCount: Int?
        var discSubtitle: String?
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
            duration = mediaMetadata.duration
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
            discSubtitle = mediaMetadata.discSubtitle
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
        public func setDuration(_ duration: CMTime?) -> Builder {
            self.duration = duration
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
        public func setRecordingDate(_ recordingDate: DateComponents?) -> Builder {
            self.recordingDate = recordingDate
            return self
        }

        /// Sets the parts of the recording date that are given, and keeps the others: tags may tell the year apart
        /// from the month and the day.
        @discardableResult
        public func setRecordingDate(year: Int? = nil, month: Int? = nil, day: Int? = nil) -> Builder {
            var date = recordingDate ?? DateComponents()
            if let year { date.year = year }
            if let month { date.month = month }
            if let day { date.day = day }
            recordingDate = date
            return self
        }

        @discardableResult
        public func setReleaseDate(_ releaseDate: DateComponents?) -> Builder {
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

        @discardableResult
        public func setDiscSubtitle(_ discSubtitle: String?) -> Builder {
            self.discSubtitle = discSubtitle
            return self
        }

        /// Sets the artwork unless there is front cover artwork already and this isn't a front cover.
        @discardableResult
        public func maybeSetArtworkData(_ artworkData: Data, pictureType: PictureType?) -> Builder {
            if self.artworkData == nil || pictureType == .frontCover || artworkDataType != .frontCover {
                self.artworkData = artworkData
                artworkDataType = pictureType
            }
            return self
        }

        /// Sets the fields the entries of `metadata` describe.
        @discardableResult
        public func populate(from metadata: [Metadata]) -> Builder {
            for entry in metadata.flatMap(\.entries) {
                entry.populateMediaMetadata(self)
            }
            return self
        }

        /// Sets the fields that `mediaMetadata` has.
        @discardableResult
        public func populate(from mediaMetadata: MediaMetadata) -> Builder {
            func merge<T>(_ keyPath: ReferenceWritableKeyPath<Builder, T?>, _ value: T?) {
                if let value { self[keyPath: keyPath] = value }
            }
            merge(\.title, mediaMetadata.title)
            merge(\.artist, mediaMetadata.artist)
            merge(\.albumTitle, mediaMetadata.albumTitle)
            merge(\.albumArtist, mediaMetadata.albumArtist)
            merge(\.displayTitle, mediaMetadata.displayTitle)
            merge(\.subtitle, mediaMetadata.subtitle)
            merge(\.description, mediaMetadata.description)
            merge(\.duration, mediaMetadata.duration)
            if let artworkData = mediaMetadata.artworkData {
                self.artworkData = artworkData
                artworkDataType = mediaMetadata.artworkDataType
            }
            merge(\.artworkUrl, mediaMetadata.artworkUrl)
            merge(\.trackNumber, mediaMetadata.trackNumber)
            merge(\.totalTrackCount, mediaMetadata.totalTrackCount)
            merge(\.isBrowsable, mediaMetadata.isBrowsable)
            merge(\.isPlayable, mediaMetadata.isPlayable)
            merge(\.recordingDate, mediaMetadata.recordingDate)
            merge(\.releaseDate, mediaMetadata.releaseDate)
            merge(\.writer, mediaMetadata.writer)
            merge(\.author, mediaMetadata.author)
            merge(\.composer, mediaMetadata.composer)
            merge(\.conductor, mediaMetadata.conductor)
            merge(\.discNumber, mediaMetadata.discNumber)
            merge(\.totalDiscCount, mediaMetadata.totalDiscCount)
            merge(\.discSubtitle, mediaMetadata.discSubtitle)
            merge(\.genre, mediaMetadata.genre)
            merge(\.compilation, mediaMetadata.compilation)
            merge(\.station, mediaMetadata.station)
            merge(\.mediaType, mediaMetadata.mediaType)
            return self
        }

        public func build() -> MediaMetadata {
            MediaMetadata(builder: self)
        }
    }
}
