//
//  SequenceableLoader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

public protocol SequenceableLoaderCallback {
    associatedtype Source
    func continueLoadingRequested(with source: Source)
}

public protocol SequenceableLoader {
    var isLoading: Bool { get }
    func getBufferedPosition() -> CMTime
    func getNextLoadPosition() -> CMTime
    @discardableResult
    func continueLoading(with loadingInfo: LoadingInfo) -> Bool
    func reevaluateBuffer(position: CMTime)
}

extension SequenceableLoader {
    func reevaluateBuffer(position: CMTime) {}
}
