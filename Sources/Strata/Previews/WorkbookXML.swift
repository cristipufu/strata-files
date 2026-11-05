import CNativeReaders
import Foundation

nonisolated final class WorkbookXML: NSObject, XMLParserDelegate {
    struct Name: Hashable {
        let local: String
        let namespace: String
        init(_ local: String, namespace: String = "") { self.local = local; self.namespace = namespace }
    }
    struct Attributes {
        let values: [Name: String]
        subscript(_ local: String, namespace namespace: String = "") -> String? { values[Name(local, namespace: namespace)] }
    }
    enum Event { case start(Name, Attributes), text(String), end(Name) }
    static let byteLimit = 8 << 20
    private static let depthLimit = 64
    private static let nodeLimit = 250_000
    private static let attributeLimit = 32
    private static let attributeNameByteLimit = 256
    private static let attributeValueByteLimit = 4096
    private let receive: (Event) throws -> Bool
    private var depth = 0
    private var nodes = 0
    private var textBytes = 0
    private var finished = false
    private var failure: Error?
    private var namespaces: [String: [String]] = ["xml": ["http://www.w3.org/XML/1998/namespace"]]
    private var mappings = 0

    private init(receive: @escaping (Event) throws -> Bool) { self.receive = receive }

    static var limitError: PreviewError { .message(String(localized: "This workbook exceeds the preview limits.")) }

    static func read(_ data: Data, receive: @escaping (Event) throws -> Bool) throws {
        try Task.checkCancellation()
        try validate(data)
        let delegate = WorkbookXML(receive: receive), parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        let result = Result { try STXMLReader.parse(parser) }
        if let failure = delegate.failure { throw failure }
        try Task.checkCancellation()
        if case .failure(let error) = result {
            let native = error as NSError
            guard delegate.finished, native.domain == XMLParser.errorDomain,
                  native.code == XMLParser.ErrorCode.delegateAbortedParseError.rawValue else { throw error }
        } else if delegate.depth != 0 { throw PreviewError.unsupported }
    }

    static func validate(_ data: Data, limit: Int = byteLimit) throws {
        guard data.count <= limit else { throw limitError }
        guard let text = String(data: data, encoding: .utf8),
              text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw PreviewError.unsupported }
    }

    private func deliver(_ event: Event, parser: XMLParser) {
        guard failure == nil, !finished else { return }
        do {
            try Task.checkCancellation()
            if try !receive(event) { finished = true; parser.abortParsing() }
        } catch { failure = error; parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard depth < Self.depthLimit, nodes < Self.nodeLimit, name.utf8.count <= Self.attributeNameByteLimit, attributes.count <= Self.attributeLimit,
              attributes.allSatisfy({ $0.key.utf8.count <= Self.attributeNameByteLimit && $0.value.utf8.count <= Self.attributeValueByteLimit }) else {
            failure = Self.limitError; parser.abortParsing(); return
        }
        depth += 1; nodes += 1
        var qualified: [Name: String] = [:]
        for (key, value) in attributes {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            let attribute: Name
            if parts.count == 2 {
                guard let namespace = namespaces[parts[0]]?.last else { failure = PreviewError.unsupported; parser.abortParsing(); return }
                attribute = Name(parts[1], namespace: namespace)
            } else { attribute = Name(key) }
            guard qualified.updateValue(value, forKey: attribute) == nil else { failure = PreviewError.unsupported; parser.abortParsing(); return }
        }
        deliver(.start(Name(name, namespace: namespaceURI ?? ""), Attributes(values: qualified)), parser: parser)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard string.utf8.count <= Self.byteLimit - textBytes else { failure = Self.limitError; parser.abortParsing(); return }
        textBytes += string.utf8.count
        deliver(.text(string), parser: parser)
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard let string = String(data: data, encoding: .utf8) else { failure = PreviewError.unsupported; parser.abortParsing(); return }
        self.parser(parser, foundCharacters: string)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard depth > 0 else { failure = PreviewError.unsupported; parser.abortParsing(); return }
        depth -= 1
        deliver(.end(Name(name, namespace: namespaceURI ?? "")), parser: parser)
    }

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        guard mappings < Self.nodeLimit, prefix.utf8.count <= Self.attributeNameByteLimit,
              namespaceURI.utf8.count <= Self.attributeValueByteLimit else { failure = Self.limitError; parser.abortParsing(); return }
        mappings += 1
        namespaces[prefix, default: []].append(namespaceURI)
    }

    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        namespaces[prefix]?.removeLast()
        if namespaces[prefix]?.isEmpty == true { namespaces[prefix] = nil }
    }
}
