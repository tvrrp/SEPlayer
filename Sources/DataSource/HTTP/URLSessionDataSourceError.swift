//
//  URLSessionDataSourceError.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//

import Foundation
import SEPlayerCommon

public final class URLSessionDataSourceError: DataSourceError, @unchecked Sendable {
    /// URL which caused a load to fail
    public let failedURL: URL?
    /// Errors in the NSURL domain
    public let errorReason: ErrorReason?
    /// SecTrustRef object representing the state of a failed SSL handshake
    public let failedHandshake: SecTrust?
    /// Corresponding to the reason why a background URLSessionTask was cancelled
    public let backgroundTaskCancelledReason: BackgroundTaskCancelledReason?
    /// Reason why the network is unavailable when the task failed due to unsatisfiable network constraints
    public let networkUnavailableReason: NetworkUnavailableReason?

    public init(error: NSError) {
        guard error.domain == NSURLErrorDomain else {
            failedURL = nil
            errorReason = nil
            failedHandshake = nil
            backgroundTaskCancelledReason = nil
            networkUnavailableReason = nil

            super.init(reason: .customError(error), message: error.localizedDescription, errorCode: .ioUnspecified)
            return
        }

        errorReason = ErrorReason(rawValue: error.code)

        if let failedURL = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            self.failedURL = failedURL
        } else {
            self.failedURL = nil
        }

        if let failedHandshakeRef = error.userInfo[NSURLErrorFailingURLPeerTrustErrorKey] as? CFTypeRef,
           CFGetTypeID(failedHandshakeRef) == SecTrustGetTypeID() {
            self.failedHandshake = (failedHandshakeRef as! SecTrust)
        } else {
            self.failedHandshake = nil
        }

        backgroundTaskCancelledReason = if let code = error.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int {
            BackgroundTaskCancelledReason(rawValue: code)
        } else {
            nil
        }

        networkUnavailableReason = if let code = error.userInfo[NSURLErrorNetworkUnavailableReasonKey] as? Int {
            NetworkUnavailableReason(rawValue: code)
        } else {
            nil
        }

        super.init(
            reason: .customError(error),
            message: error.localizedDescription,
            errorCode: errorReason?.errorCode ?? .ioUnspecified
        )
    }

    init(
        failedURL: URL? = nil,
        errorReason: ErrorReason? = nil,
        failedHandshake: SecTrust? = nil,
        backgroundTaskCancelledReason: BackgroundTaskCancelledReason? = nil,
        networkUnavailableReason: NetworkUnavailableReason? = nil
    ) {
        self.failedURL = failedURL
        self.errorReason = errorReason
        self.failedHandshake = failedHandshake
        self.backgroundTaskCancelledReason = backgroundTaskCancelledReason
        self.networkUnavailableReason = networkUnavailableReason

        if let errorReason {
            super.init(reason: .customError(errorReason), errorCode: errorReason.errorCode)
        } else {
            super.init(reason: .unknown)
        }
    }
}

public extension URLSessionDataSourceError {
    enum ErrorReason: Int, Error {
        /// The URL Loading System encountered an error that it can't interpret.
        ///
        /// This can occur when an error originates from a lower level framework or library. Whenever this error code is received, it is a bug, and should be reported to Apple.
        case unknown = -1

        /// An asynchronous load has been canceled.
        ///
        /// `NSURLSession` sends this error to its delegate when a task is cancelled.
        case cancelled = -999

        /// A malformed URL prevented a URL request from being initiated.
        case badURL = -1000

        /// An asynchronous operation timed out.
        ///
        /// ``URLSession`` sends this error to its delegate when the ``NSURLRequest/timeoutInterval`` of an ``NSURLRequest`` expires before a load can complete.
        case timedOut = -1001

        /// A properly formed URL couldn't be handled by the framework.
        ///
        /// The most likely cause is that there is no available protocol handler for the URL.
        case unsupportedURL = -1002

        /// The host name for a URL couldn't be resolved.
        case cannotFindHost = -1003
        /// An attempt to connect to a host failed.
        ///
        /// This can occur when a host name resolves, but the host is down or may not be accepting connections on a certain port.
        case cannotConnectToHost = -1004

        /// A client or server connection was severed in the middle of an in-progress load.
        case networkConnectionLost = -1005

        /// The host address couldn't be found via DNS lookup.
        ///
        /// This error code is no longer used. You should expect to handle ``NSURLErrorCannotFindHost`` instead.
        case dnsLookupFailed = -1006

        /// A redirect loop was detected or the threshold for number of allowable redirects was exceeded (currently 16).
        case httpTooManyRedirects = -1007

        /// A requested resource couldn't be retrieved.
        ///
        /// This error can indicate a file-not-found situation, or decoding problems that prevent data from being processed correctly.
        case resourceUnavailable = -1008

        /// A network resource was requested, but an internet connection has not been established and can't be established automatically.
        ///
        /// This error occurs when the connection can't be established due to a lack of connectivity or because the user chooses not to make a network connection automatically.
        case notConnectedToInternet = -1009

        /// A redirect was specified by way of server response code, but the server didn't accompany this code with a redirect URL.
        case redirectToNonExistentLocation = -1010

        /// The URL Loading System received bad data from the server.
        ///
        /// This is equivalent to the "500 Server Error" message sent by HTTP servers.
        case badServerResponse = -1011

        /// An asynchronous request for authentication has been canceled by the user.
        ///
        /// This is typically incurred by clicking a "Cancel" button in a username/password dialog, rather than the user making an attempt to authenticate.
        case userCancelledAuthentication = -1012

        /// Authentication was required to access a resource.
        case userAuthenticationRequired = -1013

        /// A server reported that a URL has a non-zero content length, but terminated the network connection gracefully without sending any data.
        case zeroByteResource = -1014

        /// Content data received during a connection request couldn't be decoded for a known content encoding.
        case cannotDecodeRawData = -1015

        /// Content data received during a connection request had an unknown content encoding.
        case cannotDecodeContentData = -1016

        /// A response to a connection request couldn't be parsed.
        case cannotParseResponse = -1017

        /// App Transport Security disallowed a connection because there is no secure network connection.
        ///
        /// Starting in iOS 9.0 and macOS 10.11, App Transport Security (ATS) is enabled by default for connections created by ``URLSession``. ATS requires the use of best practice secure protocols in HTTPS.
        case appTransportSecurityRequiresSecureConnection = -1022

        /// The specified file doesn't exist.
        case fileDoesNotExist = -1100

        /// A request for an FTP file resulted in the server responding that the file is not a plain file, but a directory.
        case fileIsDirectory = -1101

        /// A resource couldn't be read because of insufficient permissions.
        case noPermissionsToReadFile = -1102

        /// The length of the resource data exceeded the maximum allowed.
        case dataLengthExceedsMaximum = -1103

        /// An internal file operation failed.
        ///
        /// This error is never sent to third-party apps.
        case fileOutsideSafeArea = -1104

        // SSL errors

        /// An attempt to establish a secure connection failed for reasons that can't be expressed more specifically.
        case secureConnectionFailed = -1200

        /// A server certificate is expired, or is not yet valid.
        case serverCertificateHasBadDate = -1201

        /// A server certificate was signed by a root server that isn't trusted.
        case serverCertificateUntrusted = -1202

        /// A server certificate wasn't signed by any root server.
        case serverCertificateHasUnknownRoot = -1203

        /// A server certificate isn't valid yet.
        case serverCertificateNotYetValid = -1204

        /// A server certificate was rejected.
        case clientCertificateRejected = -1205

        /// A client certificate was required to authenticate an SSL connection during a connection request.
        case clientCertificateRequired = -1206

        /// A specific request to load an item only from the cache couldn't be satisfied.
        ///
        /// This error is sent when the task needs to load from the network, but is blocked from doing so by the "load only from cache" directive.
        case cannotLoadFromNetwork = -2000

        // Download and file I/O errors

        /// A download task couldn't create the downloaded file on disk because of an I/O failure.
        case cannotCreateFile = -3000

        /// A downloaded file on disk couldn't be opened.
        case cannotOpenFile = -3001

        /// A download task couldn't close the downloaded file on disk.
        case cannotCloseFile = -3002

        /// A download task couldn't write the file to disk.
        case cannotWriteToFile = -3003

        /// A downloaded file couldn't be removed from disk.
        case cannotRemoveFile = -3004

        /// A downloaded file on disk couldn't be moved.
        case cannotMoveFile = -3005

        /// A download task failed to decode an encoded file during the download.
        case downloadDecodingFailedMidStream = -3006

        /// A download task failed to decode an encoded file after downloading.
        case downloadDecodingFailedToComplete = -3007

        /// The attempted connection required activating a data context while roaming, but international roaming is disabled.
        case internationalRoamingOff = -1018

        /// A connection was attempted while a phone call was active on a network that doesn't support simultaneous phone and data communication, such as EDGE or GPRS.
        case callIsActive = -1019

        /// The cellular network disallowed a connection.
        case dataNotAllowed = -1020

        /// A body stream was needed but the client did not provide one.
        ///
        /// This impacts clients on iOS that send a `POST` request using a body stream but do not implement the ``URLSessionTaskDelegate`` delegate method ``URLSessionTaskDelegate/urlSession(_:task:needNewBodyStream:)``.
        case requestBodyStreamExhausted = -1021

        /// The shared container identifier of the URL session configuration is needed but hasn't been set.
        ///
        /// To use a ``URLSession`` to perform background uploading or downloading in an app extension, you coordinate with the host app using a shared container. The app extension must set the ``URLSessionConfiguration/sharedContainerIdentifier`` of the URL session's configuration to the shared container's identifier.
        case backgroundSessionRequiresSharedContainer = -995

        /// An app or app extension attempted to connect to a background session that is already connected to a process.
        ///
        /// This error can occur when both an app and an app extension attempt to use a background session at the same time.
        case backgroundSessionInUseByAnotherProcess = -996

        /// The app is suspended or exits while a background data task is processing.
        ///
        /// If your app has created a background data task and the app is then suspended, the task will fail with this error code. To prevent this, when you receive the response, convert the data task to a download task.
        case backgroundSessionWasDisconnected = -997
    }

    enum BackgroundTaskCancelledReason: Int {
        case userForceQuitApplication = 0
        case backgroundUpdatesDisabled = 1
        case unsufficientSystemResources = 2
    }

    enum NetworkUnavailableReason: Int {
        case cellular = 0
        case expensive = 1
        case constrained = 2
        case ultraConstrained = 3
    }
}

extension URLSessionDataSourceError.ErrorReason {
    var errorCode: PlaybackErrorCode {
        switch self {
        case .timedOut:
            .ioNetworkConnectionTimeout
        case .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .cannotLoadFromNetwork,
             .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            .ioNetworkConnectionFailed
        case .appTransportSecurityRequiresSecureConnection:
            .ioCleartextNotPermitted
        case .fileDoesNotExist:
            .ioFileNotFound
        case .noPermissionsToReadFile,
             .userAuthenticationRequired,
             .userCancelledAuthentication:
            .ioNoPermission
        default:
            .ioUnspecified
        }
    }

    /// Whether loading again can't succeed: the request itself is wrong, not the network.
    public var isPermanent: Bool {
        switch self {
        case .badURL,
             .unsupportedURL,
             .httpTooManyRedirects,
             .redirectToNonExistentLocation,
             .appTransportSecurityRequiresSecureConnection,
             .fileDoesNotExist,
             .fileIsDirectory,
             .noPermissionsToReadFile,
             .userAuthenticationRequired,
             .userCancelledAuthentication,
             .dataLengthExceedsMaximum:
            true
        default:
            false
        }
    }
}
