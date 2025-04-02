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
    var bufferedPosition: CMTime { get }
    var nextLoadPosition: CMTime { get }
    var isLoading: Bool { get }
    func continueLoading(with loadingInfo: Void) -> Bool
}
