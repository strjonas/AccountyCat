//
//  ContextualBanditEngine.swift
//  AC
//

import Accelerate
import Foundation

// MARK: - ContextualBanditEngine

/// Single-arm LinUCB contextual bandit.
///
/// The "arm" is "show nudge"; the implicit alternative (do nothing) has expected reward 0.
/// The engine nudges when its Upper Confidence Bound (UCB) score is ≥ 0.
///
/// **Algorithm:**
/// ```
/// UCB(x) = θᵀx + α √(xᵀA⁻¹x)   where θ = A⁻¹b
/// Update:  A ← A + xxᵀ
///          b ← b + r·x
/// ```
///
/// **State:**
/// - `A`: d×d precision matrix, initialised to λI (ridge regularisation, λ=1.0).
/// - `b`: d-length reward vector, initialised to zeros.
///
/// All matrix operations use Accelerate (BLAS/LAPACK), which is fast even on the CPU.
/// For d=16 (BanditFeatureVector.dimension) every call is <1 µs.
///
/// **Tuning α:**
/// Higher α → more exploration. Lower α → more exploitation.
/// Start at 0.4; reduce toward 0.15–0.2 once the engine has ≥200 reward observations.
struct ContextualBanditEngine: Codable, Sendable, Equatable {

    // MARK: - Constants

    static let d = BanditFeatureVector.dimension  // 16
    static let lambda: Double = 1.0               // ridge regularisation

    // MARK: - State

    /// Exploration coefficient (higher = more exploratory nudges).
    var alpha: Double = 0.4
    /// Precision matrix A (d×d, row-major). Initialised to λI.
    var A: [Double]
    /// Reward accumulator b (d-vector). Initialised to zeros.
    var b: [Double]

    // MARK: - Init

    init() {
        let d = Self.d
        var a = [Double](repeating: 0, count: d * d)
        for i in 0..<d { a[i * d + i] = Self.lambda }
        A = a
        b = [Double](repeating: 0, count: d)
    }

    // MARK: - Decision

    /// Returns whether to nudge and the raw UCB score (for telemetry).
    ///
    /// The baseline expected reward of "do nothing" is 0, so we nudge when UCB ≥ 0.
    mutating func shouldNudge(context x: BanditFeatureVector) -> (decision: Bool, ucb: Double) {
        guard x.values.count == Self.d else {
            return (false, 0)
        }
        let theta = solveTheta()
        let meanReward = dot(theta, x.values)
        let aInv = solveAInv()
        let variance = quadraticForm(aInv: aInv, x: x.values)
        let ucb = meanReward + alpha * sqrt(max(0, variance))
        return (ucb >= 0, ucb)
    }

    // MARK: - Update

    /// Incorporates an observed reward `r` for context `x` into the bandit state.
    mutating func update(context x: BanditFeatureVector, reward r: Double) {
        guard x.values.count == Self.d else { return }
        rankOneUpdate(vector: x.values)          // A += xxᵀ
        for i in 0..<Self.d { b[i] += r * x.values[i] }   // b += r·x
    }

    // MARK: - Private linear algebra (Accelerate)

    /// Solves A θ = b for θ using Cholesky factorisation (A is SPD).
    private func solveTheta() -> [Double] {
        var aCopy = A
        var bCopy = b
        var n = Int32(Self.d); var lda = Int32(Self.d); var ldb = Int32(Self.d)
        var nrhs: Int32 = 1
        var uplo = Int8(UnicodeScalar("U").value)
        var info: Int32 = 0
        // LAPACK: dposv_ solves A*X = B for symmetric positive definite A
        dposv_(&uplo, &n, &nrhs, &aCopy, &lda, &bCopy, &ldb, &info)
        if info != 0 {
            // Numerically degenerate: return zero weights (safe fallback)
            return [Double](repeating: 0, count: Self.d)
        }
        return bCopy
    }

    /// Computes A⁻¹ using Cholesky factorisation followed by inversion.
    private func solveAInv() -> [Double] {
        var aCopy = A
        var n = Int32(Self.d); var lda = Int32(Self.d)
        var uplo = Int8(UnicodeScalar("U").value)
        var info: Int32 = 0
        dpotrf_(&uplo, &n, &aCopy, &lda, &info)
        guard info == 0 else { return A }
        var n2 = Int32(Self.d); var lda2 = Int32(Self.d); var info2: Int32 = 0
        dpotri_(&uplo, &n2, &aCopy, &lda2, &info2)
        guard info2 == 0 else { return A }
        // dpotri fills only the upper triangle; mirror to lower for dsymv
        mirrorUpperToLower(&aCopy)
        return aCopy
    }

    /// Computes xᵀ A⁻¹ x efficiently using cblas_dsymv then cblas_ddot.
    private func quadraticForm(aInv: [Double], x: [Double]) -> Double {
        let d = Self.d
        var y = [Double](repeating: 0, count: d)
        // y = A⁻¹ x  (symmetric matrix-vector multiply)
        cblas_dsymv(
            CblasRowMajor, CblasUpper,
            Int32(d), 1.0, aInv, Int32(d),
            x, 1, 0.0, &y, 1
        )
        // xᵀ y
        return cblas_ddot(Int32(d), x, 1, y, 1)
    }

    /// Computes the dot product of two d-vectors.
    private func dot(_ a: [Double], _ b: [Double]) -> Double {
        cblas_ddot(Int32(Self.d), a, 1, b, 1)
    }

    /// Symmetric rank-1 update: A += x xᵀ using cblas_dsyr (upper triangle only),
    /// then mirrors upper to lower.
    private mutating func rankOneUpdate(vector x: [Double]) {
        cblas_dsyr(
            CblasRowMajor, CblasUpper,
            Int32(Self.d), 1.0, x, 1,
            &A, Int32(Self.d)
        )
        mirrorUpperToLower(&A)
    }

    /// Fills the lower triangle of a square matrix from the upper triangle.
    private func mirrorUpperToLower(_ m: inout [Double]) {
        let d = Self.d
        for i in 0..<d {
            for j in 0..<i {
                m[i * d + j] = m[j * d + i]
            }
        }
    }
}
