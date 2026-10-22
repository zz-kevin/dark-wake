import Foundation

/// Constant-velocity Kalman filter, state [x, y, vx, vy] in local metres.
/// A port of Dark Track's fusion/kalman.py: per-measurement noise (R) is
/// what lets one filter trust an AIS fix far more than a radar plot.
struct KalmanFilter {
    private(set) var x: Mat
    private(set) var P: Mat
    let accelStd: Double
    private(set) var lastInnovationStdM: Double

    init(x0: Double, y0: Double, v0: (Double, Double)? = nil,
         accelStd: Double, initPosVar: Double, initVelVar: Double = 100) {
        x = .column([x0, y0, v0?.0 ?? 0, v0?.1 ?? 0])
        P = .diag([initPosVar, initPosVar, initVelVar, initVelVar])
        self.accelStd = accelStd
        lastInnovationStdM = (2 * initPosVar).squareRoot()
    }

    static func transition(_ dt: Double) -> Mat {
        Mat(4, 4, [1, 0, dt, 0,
                   0, 1, 0, dt,
                   0, 0, 1, 0,
                   0, 0, 0, 1])
    }

    /// Discretized white-noise-acceleration model. Ships change velocity
    /// far more slowly than aircraft, so accelStd is small.
    func processNoise(_ dt: Double) -> Mat {
        let q = accelStd * accelStd
        let dt2 = dt * dt, dt3 = dt2 * dt, dt4 = dt3 * dt
        return Mat(4, 4, [dt4 / 4, 0, dt3 / 2, 0,
                          0, dt4 / 4, 0, dt3 / 2,
                          dt3 / 2, 0, dt2, 0,
                          0, dt3 / 2, 0, dt2]).scaled(q)
    }

    /// Predicted (x, P) dt seconds ahead without changing state -- used for
    /// gating before an association is decided.
    func peekPredict(_ dt: Double) -> (x: Mat, P: Mat) {
        let dt = max(dt, 0)
        let F = Self.transition(dt)
        return (F * x, F * P * F.T + processNoise(dt))
    }

    mutating func predict(_ dt: Double) {
        (x, P) = peekPredict(dt)
    }

    /// z is a position (metres). v, if given, is a measured velocity --
    /// AIS reports SOG/COG alongside position, radar doesn't.
    /// Returns the position innovation's length and the filter's own
    /// innovation std dev at this update (sqrt of trace of S's position
    /// block), which the kinematic detector normalizes by.
    @discardableResult
    mutating func update(z: (Double, Double), rStd: Double,
                         v: (Double, Double)? = nil, rvStd: Double = 0.5) -> (residualM: Double, innovationStdM: Double) {
        let H: Mat, R: Mat, zv: Mat
        if let v {
            H = .identity(4)
            R = .diag([rStd * rStd, rStd * rStd, rvStd * rvStd, rvStd * rvStd])
            zv = .column([z.0, z.1, v.0, v.1])
        } else {
            H = Mat(2, 4, [1, 0, 0, 0, 0, 1, 0, 0])
            R = .diag([rStd * rStd, rStd * rStd])
            zv = .column([z.0, z.1])
        }
        let y = zv - H * x
        let S = H * P * H.T + R
        guard let Sinv = S.inverse() else { return (0, lastInnovationStdM) }
        let K = P * H.T * Sinv
        x = x + K * y
        P = (Mat.identity(4) - K * H) * P
        lastInnovationStdM = (S[0, 0] + S[1, 1]).squareRoot()
        return (hypot(y.a[0], y.a[1]), lastInnovationStdM)
    }

    var position: (Double, Double) { (x.a[0], x.a[1]) }
    var velocity: (Double, Double) { (x.a[2], x.a[3]) }
    var speedKnots: Double { hypot(x.a[2], x.a[3]) / Units.mpsPerKnot }
    var positionVariance: Double { P[0, 0] + P[1, 1] }

    /// Re-anchor on a fix that can't be reconciled with the current state
    /// (an AIS position jump): identity comes from AIS, so follow it.
    mutating func reset(x0: Double, y0: Double, v0: (Double, Double)?, initPosVar: Double) {
        self = KalmanFilter(x0: x0, y0: y0, v0: v0, accelStd: accelStd, initPosVar: initPosVar)
    }
}

extension Mat {
    func scaled(_ s: Double) -> Mat { Mat(rows, cols, a.map { $0 * s }) }
}
