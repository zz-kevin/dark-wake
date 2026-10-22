import Foundation

/// Minimum-cost assignment (Hungarian algorithm, O(n^2 m) with potentials).
/// Returns, for each row, the assigned column or nil. Rectangular input is
/// fine. As in Dark Track's associate.py, a whole radar sweep is assigned at
/// once so a greedy nearest match can't steal the only plausible contact
/// from a neighbouring track.
func hungarian(_ cost: [[Double]]) -> [Int?] {
    let n = cost.count
    guard n > 0, let m = cost.first?.count, m > 0 else { return Array(repeating: nil, count: n) }
    if n > m {
        let t = (0..<m).map { j in (0..<n).map { i in cost[i][j] } }
        var result = [Int?](repeating: nil, count: n)
        for (j, i) in hungarian(t).enumerated() { if let i { result[i] = j } }
        return result
    }
    var u = [Double](repeating: 0, count: n + 1)
    var v = [Double](repeating: 0, count: m + 1)
    var p = [Int](repeating: 0, count: m + 1)
    var way = [Int](repeating: 0, count: m + 1)
    for i in 1...n {
        p[0] = i
        var j0 = 0
        var minv = [Double](repeating: .infinity, count: m + 1)
        var used = [Bool](repeating: false, count: m + 1)
        repeat {
            used[j0] = true
            let i0 = p[j0]
            var delta = Double.infinity
            var j1 = 0
            for j in 1...m where !used[j] {
                let cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
                if cur < minv[j] { minv[j] = cur; way[j] = j0 }
                if minv[j] < delta { delta = minv[j]; j1 = j }
            }
            for j in 0...m {
                if used[j] { u[p[j]] += delta; v[j] -= delta } else { minv[j] -= delta }
            }
            j0 = j1
        } while p[j0] != 0
        repeat {
            let j1 = way[j0]
            p[j0] = p[j1]
            j0 = j1
        } while j0 != 0
    }
    var result = [Int?](repeating: nil, count: n)
    for j in 1...m where p[j] != 0 { result[p[j] - 1] = j - 1 }
    return result
}
