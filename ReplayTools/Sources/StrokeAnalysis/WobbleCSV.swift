import Foundation

public enum WobbleCSVError: Error {
    case empty
}

/// Minimal header-name-based CSV reader for Wobble recordings. Columns are looked
/// up by name (not position) so it tolerates added/reordered columns and works
/// across old and new file formats.
public struct WobbleCSV {
    public let header: [String]
    public let rows: [[String]]
    private let index: [String: Int]

    public init(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        try self.init(text: text)
    }

    public init(text: String) throws {
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { throw WobbleCSVError.empty }
        let head = lines.removeFirst()
        header = head.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        rows = lines.map { line in
            line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        }
        var idx: [String: Int] = [:]
        for (i, name) in header.enumerated() { idx[name] = i }
        index = idx
    }

    public func hasColumn(_ name: String) -> Bool { index[name] != nil }

    public func double(_ row: [String], _ name: String) -> Double? {
        guard let i = index[name], i < row.count else { return nil }
        return Double(row[i])
    }

    public func string(_ row: [String], _ name: String) -> String? {
        guard let i = index[name], i < row.count else { return nil }
        return row[i]
    }
}
