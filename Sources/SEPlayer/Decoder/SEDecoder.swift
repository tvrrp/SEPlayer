//
//  SEDecoder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//

protocol SEDecoder {
    var isReadyForMoreMediaData: Bool { get }
    var isReady: Bool { get }
    func readSamples(enqueueDecodedSample: Bool, didProducedSample: @escaping () -> Void, completion: @escaping (Error?) -> Void)
    func flush()
    func invalidate()
}
