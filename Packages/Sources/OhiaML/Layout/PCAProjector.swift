import Accelerate
import Foundation

public enum PCAProjector {

    public enum Error: Swift.Error { case emptyInput, dimensionMismatch, eigensolverFailed(info: Int32) }

    /// Project N vectors of dimension D onto top-3 principal components,
    /// then normalize to a bounded cube ~[-1, 1]³.
    public static func project(vectors: [[Float]]) throws -> [SIMD3<Float>] {
        guard let first = vectors.first else { throw Error.emptyInput }
        let d = first.count
        for v in vectors where v.count != d { throw Error.dimensionMismatch }
        let n = vectors.count

        // Flatten into N*D row-major matrix
        var data = [Float](); data.reserveCapacity(n * d)
        for v in vectors { data.append(contentsOf: v) }

        // Compute mean per column and subtract
        var mean = [Float](repeating: 0, count: d)
        for i in 0..<n {
            for j in 0..<d { mean[j] += data[i * d + j] }
        }
        for j in 0..<d { mean[j] /= Float(n) }
        for i in 0..<n {
            for j in 0..<d { data[i * d + j] -= mean[j] }
        }

        // Covariance D×D via explicit loops — vDSP_mmul computes X×Y, we need X^T×X.
        var cov = [Float](repeating: 0, count: d * d)
        for a in 0..<d {
            for b in 0..<d {
                var sum: Float = 0
                for i in 0..<n { sum += data[i * d + a] * data[i * d + b] }
                cov[a * d + b] = sum / Float(max(n - 1, 1))
            }
        }

        // Eigendecomposition of symmetric D×D via LAPACK ssyevr
        var jobz: CChar = 0x56  // 'V' — compute eigenvalues + eigenvectors
        var range: CChar = 0x41 // 'A' — all eigenvalues
        var uplo: CChar = 0x55  // 'U' — upper triangle
        var nn = __LAPACK_int(d)
        var lda = __LAPACK_int(d)
        var vl: Float = 0, vu: Float = 0
        var il: __LAPACK_int = 0, iu: __LAPACK_int = 0
        var abstol: Float = 0
        var m: __LAPACK_int = 0
        var w = [Float](repeating: 0, count: d)           // eigenvalues (ascending)
        var z = [Float](repeating: 0, count: d * d)       // eigenvectors columnwise
        var ldz = __LAPACK_int(d)
        var isuppz = [__LAPACK_int](repeating: 0, count: 2 * d)
        var workQuery: Float = 0
        var lwork: __LAPACK_int = -1
        var iworkQuery: __LAPACK_int = 0
        var liwork: __LAPACK_int = -1
        var info: __LAPACK_int = 0

        // Workspace query
        ssyevr_(&jobz, &range, &uplo, &nn, &cov, &lda, &vl, &vu, &il, &iu,
                &abstol, &m, &w, &z, &ldz, &isuppz, &workQuery, &lwork,
                &iworkQuery, &liwork, &info)
        guard info == 0 else { throw Error.eigensolverFailed(info: Int32(info)) }
        lwork = __LAPACK_int(workQuery)
        liwork = iworkQuery
        var work = [Float](repeating: 0, count: Int(lwork))
        var iwork = [__LAPACK_int](repeating: 0, count: Int(liwork))

        // Actual call
        ssyevr_(&jobz, &range, &uplo, &nn, &cov, &lda, &vl, &vu, &il, &iu,
                &abstol, &m, &w, &z, &ldz, &isuppz, &work, &lwork,
                &iwork, &liwork, &info)
        guard info == 0 else { throw Error.eigensolverFailed(info: Int32(info)) }

        // Top-3 eigenvectors are last three columns of z (eigenvalues ascending, so top = highest index)
        let pc1 = Array(z[(d-1)*d..<d*d])
        let pc2 = Array(z[(d-2)*d..<(d-1)*d])
        let pc3 = Array(z[(d-3)*d..<(d-2)*d])

        // Project each mean-centered vector onto PCs
        var raw = [SIMD3<Float>]()
        raw.reserveCapacity(n)
        for i in 0..<n {
            let offset = i * d
            var x: Float = 0, y: Float = 0, zc: Float = 0
            for j in 0..<d {
                let v = data[offset + j]
                x += v * pc1[j]
                y += v * pc2[j]
                zc += v * pc3[j]
            }
            raw.append(SIMD3<Float>(x, y, zc))
        }

        // Normalize to [-1, 1]³
        let maxAbs = raw.flatMap { [abs($0.x), abs($0.y), abs($0.z)] }.max() ?? 1
        let scale: Float = maxAbs > 0 ? 1.0 / maxAbs : 1.0
        return raw.map { $0 * scale }
    }
}
