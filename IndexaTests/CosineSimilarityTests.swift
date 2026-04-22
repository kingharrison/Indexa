import Testing
import Foundation
@testable import Indexa

@Suite("Cosine Similarity")
struct CosineSimilarityTests {

    // Use a VectorStore with a dummy path — cosineSimilarity is pure math
    let store = VectorStore(dbPath: "/dev/null")

    @Test("Identical vectors return 1.0")
    func identical() {
        let a: [Float] = [1, 2, 3]
        let result = store.cosineSimilarity(a, a)
        #expect(abs(result - 1.0) < 0.0001)
    }

    @Test("Orthogonal vectors return 0.0")
    func orthogonal() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        let result = store.cosineSimilarity(a, b)
        #expect(abs(result) < 0.0001)
    }

    @Test("Opposite vectors return -1.0")
    func opposite() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [-1, 0, 0]
        let result = store.cosineSimilarity(a, b)
        #expect(abs(result - (-1.0)) < 0.0001)
    }

    @Test("Empty vectors return 0.0")
    func emptyVectors() {
        let result = store.cosineSimilarity([], [])
        #expect(result == 0.0)
    }

    @Test("Mismatched lengths return 0.0")
    func mismatchedLengths() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [1, 2]
        let result = store.cosineSimilarity(a, b)
        #expect(result == 0.0)
    }

    @Test("45-degree angle produces expected similarity")
    func knownAngle() {
        let a: [Float] = [1, 0]
        let b: [Float] = [1, 1]
        let result = store.cosineSimilarity(a, b)
        // cos(45°) ≈ 0.7071
        #expect(abs(result - 0.7071) < 0.001)
    }

    @Test("Scaled vectors have same similarity as unit vectors")
    func scaleInvariance() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [4, 5, 6]
        let aScaled: [Float] = [10, 20, 30]

        let result1 = store.cosineSimilarity(a, b)
        let result2 = store.cosineSimilarity(aScaled, b)
        #expect(abs(result1 - result2) < 0.0001)
    }
}
