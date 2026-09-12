import XCTest
@testable import QianniuOCRAppSupport

final class ResourceRootSelectionTests: XCTestCase {
    func testInstalledResourceRootIsDerivedWithoutOpeningBundleMetadata() {
        let executable = "/Applications/Demo.app/Contents/MacOS/Demo"

        let selected = ResourceRootSelection.installedResourceRoot(executablePath: executable)

        XCTAssertEqual(
            selected.path,
            "/Applications/Demo.app/Contents/Resources/WebOCR"
        )
    }

    func testEmbeddedAppUsesItsOwnDirectPackagedWebOCRDirectory() {
        let executable = "/Applications/Suite.app/Contents/Resources/Components/OCR.app/Contents/MacOS/OCR"

        let selected = ResourceRootSelection.installedResourceRoot(executablePath: executable)

        XCTAssertEqual(
            selected.path,
            "/Applications/Suite.app/Contents/Resources/Components/OCR.app/Contents/Resources/WebOCR"
        )
    }

    func testPackagedResourcePreventsDevelopmentBundleLookup() throws {
        let packaged = URL(fileURLWithPath: "/Applications/OCR.app/Contents/Resources/WebOCR")
        var developmentLookupCount = 0

        let selected = ResourceRootSelection.select(
            packaged: packaged,
            exists: { $0 == packaged },
            development: {
                developmentLookupCount += 1
                return URL(fileURLWithPath: "/tmp/development")
            }
        )

        XCTAssertEqual(selected, packaged)
        XCTAssertEqual(developmentLookupCount, 0)
    }

    func testPackagedOpenCVScriptPreventsDevelopmentBundleLookup() throws {
        let packaged = URL(
            fileURLWithPath: "/Applications/VersionB.app/Contents/Resources/OpenCV/video_play_locator.py"
        )
        var developmentLookupCount = 0

        let selected = try ResourceRootSelection.openCVScript(
            packaged: packaged,
            exists: { $0 == packaged },
            development: {
                developmentLookupCount += 1
                throw CocoaError(.fileNoSuchFile)
            }
        )

        XCTAssertEqual(selected, packaged)
        XCTAssertEqual(developmentLookupCount, 0)
    }
}
