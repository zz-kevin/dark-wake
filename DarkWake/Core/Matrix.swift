import Foundation

/// Small dense row-major matrix -- just enough for a 4-state Kalman filter.
struct Mat: Equatable {
    let rows: Int
    let cols: Int
    var a: [Double]

    init(_ rows: Int, _ cols: Int, _ values: [Double]? = nil) {
        self.rows = rows
        self.cols = cols
        a = values ?? Array(repeating: 0, count: rows * cols)
        precondition(a.count == rows * cols)
    }

    static func identity(_ n: Int) -> Mat {
        var m = Mat(n, n)
        for i in 0..<n { m[i, i] = 1 }
        return m
    }

    static func diag(_ d: [Double]) -> Mat {
        var m = Mat(d.count, d.count)
        for (i, v) in d.enumerated() { m[i, i] = v }
        return m
    }

    static func column(_ v: [Double]) -> Mat { Mat(v.count, 1, v) }

    subscript(r: Int, c: Int) -> Double {
        get { a[r * cols + c] }
        set { a[r * cols + c] = newValue }
    }

    var T: Mat {
        var m = Mat(cols, rows)
        for r in 0..<rows { for c in 0..<cols { m[c, r] = self[r, c] } }
        return m
    }

    static func * (l: Mat, r: Mat) -> Mat {
        precondition(l.cols == r.rows)
        var m = Mat(l.rows, r.cols)
        for i in 0..<l.rows {
            for k in 0..<l.cols {
                let lv = l[i, k]
                if lv == 0 { continue }
                for j in 0..<r.cols { m[i, j] += lv * r[k, j] }
            }
        }
        return m
    }

    static func + (l: Mat, r: Mat) -> Mat {
        Mat(l.rows, l.cols, zip(l.a, r.a).map(+))
    }

    static func - (l: Mat, r: Mat) -> Mat {
        Mat(l.rows, l.cols, zip(l.a, r.a).map(-))
    }

    /// Gauss-Jordan with partial pivoting. nil if singular.
    func inverse() -> Mat? {
        precondition(rows == cols)
        let n = rows
        var m = self
        var inv = Mat.identity(n)
        for c in 0..<n {
            var pivot = c
            for r in (c + 1)..<max(n, c + 1) where abs(m[r, c]) > abs(m[pivot, c]) { pivot = r }
            if abs(m[pivot, c]) < 1e-12 { return nil }
            if pivot != c {
                for j in 0..<n {
                    m.a.swapAt(c * n + j, pivot * n + j)
                    inv.a.swapAt(c * n + j, pivot * n + j)
                }
            }
            let p = m[c, c]
            for j in 0..<n { m[c, j] /= p; inv[c, j] /= p }
            for r in 0..<n where r != c {
                let f = m[r, c]
                if f == 0 { continue }
                for j in 0..<n {
                    m[r, j] -= f * m[c, j]
                    inv[r, j] -= f * inv[c, j]
                }
            }
        }
        return inv
    }
}
