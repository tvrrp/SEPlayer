//
//  SequenceableLoader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

protocol SequenceableLoaderCallback {
    associatedtype Source
    func continueLoadingRequested(with source: Source)
}

protocol SequenceableLoader {
    var isLoading: Bool { get }
    func getBufferedPositionUs() -> Int64
    func getNextLoadPositionUs() -> Int64
    @discardableResult
    func continueLoading(with loadingInfo: LoadingInfo) -> Bool
    func reevaluateBuffer(positionUs: Int64)
}

extension SequenceableLoader {
    func reevaluateBuffer(positionUs: Int64) {}
}
