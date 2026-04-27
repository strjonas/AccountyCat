//
//  ContextualBanditEngine.swift
//  AC
//

import Accelerate
import Foundation

// MARK: - BanditArm

/// The set of actions the bandit can take.
///
/// Each arm has its own independent LinUCB weights. `.none` is the "do nothing" baseline
/// with expected reward 0 — the bandit picks an intervention arm only when some arm's UCB
/// is greater than 0.
enum BanditArm: String, Codable, CaseIterable, Sendable, Equatable {
    /// Do nothing. Expected reward = 0.
    case none
    /// A warm, light awareness-check nudge. First-touch or low-friction.
    case supportiveNudge = "supportive_nudge"
    /// A firm, specific nudge. Used when gentle hints have been ignored.
    case challengingNudge = "challenging_nudge"
    /// Full-screen overlay — stronger interruption reserved for clear, repeated distraction.
    case overlay

    /// Arms the engine actively learns about (`.none` is the implicit baseline).
    static let learnable: [BanditArm] = [.supportiveNudge, .challengingNudge, .overlay]
}

// MARK: - ContextualBanditEngine

/// Multi-arm LinUCB contextual bandit.
///
/// Each learnable arm holds its own `A` (precision matrix) and `b` (reward vector).  At
/// decision time the engine computes a UCB per arm and picks the highest — but only if
/// that UCB exceeds `.none`'s baseline of 0.
///
/// **Per-arm algorithm (LinUCB):**
/// ```
/// UCB_a(x) = θ_aᵀx + α √(xᵀA_a⁻¹x)   where θ_a = A_a⁻¹ b_a
/// Update:   A_a ← A_a + xxᵀ
///           b_a ← b_a + r·x
/// ```
///
/// All matrix operations use Accelerate (BLAS/LAPACK); each `selectArm` is a handful of
/// microseconds at d=16.
///
/// **Tuning α:** Start at 0.4 (exploration-heavy); lower toward 0.15–0.2 after ≥200 updates.
struct ContextualBanditEngine: Codable, Sendable, Equatable {

    // MARK: - Constants

    static let d = BanditFeatureVector.dimension    // 16
    static let lambda: Double = 1.0                 // ridge regularisation

    // MARK: - Per-arm state

    struct ArmState: Codable, Sendable, Equatable {
        /// Precision matrix A (d×d, row-major). Initialised to λI.
        var A: [Double]
        /// Reward accumulator b (d-vector). Initialised to zeros.
        var b: [Double]

        static func initial() -> ArmState {
            let d = ContextualBanditEngine.d
            var a = [Double](repeating: 0, count: d * d)
            for i in 0..<d { a[i * d + i] = ContextualBanditEngine.lambda }
            return ArmState(A: a, b: [Double](repeating: 0, count: d))
        }
    }

    // MARK: - State

    /// Exploration coefficient — applied uniformly across arms.
    var alpha: Double = 0.4
    /// Per-arm weights, keyed by `BanditArm.rawValue`.
    var arms: [String: ArmState]

    // MARK: - Init

    init() {
        var arms: [String: ArmState] = [:]
        for arm in BanditArm.learnable {
            arms[arm.rawValue] = ArmState.initial()
        }
        self.arms = arms
    }

    // MARK: - Codable (with migration from single-arm format)

    enum CodingKeys: String, CodingKey {
        case alpha
        case arms
        // Legacy single-arm format — migrated into `.supportiveNudge`
        case A
        case b
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alpha = try c.decodeIfPresent(Double.self, forKey: .alpha) ?? 0.4
        if let decoded = try c.decodeIfPresent([String: ArmState].self, forKey: .arms) {
            var hydrated = decoded
            for arm in BanditArm.learnable where hydrated[arm.rawValue] == nil {
                hydrated[arm.rawValue] = ArmState.initial()
            }
            arms = hydrated
        } else if
            let legacyA = try c.decodeIfPresent([Double].self, forKey: .A),
            let legacyB = try c.decodeIfPresent([Double].self, forKey: .b),
            legacyA.count == Self.d * Self.d, legacyB.count == Self.d
        {
            // Migrate the old single-arm engine into the supportive-nudge slot.
            var hydrated: [String: ArmState] = [:]
            for arm in BanditArm.learnable {
                hydrated[arm.rawValue] = ArmState.initial()
            }
            hydrated[BanditArm.supportiveNudge.rawValue] = ArmState(A: legacyA, b: legacyB)
            arms = hydrated
        } else {
            var hydrated: [String: ArmState] = [:]
            for arm in BanditArm.learnable {
                hydrated[arm.rawValue] = ArmState.initial()
            }
            arms = hydrated
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(alpha, forKey: .alpha)
        try c.encode(arms, forKey: .arms)
    }

    // MARK: - Decision

    struct ArmScore: Sendable, Equatable {
        var arm: BanditArm
        var ucb: Double
    }

    /// Returns the arm with the highest UCB or `.none` if every learnable arm's UCB ≤ 0.
    /// Also returns every arm's score (for telemetry).
    func selectArm(context x: BanditFeatureVector) -> (arm: BanditArm, ucb: Double, scores: [ArmScore]) {
        guard x.values.count == Self.d else {
            return (.none, 0, [])
        }

        var scores: [ArmScore] = []
        scores.reserveCapacity(BanditArm.learnable.count)
        for arm in BanditArm.learnable {
            let state = arms[arm.rawValue] ?? ArmState.initial()
            let theta = solveTheta(state: state)
            let meanReward = dot(theta, x.values)
            let aInv = solveAInv(state: state)
            let variance = quadraticForm(aInv: aInv, x: x.values)
            let ucb = meanReward + alpha * sqrt(max(0, variance))
            scores.append(ArmScore(arm: arm, ucb: ucb))
        }

        let best = scores.max(by: { $0.ucb < $1.ucb })
        if let best, best.ucb > 0 {
            return (best.arm, best.ucb, scores)
        }
        return (.none, best?.ucb ?? 0, scores)
    }

    // MARK: - Update

    /// Incorporates an observed reward `r` for context `x` into `arm`'s weights.
    /// Updates on `.none` are silently ignored — there's nothing to learn about the baseline.
    mutating func update(arm: BanditArm, context x: BanditFeatureVector, reward r: Double) {
        guard arm != .none else { return }
        guard x.values.count == Self.d else { return }
        var state = arms[arm.rawValue] ?? ArmState.initial()
        rankOneUpdate(state: &state, vector: x.values)
        for i in 0..<Self.d { state.b[i] += r * x.values[i] }
        arms[arm.rawValue] = state
    }

    // MARK: - Private linear algebra (Accelerate)

    /// Solves A θ = b for θ using Cholesky factorisation (A is SPD).
    private func solveTheta(state: ArmState) -> [Double] {
        var aCopy = state.A
        var bCopy = state.b
        var n = Int32(Self.d); var lda = Int32(Self.d); var ldb = Int32(Self.d)
        var nrhs: Int32 = 1
        var uplo = Int8(UnicodeScalar("U").value)
        var info: Int32 = 0
        dposv_(&uplo, &n, &nrhs, &aCopy, &lda, &bCopy, &ldb, &info)
        if info != 0 {
            return [Double](repeating: 0, count: Self.d)
        }
        return bCopy
    }

    /// Computes A⁻¹ via Cholesky factorisation + inversion.
    private func solveAInv(state: ArmState) -> [Double] {
        var aCopy = state.A
        var n = Int32(Self.d); var lda = Int32(Self.d)
        var uplo = Int8(UnicodeScalar("U").value)
        var info: Int32 = 0
        dpotrf_(&uplo, &n, &aCopy, &lda, &info)
        guard info == 0 else { return state.A }
        var n2 = Int32(Self.d); var lda2 = Int32(Self.d); var info2: Int32 = 0
        dpotri_(&uplo, &n2, &aCopy, &lda2, &info2)
        guard info2 == 0 else { return state.A }
        mirrorUpperToLower(&aCopy)
        return aCopy
    }

    private func quadraticForm(aInv: [Double], x: [Double]) -> Double {
        let d = Self.d
        var y = [Double](repeating: 0, count: d)
        cblas_dsymv(
            CblasRowMajor, CblasUpper,
            Int32(d), 1.0, aInv, Int32(d),
            x, 1, 0.0, &y, 1
        )
        return cblas_ddot(Int32(d), x, 1, y, 1)
    }

    private func dot(_ a: [Double], _ b: [Double]) -> Double {
        cblas_ddot(Int32(Self.d), a, 1, b, 1)
    }

    private func rankOneUpdate(state: inout ArmState, vector x: [Double]) {
        cblas_dsyr(
            CblasRowMajor, CblasUpper,
            Int32(Self.d), 1.0, x, 1,
            &state.A, Int32(Self.d)
        )
        mirrorUpperToLower(&state.A)
    }

    private func mirrorUpperToLower(_ m: inout [Double]) {
        let d = Self.d
        for i in 0..<d {
            for j in 0..<i {
                m[i * d + j] = m[j * d + i]
            }
        }
    }
}
