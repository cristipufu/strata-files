import Foundation

package enum MediaAnalysisFailure: Error { case malformed, unsupported, limit }

package struct MediaAnalysisRequest: Sendable {
    package enum Operation: Sendable { case storyboard, frame(Double), waveform }
    package let operation: Operation
    package let typeIdentifier: String
    package init(operation: Operation = .storyboard, typeIdentifier: String = "com.apple.quicktime-movie") throws {
        if case .frame(let time) = operation {
            guard time.isFinite, time >= 0, time <= MediaFrames.durationLimit else { throw MediaAnalysisFailure.malformed }
        }
        guard !typeIdentifier.isEmpty, typeIdentifier.utf8.count <= 128,
              typeIdentifier.utf8.allSatisfy({ $0 == 45 || $0 == 46 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { throw MediaAnalysisFailure.malformed }
        self.operation = operation; self.typeIdentifier = typeIdentifier
    }
    package var encoded: Data {
        var bytes = MediaBytes()
        let mode: UInt32, time: Double
        switch operation {
        case .storyboard: mode = 1; time = 0
        case .frame(let value): mode = 2; time = value
        case .waveform: mode = 3; time = 0
        }
        bytes.append(mode); bytes.append(time.bitPattern)
        bytes.append(UInt32(typeIdentifier.utf8.count)); bytes.data.append(contentsOf: typeIdentifier.utf8)
        return bytes.data
    }
    package init(encoded: Data) throws {
        var bytes = MediaBytes(data: encoded)
        let mode = try bytes.word(), time = Double(bitPattern: try bytes.wide())
        let count = Int(try bytes.word())
        guard count <= 128, let type = String(data: try bytes.take(count), encoding: .utf8) else { throw MediaAnalysisFailure.malformed }
        guard bytes.isAtEnd, (1...3).contains(mode), mode == 2 || time == 0 else { throw MediaAnalysisFailure.malformed }
        let operation: Operation = mode == 1 ? .storyboard : mode == 2 ? .frame(time) : .waveform
        try self.init(operation: operation, typeIdentifier: type)
    }
}

package struct MediaFrame: Sendable {
    package let requested: Double
    package let actual: Double
    package let width: Int
    package let height: Int
    package let rgba: Data

    package init(requested: Double, actual: Double, width: Int, height: Int, rgba: Data) throws {
        guard requested.isFinite, actual.isFinite, requested >= 0, actual >= 0,
              width > 0, width <= MediaFrames.widthLimit, height > 0, height <= MediaFrames.heightLimit,
              rgba.count == width * height * 4 else { throw MediaAnalysisFailure.malformed }
        self.requested = requested; self.actual = actual
        self.width = width; self.height = height; self.rgba = rgba
    }
}

package struct MediaFrames: Sendable {
    package static let frameLimit = 8
    package static let widthLimit = 256
    package static let heightLimit = 144
    package static let durationLimit: Double = 1_000_000_000
    package static let outputLimit = frameLimit * (widthLimit * heightLimit * 4 + 32) + 32
    package let duration: Double
    package let frames: [MediaFrame]

    package init(duration: Double, frames: [MediaFrame]) throws {
        guard duration.isFinite, duration > 0, duration <= Self.durationLimit,
              !frames.isEmpty, frames.count <= Self.frameLimit,
              frames.allSatisfy({ $0.requested <= duration && $0.actual <= duration }) else { throw MediaAnalysisFailure.malformed }
        self.duration = duration; self.frames = frames
    }

    package var encoded: Data {
        var bytes = MediaBytes()
        bytes.append(UInt32(1)); bytes.append(duration.bitPattern); bytes.append(UInt32(frames.count))
        for frame in frames {
            bytes.append(frame.requested.bitPattern); bytes.append(frame.actual.bitPattern)
            bytes.append(UInt32(frame.width)); bytes.append(UInt32(frame.height)); bytes.data.append(frame.rgba)
        }
        return bytes.data
    }

    package init(encoded: Data) throws {
        guard encoded.count <= Self.outputLimit else { throw MediaAnalysisFailure.limit }
        var bytes = MediaBytes(data: encoded)
        guard try bytes.word() == 1 else { throw MediaAnalysisFailure.malformed }
        let duration = Double(bitPattern: try bytes.wide()), count = Int(try bytes.word())
        guard count > 0, count <= Self.frameLimit else { throw MediaAnalysisFailure.malformed }
        var frames: [MediaFrame] = []
        for _ in 0..<count {
            let requested = Double(bitPattern: try bytes.wide()), actual = Double(bitPattern: try bytes.wide())
            let width = Int(try bytes.word()), height = Int(try bytes.word())
            guard width > 0, width <= Self.widthLimit, height > 0, height <= Self.heightLimit else { throw MediaAnalysisFailure.malformed }
            frames.append(try MediaFrame(requested: requested, actual: actual, width: width, height: height,
                rgba: bytes.take(width * height * 4)))
        }
        guard bytes.isAtEnd else { throw MediaAnalysisFailure.malformed }
        try self.init(duration: duration, frames: frames)
    }
}

package struct MediaBytes {
    package var data: Data
    private var offset = 0
    package init(data: Data = Data()) { self.data = data }
    package var isAtEnd: Bool { offset == data.count }
    package mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else { throw MediaAnalysisFailure.malformed }
        defer { offset += count }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
    }
    package mutating func word() throws -> UInt32 { UInt32(try integer(count: 4)) }
    package mutating func wide() throws -> UInt64 { try integer(count: 8) }
    private mutating func integer(count: Int) throws -> UInt64 {
        try take(count).enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
    }
    package mutating func append(_ value: UInt32) { append(UInt64(value), count: 4) }
    package mutating func append(_ value: UInt64) { append(value, count: 8) }
    private mutating func append(_ value: UInt64, count: Int) {
        for offset in 0..<count { data.append(UInt8(truncatingIfNeeded: value >> (offset * 8))) }
    }
}
