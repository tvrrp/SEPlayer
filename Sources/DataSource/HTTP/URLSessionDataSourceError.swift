//
//  URLSessionDataSourceError.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//

import Foundation

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

            super.init(reason: .customError(error), message: error.localizedDescription)
            return
        }

        errorReason = ErrorReason(rawValue: error.code)

        if let failedURL = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            self.failedURL = failedURL
        } else {
            self.failedURL = nil
        }

        if let failedHandshakeRef = error.userInfo[NSURLErrorFailingURLErrorKey] as? CFTypeRef,
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

        super.init(reason: .customError(error), message: error.localizedDescription)
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

        super.init(reason: .unknown)
    }
}

public extension URLSessionDataSourceError {
    enum ErrorReason: Int {
        case unknown = -1
        case cancelled = -999
        case badURL = -1000
        case timedOut = -1001
        case unsupportedURL = -1002
        case cannotFindHost = -1003
        case cannotConnectToHost = -1004
        case networkConnectionLost = -1005
        case dnsLookupFailed = -1006
        case httpTooManyRedirects = -1007
        case resourceUnavailable = -1008
        case notConnectedToInternet = -1009
        case redirectToNonExistentLocation = -1010
        case badServerResponse = -1011
        case userCancelledAuthentication = -1012
        case userAuthenticationRequired = -1013
        case zeroByteResource = -1014
        case cannotDecodeRawData = -1015
        case cannotDecodeContentData = -1016
        case cannotParseResponse = -1017
        case appTransportSecurityRequiresSecureConnection = -1022
        case fileDoesNotExist = -1100
        case fileIsDirectory = -1101
        case noPermissionsToReadFile = -1102
        case dataLengthExceedsMaximum = -1103
        case fileOutsideSafeArea = -1104
        // SSL errors
        case secureConnectionFailed = -1200
        case serverCertificateHasBadDate = -1201
        case serverCertificateUntrusted = -1202
        case serverCertificateHasUnknownRoot = -1203
        case serverCertificateNotYetValid = -1204
        case clientCertificateRejected = -1205
        case clientCertificateRequired = -1206
        case cannotLoadFromNetwork = -2000
        // Download and file I/O errors
        case cannotCreateFile = -3000
        case cannotOpenFile = -3001
        case cannotCloseFile = -3002
        case cannotWriteToFile = -3003
        case cannotRemoveFile = -3004
        case cannotMoveFile = -3005
        case downloadDecodingFailedMidStream = -3006
        case downloadDecodingFailedToComplete = -3007

        case internationalRoamingOff = -1018
        case callIsActive = -1019
        case dataNotAllowed = -1020
        case requestBodyStreamExhausted = -1021

        case backgroundSessionRequiresSharedContainer = -995
        case backgroundSessionInUseByAnotherProcess = -996
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
