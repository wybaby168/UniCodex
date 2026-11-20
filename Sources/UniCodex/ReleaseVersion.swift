import Foundation

struct ReleaseVersion: Comparable, CustomStringConvertible {
    let description: String

    init?(_ value: String) {
        guard
            value.range(
                of: #"\A(?:0|[1-9][0-9]{0,5})\.(?:0|[1-9][0-9]{0,5})\.(?:0|[1-9][0-9]{0,5})(?:-[a-zA-Z0-9.]+)?\z"#,
                options: .regularExpression) != nil
        else { return nil }
        description = value
    }

    var isStable: Bool { !description.contains("-") }

    static func < (left: Self, right: Self) -> Bool {
        let lhs = left.description.split(separator: "-", maxSplits: 1)
        let rhs = right.description.split(separator: "-", maxSplits: 1)
        let leftCore = lhs[0].split(separator: ".").compactMap { Int($0) }
        let rightCore = rhs[0].split(separator: ".").compactMap { Int($0) }
        if leftCore != rightCore { return leftCore.lexicographicallyPrecedes(rightCore) }
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        guard lhs.count > 1 else { return false }
        return lhs[1].compare(rhs[1], options: .numeric) == .orderedAscending
    }
}
