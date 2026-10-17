import CoreGraphics
import Foundation

/// Pure geometry, no AppKit. Rects use AX/CG global coordinates:
/// origin at the top-left of the primary screen, y grows downward.
enum Layout {
    struct Cell: Equatable, Codable { var row: Int; var col: Int }

    enum Action: String {
        case leftHalf, rightHalf, topHalf, bottomHalf
        case firstThird, centerThird, lastThird
        case topLeft, topRight, bottomLeft, bottomRight
        case maximize, center, restore, nextDisplay, previousDisplay, grid
    }

    /// Repeated presses of the same half cycle 1/2 -> 2/3 -> 1/3 (Rectangle default).
    static let cycle: [CGFloat] = [1.0 / 2, 2.0 / 3, 1.0 / 3]

    static func rect(for action: Action, in s: CGRect, repeatCount: Int) -> CGRect? {
        let f = cycle[repeatCount % cycle.count]
        let w = s.width / 2, h = s.height / 2
        switch action {
        case .leftHalf:    return CGRect(x: s.minX, y: s.minY, width: s.width * f, height: s.height)
        case .rightHalf:   return CGRect(x: s.maxX - s.width * f, y: s.minY, width: s.width * f, height: s.height)
        case .topHalf:     return CGRect(x: s.minX, y: s.minY, width: s.width, height: s.height * f)
        case .bottomHalf:  return CGRect(x: s.minX, y: s.maxY - s.height * f, width: s.width, height: s.height * f)
        case .firstThird:  return CGRect(x: s.minX, y: s.minY, width: s.width / 3, height: s.height)
        case .centerThird: return CGRect(x: s.minX + s.width / 3, y: s.minY, width: s.width / 3, height: s.height)
        case .lastThird:   return CGRect(x: s.minX + s.width * 2 / 3, y: s.minY, width: s.width / 3, height: s.height)
        case .topLeft:     return CGRect(x: s.minX, y: s.minY, width: w, height: h)
        case .topRight:    return CGRect(x: s.minX + w, y: s.minY, width: w, height: h)
        case .bottomLeft:  return CGRect(x: s.minX, y: s.minY + h, width: w, height: h)
        case .bottomRight: return CGRect(x: s.minX + w, y: s.minY + h, width: w, height: h)
        case .maximize:    return s
        case .center, .restore, .nextDisplay, .previousDisplay, .grid: return nil
        }
    }

    /// Divvy-style: the rect covered by the cells between two corners (drag in any direction).
    static func cellsRect(from a: Cell, to b: Cell, rows: Int, cols: Int, in s: CGRect) -> CGRect {
        let w = s.width / CGFloat(cols), h = s.height / CGFloat(rows)
        let c0 = min(a.col, b.col), c1 = max(a.col, b.col)
        let r0 = min(a.row, b.row), r1 = max(a.row, b.row)
        return CGRect(x: s.minX + CGFloat(c0) * w, y: s.minY + CGFloat(r0) * h,
                      width: CGFloat(c1 - c0 + 1) * w, height: CGFloat(r1 - r0 + 1) * h)
    }

    /// Full gap on screen edges, half gap on inner edges: neighbours end up exactly `gap` apart.
    static func applyGaps(_ r: CGRect, in s: CGRect, gap: CGFloat) -> CGRect {
        guard gap > 0 else { return r }
        func inset(_ onEdge: Bool) -> CGFloat { onEdge ? gap : gap / 2 }
        let left = inset(abs(r.minX - s.minX) < 1), right = inset(abs(r.maxX - s.maxX) < 1)
        let top = inset(abs(r.minY - s.minY) < 1), bottom = inset(abs(r.maxY - s.maxY) < 1)
        return CGRect(x: r.minX + left, y: r.minY + top,
                      width: r.width - left - right, height: r.height - top - bottom)
    }

    static func centered(_ size: CGSize, in s: CGRect) -> CGRect {
        let w = min(size.width, s.width), h = min(size.height, s.height)
        return CGRect(x: s.midX - w / 2, y: s.midY - h / 2, width: w, height: h)
    }

    /// Same relative placement on another screen.
    static func transfer(_ r: CGRect, from a: CGRect, to b: CGRect) -> CGRect {
        let sx = b.width / a.width, sy = b.height / a.height
        return CGRect(x: b.minX + (r.minX - a.minX) * sx, y: b.minY + (r.minY - a.minY) * sy,
                      width: r.width * sx, height: r.height * sy)
    }

    /// Pull a rect back inside the screen, keeping its size (an app may refuse the size we asked for).
    static func constrain(_ r: CGRect, to s: CGRect) -> CGRect {
        var o = r.origin
        o.x = max(s.minX, min(o.x, s.maxX - r.width))
        o.y = max(s.minY, min(o.y, s.maxY - r.height))
        return CGRect(origin: o, size: r.size)
    }

    /// AX (top-left origin) <-> AppKit (bottom-left origin). The same formula works both ways.
    static func flip(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func nearlyEqual(_ a: CGRect, _ b: CGRect, tolerance t: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= t && abs(a.minY - b.minY) <= t
            && abs(a.width - b.width) <= t && abs(a.height - b.height) <= t
    }

    /// `Maestro --selftest`
    static func selfTest() {
        func check(_ ok: Bool, _ msg: String) { if !ok { print("FAIL: \(msg)"); exit(1) } }
        func near(_ a: CGRect, _ b: CGRect) -> Bool { nearlyEqual(a, b, tolerance: 0.01) }
        let s = CGRect(x: 0, y: 25, width: 1200, height: 780)

        check(near(rect(for: .leftHalf, in: s, repeatCount: 0)!, CGRect(x: 0, y: 25, width: 600, height: 780)), "left 1/2")
        check(near(rect(for: .leftHalf, in: s, repeatCount: 1)!, CGRect(x: 0, y: 25, width: 800, height: 780)), "left 2/3")
        check(near(rect(for: .rightHalf, in: s, repeatCount: 2)!, CGRect(x: 800, y: 25, width: 400, height: 780)), "right 1/3")
        check(near(rect(for: .leftHalf, in: s, repeatCount: 3)!, rect(for: .leftHalf, in: s, repeatCount: 0)!), "cycle wraps")
        check(near(rect(for: .bottomRight, in: s, repeatCount: 0)!, CGRect(x: 600, y: 415, width: 600, height: 390)), "bottom right")
        check(near(rect(for: .centerThird, in: s, repeatCount: 0)!, CGRect(x: 400, y: 25, width: 400, height: 780)), "center third")

        let left = cellsRect(from: Cell(row: 5, col: 2), to: Cell(row: 0, col: 0), rows: 6, cols: 6, in: s)
        check(near(left, CGRect(x: 0, y: 25, width: 600, height: 780)), "grid left half, reversed drag")

        let g: CGFloat = 10
        let a = applyGaps(left, in: s, gap: g)
        let b = applyGaps(cellsRect(from: Cell(row: 0, col: 3), to: Cell(row: 5, col: 5), rows: 6, cols: 6, in: s), in: s, gap: g)
        check(abs(a.minX - g) < 0.01 && abs(a.minY - (s.minY + g)) < 0.01, "outer gap")
        check(abs(b.minX - a.maxX - g) < 0.01, "gap between neighbours")
        check(abs(s.maxX - b.maxX - g) < 0.01, "right outer gap")

        let r = CGRect(x: 10, y: 20, width: 300, height: 200)
        check(flip(flip(r, primaryHeight: 900), primaryHeight: 900) == r, "flip roundtrip")
        check(flip(r, primaryHeight: 900).minY == 680, "flip y")
        check(constrain(CGRect(x: 1100, y: 25, width: 300, height: 100), to: s).maxX == s.maxX, "constrain right")
        check(near(transfer(left, from: s, to: CGRect(x: 1200, y: 0, width: 600, height: 400)),
                   CGRect(x: 1200, y: 0, width: 300, height: 400)), "transfer to next display")
        print("selftest ok")
    }
}
