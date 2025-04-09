//
//  TrackOutput.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

protocol TrackOutput {
    func sampleData(input: DataReader, allowEndOfInput: Bool, metadata: SampleMetadata, completionQueue: Queue, completion: @escaping (Error?) -> Void)
}
