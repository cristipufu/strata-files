import Foundation
import FoundationModels

// Guided generation without the @Generable macro.
//
// The FoundationModels macros (`@Generable`, `@Guide`) need the `FoundationModelsMacros` compiler plugin, which ships with Xcode but
// not with the Command Line Tools this package builds with. `DynamicGenerationSchema` gives the same constrained decoding at
// runtime: the model can only produce output that fits the schema (enums, arrays with counts, optional fields), and the result
// comes back as `GeneratedContent`, read here by key.

/// Small builders for `DynamicGenerationSchema`.
package nonisolated enum Schema {
    package struct Field {
        package let name: String
        package let description: String?
        package let schema: DynamicGenerationSchema
        package let optional: Bool
    }

    package static func string() -> DynamicGenerationSchema { DynamicGenerationSchema(type: String.self) }

    package static func integer(_ range: ClosedRange<Int>? = nil) -> DynamicGenerationSchema {
        DynamicGenerationSchema(type: Int.self, guides: range.map { [.range($0)] } ?? [])
    }

    package static func choice(_ name: String, _ values: [String]) -> DynamicGenerationSchema {
        DynamicGenerationSchema(name: name, anyOf: values)
    }

    package static func array(_ item: DynamicGenerationSchema, min: Int? = nil, max: Int? = nil) -> DynamicGenerationSchema {
        DynamicGenerationSchema(arrayOf: item, minimumElements: min, maximumElements: max)
    }

    package static func field(_ name: String, _ description: String? = nil, _ schema: DynamicGenerationSchema, optional: Bool = false) -> Field {
        Field(name: name, description: description, schema: schema, optional: optional)
    }

    package static func object(_ name: String, _ description: String? = nil, _ fields: [Field]) -> DynamicGenerationSchema {
        DynamicGenerationSchema(name: name, description: description, properties: fields.map {
            DynamicGenerationSchema.Property(name: $0.name, description: $0.description, schema: $0.schema, isOptional: $0.optional)
        })
    }

    package static func root(_ schema: DynamicGenerationSchema, _ dependencies: [DynamicGenerationSchema] = []) throws -> GenerationSchema {
        try GenerationSchema(root: schema, dependencies: dependencies)
    }
}

/// Reading `GeneratedContent` by key. Works on partial content while streaming (missing keys read as nil).
nonisolated extension GeneratedContent {
    package subscript(key: String) -> GeneratedContent? {
        if case let .structure(properties, _) = kind { return properties[key] }
        return nil
    }

    package var string: String? {
        if case let .string(value) = kind { return value }
        return nil
    }

    /// A non-empty, trimmed string (the model sometimes fills optional strings with "" or "none").
    package var meaningfulString: String? {
        guard let value = string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              !["none", "null", "n/a", "nil", "-"].contains(value.lowercased()) else { return nil }
        return value
    }

    package var number: Double? {
        if case let .number(value) = kind { return value }
        if case let .string(value) = kind { return Double(value) }
        return nil
    }

    package var integer: Int? {
        guard let rounded = number?.rounded(), rounded.isFinite,
              rounded > Double(Int.min), rounded < Double(Int.max) else { return nil }
        return Int(rounded)
    }

    package var array: [GeneratedContent] {
        if case let .array(values) = kind { return values }
        return []
    }

    package var strings: [String] { array.compactMap(\.meaningfulString) }
}

/// Runs model work with a deadline, so a slow or stuck model never blocks a fallback.
package nonisolated enum Deadline {
    package struct Expired: Error {}

    package static func run<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw Expired()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Expired() }
            return first
        }
    }
}
