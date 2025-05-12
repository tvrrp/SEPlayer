//
//  SequenceableLoader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

protocol SequenceableLoaderCallback {
    associatedtype Source
    func continueLoadingRequested(with source: Source)
}

protocol SequenceableLoader {
    var bufferedPosition: Int64 { get }
    var nextLoadPosition: Int64 { get }
    var isLoading: Bool { get }
    @discardableResult
    func continueLoading(with loadingInfo: LoadingInfo) -> Bool
}
