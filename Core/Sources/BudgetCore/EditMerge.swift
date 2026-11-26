import Foundation

/// Saving an edit made to a copy taken earlier. Only what the edit changed is written, so a
/// change that arrived from another device while the screen was open stays (above all, that
/// something is now private).
public enum EditMerge {
    /// `draft` is the edited copy, `original` the copy as it was when editing began, and
    /// `current` what's saved now. Fields are taken one at a time. Fields named together in
    /// `groups` only make sense as a set, such as an amount and its split: if the edit
    /// touched any of them, all of them come from the draft. Lists of items with ids are
    /// merged item by item.
    public static func apply<T: Codable>(_ draft: T, editedFrom original: T, onto current: T, together groups: [[String]] = []) -> T {
        // Property lists keep dates and decimals exactly.
        guard let edited = fields(draft), let before = fields(original), var result = fields(current) else { return draft }
        let changed = Set(edited.keys).union(before.keys).filter { !same(edited[$0], before[$0]) }
        var whole = Set<String>()
        for group in groups where !changed.isDisjoint(with: group) { whole.formUnion(group) }
        for key in Set(changed).union(whole) {
            if !whole.contains(key), let merged = items(edited[key], before[key], result[key]) {
                result[key] = merged
            } else {
                result[key] = edited[key]
            }
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: result, format: .binary, options: 0),
              let value = try? PropertyListDecoder().decode(T.self, from: data) else { return draft }
        return value
    }

    private static func fields<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? PropertyListEncoder().encode(value),
              let list = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        return list as? [String: Any]
    }

    private static func same(_ one: Any?, _ other: Any?) -> Bool {
        switch (one, other) {
        case (nil, nil): true
        case let (one?, other?): NSDictionary(dictionary: ["value": one]).isEqual(to: ["value": other])
        default: false
        }
    }

    /// The three versions of a list merged item by item: what the edit added, removed or
    /// changed is applied to the saved list. Nil unless every item has an id.
    private static func items(_ edited: Any?, _ before: Any?, _ current: Any?) -> [Any]? {
        func list(_ value: Any?) -> [(id: String, item: [String: Any])]? {
            guard let value else { return [] }
            guard let array = value as? [Any] else { return nil }
            var result: [(String, [String: Any])] = []
            for element in array {
                guard let item = element as? [String: Any], let id = item["id"] as? String else { return nil }
                result.append((id, item))
            }
            return result
        }
        guard edited != nil, let edited = list(edited), let before = list(before), let current = list(current) else { return nil }
        let old = Dictionary(before.map { ($0.id, $0.item) }, uniquingKeysWith: { first, _ in first })
        let new = Dictionary(edited.map { ($0.id, $0.item) }, uniquingKeysWith: { first, _ in first })
        var result: [[String: Any]] = []
        var present = Set<String>()
        for (id, item) in current {
            if old[id] != nil && new[id] == nil { continue }
            present.insert(id)
            if let mine = new[id], !same(mine, old[id]) { result.append(mine) } else { result.append(item) }
        }
        // Added here. One removed elsewhere and untouched here stays removed.
        for (id, item) in edited where !present.contains(id) && old[id] == nil { result.append(item) }
        return result
    }
}
