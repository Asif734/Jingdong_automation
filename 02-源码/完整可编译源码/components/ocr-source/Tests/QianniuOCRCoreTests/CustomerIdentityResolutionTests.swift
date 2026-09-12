import XCTest
@testable import QianniuOCRCore

final class CustomerIdentityResolutionTests: XCTestCase {
    func testAcceptsArbitraryIdentifierFromStructuralAXHeader() {
        let candidates = CustomerIdentityCandidates(
            axHeader: "stoneshishininger",
            axSessionList: "stoneshishininger",
            ocr: nil
        )

        XCTAssertEqual(
            CustomerIdentityResolver.resolve(candidates: candidates, requestID: "R1"),
            ResolvedCustomerIdentity(
                identity: CustomerIdentity(value: "stoneshishininger", status: .detected),
                source: .axHeader,
                candidates: candidates
            )
        )
    }

    func testMatchingAXSourcesResolveDetectedHeaderIdentity() {
        let candidates = CustomerIdentityCandidates(
            axHeader: "tb9783153356",
            axSessionList: "tb9783153356",
            ocr: nil
        )

        XCTAssertEqual(
            CustomerIdentityResolver.resolve(candidates: candidates, requestID: "R1"),
            ResolvedCustomerIdentity(
                identity: CustomerIdentity(value: "tb9783153356", status: .detected),
                source: .axHeader,
                candidates: candidates
            )
        )
    }

    func testConflictingAXSourcesPreferHeaderButRequireReview() {
        let candidates = CustomerIdentityCandidates(
            axHeader: "tb9783153356",
            axSessionList: "tb263147182",
            ocr: "tb9783153356"
        )

        let result = CustomerIdentityResolver.resolve(candidates: candidates, requestID: "R1")

        XCTAssertEqual(result.identity, CustomerIdentity(value: "tb9783153356", status: .needsReview))
        XCTAssertEqual(result.source, .axHeader)
        XCTAssertEqual(result.candidates, candidates)
    }

    func testMissingHeaderUsesSelectedReceptionSession() {
        let candidates = CustomerIdentityCandidates(
            axHeader: nil,
            axSessionList: "tb263147182",
            ocr: nil
        )

        let result = CustomerIdentityResolver.resolve(candidates: candidates, requestID: "R1")

        XCTAssertEqual(result.identity, CustomerIdentity(value: "tb263147182", status: .detected))
        XCTAssertEqual(result.source, .axSessionList)
    }

    func testMissingAXUsesOCRThenRequestScopedFallback() {
        let ocrResult = CustomerIdentityResolver.resolve(
            candidates: CustomerIdentityCandidates(axHeader: nil, axSessionList: nil, ocr: "tb263147182"),
            requestID: "R1"
        )
        let fallback = CustomerIdentityResolver.resolve(candidates: .empty, requestID: "R1")

        XCTAssertEqual(ocrResult.identity, CustomerIdentity(value: "tb263147182", status: .detected))
        XCTAssertEqual(ocrResult.source, .ocr)
        XCTAssertEqual(fallback.identity, CustomerIdentity(value: "unknown-R1", status: .needsReview))
        XCTAssertEqual(fallback.source, .fallback)
    }

    func testInvalidCandidateIsIgnored() {
        let result = CustomerIdentityResolver.resolve(
            candidates: CustomerIdentityCandidates(axHeader: "2026-08-10", axSessionList: "tb263147182", ocr: nil),
            requestID: "R1"
        )

        XCTAssertEqual(result.identity.value, "tb263147182")
        XCTAssertEqual(result.source, .axSessionList)
    }
}
