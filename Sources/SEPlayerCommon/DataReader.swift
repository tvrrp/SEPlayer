//
//  DataReader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.05.2025.
//

import CoreMedia

public protocol DataReader {
    var isolation: any Actor { get }
    func read(range: Range<Int>, _ isolation: isolated any Actor) async throws -> CMBlockBuffer?
}
