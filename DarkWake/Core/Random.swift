import Foundation

/// Seedable generator so simulation runs (and tests) are reproducible.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func uniform(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * uniform() }

    mutating func gaussian(_ std: Double = 1) -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return std * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    mutating func poisson(_ lambda: Double) -> Int {
        let l = exp(-lambda)
        var k = 0, p = 1.0
        repeat { k += 1; p *= uniform() } while p > l
        return k - 1
    }

    mutating func chance(_ p: Double) -> Bool { uniform() < p }
}
