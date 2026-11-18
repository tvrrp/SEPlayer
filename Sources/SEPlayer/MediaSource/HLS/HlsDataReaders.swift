//
//  HlsDataReaders.swift
//  SEPlayer
//

import CommonCrypto
import CoreMedia
import Foundation
import SEPlayerCommon

/// Reads only a range of the resource: a segment given by a byte range ends there, not at the end of the file.
final class BoundedDataReader: DataReader {
    var isolation: any Actor { upstream.isolation }

    private let upstream: DataReader
    private let bounds: Range<Int>?

    /// - Parameter end: Where the readable range ends, or `nil` for the end of the resource.
    init(upstream: DataReader, end: Int?) {
        self.upstream = upstream
        bounds = end.map { 0 ..< $0 }
    }

    func read(range: Range<Int>, _ isolation: isolated any Actor) async throws -> CMBlockBuffer? {
        guard let bounds else {
            return try await upstream.read(range: range, isolation)
        }
        let clamped = range.clamped(to: bounds)
        // The end of the range is the end of the input.
        guard !clamped.isEmpty else { return nil }
        return try await upstream.read(range: clamped, isolation)
    }
}

/// Decrypts a segment encrypted with AES-128 in CBC mode with PKCS7 padding, as for #EXT-X-KEY `METHOD=AES-128`.
///
/// Positions of the decrypted data are those of the encrypted data, from the start of the segment: padding only
/// removes bytes from the end. The segment is decrypted in order into pieces of pooled memory, and reads reference the
/// pieces without copying. Pieces well behind the reads are dropped. A read that goes back to dropped bytes starts
/// decrypting again from there: in CBC mode a block needs only the encrypted block before it.
final class Aes128DataReader: DataReader {
    enum DecryptionError: Error {
        case invalidKey
        case cryptor(CCCryptorStatus)
    }

    var isolation: any Actor { upstream.isolation }

    private let upstream: DataReader
    private let start: Int
    private let end: Int?
    private let key: Data
    private let iv: Data
    /// The memory of the decrypted bytes.
    private let memoryPool: CMMemoryPool
    private var cryptor: CCCryptorRef
    /// Where the next encrypted bytes to decrypt start.
    private var cipherPosition: Int
    /// The decrypted bytes kept, in order and without gaps, each with where it starts.
    private var pieces: [(offset: Int, buffer: CMBlockBuffer)] = []
    private var plainStart: Int
    private var plainEnd: Int
    private var isFinished = false

    /// - Parameters:
    ///   - start: Where the segment starts in the resource.
    ///   - end: Where the segment ends in the resource, or `nil` for the end of the resource.
    ///   - memoryPool: The memory of the decrypted bytes; readers of one stream after another can share it.
    init(upstream: DataReader, start: Int, end: Int?, key: Data, iv: Data, memoryPool: CMMemoryPool) throws {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else {
            SELogger.error(.decryption, "Invalid AES-128 key of \(key.count) bytes or IV of \(iv.count) bytes")
            throw DecryptionError.invalidKey
        }
        self.upstream = upstream
        self.start = start
        self.end = end
        self.key = key
        self.iv = iv
        self.memoryPool = memoryPool
        cipherPosition = start
        plainStart = start
        plainEnd = start
        cryptor = try Self.makeCryptor(key: key, iv: iv)
    }

    deinit {
        CCCryptorRelease(cryptor)
    }

    func read(range: Range<Int>, _ isolation: isolated any Actor) async throws -> CMBlockBuffer? {
        if range.lowerBound < plainStart {
            try await restart(at: range.lowerBound, isolation)
        }
        while !isFinished, plainEnd < range.upperBound {
            try await decryptMore(isolation)
        }

        let readable = range.clamped(to: plainStart ..< plainEnd)
        guard !readable.isEmpty else { return nil }

        let blockBuffer = try reference(readable)
        dropPieces(before: readable.lowerBound - Self.bytesKeptBehind)
        return blockBuffer
    }

    // MARK: - Decryption

    /// Starts decrypting again at the block of `position`, with the encrypted block before it as the IV.
    private func restart(at position: Int, _ isolation: isolated any Actor) async throws {
        let blockSize = kCCBlockSizeAES128
        let cipherStart = start + max(0, position - start) / blockSize * blockSize
        SELogger.debug(.decryption, "Decrypting again from \(cipherStart) for a read at \(position), behind \(plainStart)")

        var iv = self.iv
        if cipherStart > start {
            let previousBlock = (cipherStart - blockSize) ..< cipherStart
            let buffer = try await upstream.read(range: previousBlock, isolation)
            guard let buffer, buffer.dataLength == blockSize else {
                throw DecryptionError.cryptor(CCCryptorStatus(kCCDecodeError))
            }
            iv = try buffer.dataBytes()
        }

        let newCryptor = try Self.makeCryptor(key: key, iv: iv)
        CCCryptorRelease(cryptor)
        cryptor = newCryptor
        cipherPosition = cipherStart
        pieces.removeAll()
        plainStart = cipherStart
        plainEnd = cipherStart
        isFinished = false
    }

    private func decryptMore(_ isolation: isolated any Actor) async throws {
        let length = end.map { min(Self.readLength, $0 - cipherPosition) } ?? Self.readLength

        // Without more encrypted bytes the cryptor gives its last block, less the padding.
        var cipher: Data?
        if length > 0 {
            let buffer = try await upstream.read(range: cipherPosition ..< (cipherPosition + length), isolation)
            if let buffer, !buffer.isEmpty { cipher = try buffer.dataBytes() }
        }

        let capacity = (cipher?.count ?? 0) + kCCBlockSizeAES128
        let output = try CMBlockBuffer(length: capacity, allocator: memoryPool.allocator, flags: .assureMemoryNow)

        var moved = 0
        let status = try output.withUnsafeMutableBlockBytes { outputBytes -> CCCryptorStatus in
            guard let cipher else {
                return CCCryptorFinal(cryptor, outputBytes.baseAddress, capacity, &moved)
            }
            return cipher.withUnsafeBytes { cipherBytes in
                CCCryptorUpdate(
                    cryptor,
                    cipherBytes.baseAddress,
                    cipher.count,
                    outputBytes.baseAddress,
                    capacity,
                    &moved
                )
            }
        }
        guard status == kCCSuccess else {
            SELogger.error(.decryption, "Decrypting at \(cipherPosition) failed: \(status)")
            throw DecryptionError.cryptor(status)
        }

        if moved > 0 {
            try pieces.append((offset: plainEnd, buffer: CMBlockBuffer(bufferReference: output, range: 0 ..< moved)))
            plainEnd += moved
        }
        if let cipher {
            cipherPosition += cipher.count
        } else {
            isFinished = true
        }
    }

    // MARK: - Pieces

    /// The decrypted bytes of `range`, without copying them.
    private func reference(_ range: Range<Int>) throws -> CMBlockBuffer {
        let blockBuffer = try CMBlockBuffer()
        for piece in pieces {
            let pieceRange = piece.offset ..< (piece.offset + piece.buffer.dataLength)
            let overlap = range.clamped(to: pieceRange)
            guard !overlap.isEmpty else { continue }
            let local = (overlap.lowerBound - piece.offset) ..< (overlap.upperBound - piece.offset)
            try blockBuffer.append(bufferReference: piece.buffer, range: local)
        }
        return blockBuffer
    }

    private func dropPieces(before position: Int) {
        while let first = pieces.first, first.offset + first.buffer.dataLength <= position {
            pieces.removeFirst()
        }
        plainStart = pieces.first?.offset ?? plainEnd
    }
}

private extension Aes128DataReader {
    /// How many encrypted bytes are read and decrypted at a time.
    static let readLength = 128 * 1024 // 128 KB
    /// Decrypted bytes this far behind the latest read are kept, for reads that come back to them, as after peeks.
    static let bytesKeptBehind = 256 * 1024 // 256 KB

    static func makeCryptor(key: Data, iv: Data) throws -> CCCryptorRef {
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreate(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding),
                    keyBytes.baseAddress,
                    key.count,
                    ivBytes.baseAddress,
                    &cryptor
                )
            }
        }
        guard status == kCCSuccess, let cryptor else {
            throw DecryptionError.cryptor(status)
        }
        return cryptor
    }
}
