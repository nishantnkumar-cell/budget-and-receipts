import Foundation

/// Where an entry goes on its blank form: points from the page's top left.
public struct ReturnPlacement: Hashable, Sendable {
    /// The page of the blank form, from 1.
    public var page: Int
    public var left: Double
    public var top: Double
    public var right: Double
    public var bottom: Double
    /// How many character cells the box is divided into; 1 for a tick or a line of text.
    public var cells: Int

    init(_ page: Int, _ left: Double, _ top: Double, _ right: Double, _ bottom: Double, cells: Int = 1) {
        self.page = page
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
        self.cells = cells
    }
}

/// The entry boxes of the 2025-26 forms, measured from the blank forms published on GOV.UK.
public enum ReturnLayout {
    public static func placement(of id: String) -> ReturnPlacement? { all[id] }

    static let all: [String: ReturnPlacement] = {
        var places: [String: ReturnPlacement] = [
            // SA100, the main return.
            "SA100.TR2.1": .init(4, 89.5, 207.5, 103, 223.5),
            "SA100.TR2.1n": .init(4, 211, 207.5, 224, 223.5),
            "SA100.TR2.4": .init(4, 89.5, 539, 103, 555.5),
            "SA100.TR2.5": .init(4, 89.5, 690, 103, 706),
            "SA100.TR3.2": .init(5, 82, 193.5, 204, 209.5, cells: 8),
            "SA100.TR3.3": .init(5, 82, 250.5, 141.5, 266.5, cells: 4),
            "SA100.TR3.4": .init(5, 82, 308, 204, 324, cells: 8),
            "SA100.TR4.1": .init(6, 82, 202, 204, 218, cells: 8),
            "SA100.TR4.5": .init(6, 82, 390, 204, 406, cells: 8),
            "SA100.TR7.19": .init(9, 72, 300, 535, 316),
            // SA102, one employment.
            "SA102.1": .init(1, 82, 205.5, 204, 221.5, cells: 8),
            // Its first cell is a printed minus sign.
            "SA102.2": .init(1, 97.5, 292, 204, 308, cells: 7),
            "SA102.5": .init(1, 70, 406, 280, 422),
            // SA105, UK property.
            "SA105.1": .init(1, 250.5, 206.5, 280, 222.5, cells: 2),
            "SA105.3": .init(1, 518, 210.5, 531, 226.5),
            // SA106, foreign savings totals.
            "SA106.4": .init(3, 377, 220.5, 499.5, 236.5, cells: 8)
        ]
        func left(_ box: String, _ page: Int, _ top: Double) {
            places["SA105.\(box)"] = .init(page, 82, top, 204, top + 16, cells: 8)
        }
        func right(_ box: String, _ page: Int, _ top: Double, cells: Int = 8) {
            places["SA105.\(box)"] = .init(page, 340.5, top, cells == 8 ? 463 : 400.5, top + 16, cells: cells)
        }
        left("20", 1, 399.5)
        left("24", 1, 575.5)
        left("25", 1, 618)
        right("27", 1, 575.5)
        right("28", 1, 618)
        right("29", 1, 660.5)
        left("36", 2, 503)
        right("38", 2, 150)
        right("39", 2, 192.5)
        right("40", 2, 235)
        right("41", 2, 292.5)
        right("43", 2, 399)
        right("44", 2, 442)
        right("45", 2, 496.5)
        for (index, top) in [140.5, 160.0, 181.0].enumerated() {
            let row = index + 1
            places["SA106.A\(row)"] = .init(2, 51.5, top, 96, top + 16, cells: 3)
            places["SA106.B\(row)"] = .init(2, 224.5, top, 347, top + 16, cells: 8)
            places["SA106.C\(row)"] = .init(2, 427.5, top, 550, top + 16, cells: 8)
            places["SA106.E\(row)"] = .init(3, 270.5, top, 283.5, top + 16)
            places["SA106.F\(row)"] = .init(3, 377, top, 499.5, top + 16, cells: 8)
        }
        return places
    }()

    /// The characters to draw, one per cell, ending in the last cell for numbers. Nil when
    /// they don't fit.
    public static func characters(_ value: ReturnValue, cells: Int) -> [Character]? {
        let text: String
        var alignRight = true
        switch value {
        case .pounds(let amount), .count(let amount): text = "\(amount)"
        case .tick: text = "X"
        case .text(let words):
            text = words
            alignRight = false
        }
        guard text.count <= cells else { return nil }
        let padding = [Character](repeating: " ", count: cells - text.count)
        return alignRight ? padding + Array(text) : Array(text) + padding
    }
}
