import AVFoundation
import Foundation

final class PinnedMediaResource: NSObject, AVAssetResourceLoaderDelegate {
    private let length: Int64
    private let type: String
    init(length: Int64, type: String) { self.length = length; self.type = type }

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        request.contentInformationRequest?.contentType = type
        request.contentInformationRequest?.contentLength = length
        request.contentInformationRequest?.isByteRangeAccessSupported = true
        guard let data = request.dataRequest else { request.finishLoading(); return true }
        guard data.requestedOffset >= 0, data.currentOffset >= 0, data.requestedLength >= 0 else {
            request.finishLoading(with: POSIXError(.EINVAL)); return true
        }
        var offset = max(data.requestedOffset, data.currentOffset)
        guard offset <= length else { request.finishLoading(with: POSIXError(.EINVAL)); return true }
        let remaining = Int64(data.requestedLength) - (offset - data.requestedOffset)
        let end = data.requestsAllDataToEndOfResource ? length : offset + min(max(0, remaining), length - offset)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while offset < end, !request.isCancelled {
            let count = pread(3, &buffer, min(buffer.count, Int(end - offset)), offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { request.finishLoading(with: POSIXError(.EIO)); return true }
            autoreleasepool { data.respond(with: Data(buffer.prefix(count))) }
            offset += Int64(count)
        }
        if !request.isCancelled { request.finishLoading() }
        return true
    }
}
