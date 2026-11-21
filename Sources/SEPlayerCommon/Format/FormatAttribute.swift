//
//  FormatAttribute.swift
//  SEPlayer
//

/// A typed attribute, declared as a property of the scope it belongs to. `nil` when it is not set.
public struct FormatAttribute<Value: Hashable & Sendable>: Sendable {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }
}

/// An attribute that reads as a default when it is not set.
public struct DefaultedFormatAttribute<Value: Hashable & Sendable>: Sendable {
    public let name: String
    public let defaultValue: Value

    public init(_ name: String, default defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

/// A group of attributes, declared as its stored properties.
public protocol FormatAttributeScope {
    init()
}

/// A value that combines with another of its type when formats merge, rather than being replaced.
protocol AttributeMergeable: Hashable, Sendable {
    func merging(_ other: Self) -> Self
}

extension AttributeMergeable {
    fileprivate func merging(any other: Any) -> (any Hashable & Sendable)? {
        (other as? Self).map { merging($0) }
    }
}

/// The values of attributes, by their scope and name.
struct AttributeStorage: Hashable, Sendable {
    struct ID: Hashable, Sendable {
        let scope: ObjectIdentifier
        let name: String
    }

    struct Value: Hashable, Sendable {
        let base: any Hashable & Sendable

        static func == (lhs: Value, rhs: Value) -> Bool {
            AnyHashable(lhs.base) == AnyHashable(rhs.base)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(AnyHashable(base))
        }
    }

    var isEmpty: Bool { values.isEmpty }

    var description: String {
        values.map { "\($0.key.name): \($0.value.base)" }.sorted().joined(separator: ", ")
    }

    private(set) var values: [ID: Value] = [:]

    func value<S: FormatAttributeScope, V>(_ keyPath: KeyPath<S, FormatAttribute<V>>) -> V? {
        values[Self.id(keyPath)]?.base as? V
    }

    func value<S: FormatAttributeScope, V>(_ keyPath: KeyPath<S, DefaultedFormatAttribute<V>>) -> V {
        let attribute = S()[keyPath: keyPath]
        let id = ID(scope: ObjectIdentifier(S.self), name: attribute.name)
        return values[id]?.base as? V ?? attribute.defaultValue
    }

    mutating func setValue<S: FormatAttributeScope, V>(_ value: V?, _ keyPath: KeyPath<S, FormatAttribute<V>>) {
        values[Self.id(keyPath)] = value.map { Value(base: $0) }
    }

    /// Setting the default removes the attribute, so that formats compare by what they say.
    mutating func setValue<S: FormatAttributeScope, V>(_ value: V, _ keyPath: KeyPath<S, DefaultedFormatAttribute<V>>) {
        let attribute = S()[keyPath: keyPath]
        let id = ID(scope: ObjectIdentifier(S.self), name: attribute.name)
        values[id] = value == attribute.defaultValue ? nil : Value(base: value)
    }

    /// Takes the attributes of `other`, which win over the ones already set.
    mutating func merge(_ other: AttributeStorage) {
        values.merge(other.values) { old, new in
            guard let old = old.base as? any AttributeMergeable, let merged = old.merging(any: new.base) else {
                return new
            }
            return Value(base: merged)
        }
    }

    /// The attributes of one scope.
    func filtered<S: FormatAttributeScope>(to scope: S.Type) -> AttributeStorage {
        var result = AttributeStorage()
        result.values = values.filter { $0.key.scope == ObjectIdentifier(scope) }
        return result
    }

    /// Replaces the attributes of one scope with those `other` has for it.
    mutating func replace<S: FormatAttributeScope>(_ scope: S.Type, with other: AttributeStorage) {
        values = values.filter { $0.key.scope != ObjectIdentifier(scope) }
        values.merge(other.filtered(to: scope).values) { _, new in new }
    }

    private static func id<S: FormatAttributeScope, V>(_ keyPath: KeyPath<S, FormatAttribute<V>>) -> ID {
        ID(scope: ObjectIdentifier(S.self), name: S()[keyPath: keyPath].name)
    }
}
