//
//  PlaybackErrorCode.swift
//  SEPlayer
//

/// What failed in playback. The codes are grouped by the stage that failed: loading, parsing, decoding or output.
public enum PlaybackErrorCode: Int, Sendable {
    // MARK: Miscellaneous

    /// The cause is unknown, or not one of the other codes.
    case unspecified = 1000
    /// The playback position fell behind the window of a live stream: the media it needs is no longer available.
    case behindLiveWindow = 1002
    /// An operation took too long, as when playback is stuck buffering without loading.
    case timeout = 1003
    /// A check of the player's own state failed: a bug, not a problem of the media.
    case failedRuntimeCheck = 1004

    // MARK: Input/Output

    /// Loading failed for a reason none of the other input/output codes describes.
    case ioUnspecified = 2000
    /// The connection could not be made or was lost: no network, an unknown host, a failed TLS handshake.
    case ioNetworkConnectionFailed = 2001
    /// The network did not answer in time.
    case ioNetworkConnectionTimeout = 2002
    /// The server answered with a content type the player can't use.
    case ioInvalidHttpContentType = 2003
    /// The server answered with a status code outside 2xx.
    case ioBadHttpStatus = 2004
    /// The file does not exist.
    case ioFileNotFound = 2005
    /// The resource can't be read without permissions or authentication the player doesn't have.
    case ioNoPermission = 2006
    /// App Transport Security does not allow the insecure connection.
    case ioCleartextNotPermitted = 2007
    /// A read started past the end of the resource.
    case ioReadPositionOutOfRange = 2008

    // MARK: Content parsing

    /// The media is malformed.
    case parsingContainerMalformed = 3001
    /// The manifest, as an HLS playlist, is malformed.
    case parsingManifestMalformed = 3002
    /// The media uses a container or a feature of it that isn't supported.
    case parsingContainerUnsupported = 3003
    /// The manifest uses a feature that isn't supported.
    case parsingManifestUnsupported = 3004

    // MARK: Decoding

    /// The decoder could not be created.
    case decoderInitFailed = 4001
    /// Decoding failed.
    case decodingFailed = 4003
    /// The format is beyond what the device can decode, as a resolution too large.
    case decodingFormatExceedsCapabilities = 4004
    /// No decoder supports the format.
    case decodingFormatUnsupported = 4005

    // MARK: Output

    /// The audio output could not be set up.
    case audioOutputInitFailed = 5001
    /// The audio output failed while playing.
    case audioOutputWriteFailed = 5002
    /// The video output failed while displaying.
    case videoOutputFailed = 7000
}

/// An error that knows which ``PlaybackErrorCode`` it is.
public protocol PlaybackErrorCodeProviding: Error {
    var errorCode: PlaybackErrorCode { get }
}
