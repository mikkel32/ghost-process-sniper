import XCTest
@testable import GhostProcessSniperCore

final class PathTextTests: XCTestCase {
    func testDisplayNameDropsTheBundleExtension() {
        XCTAssertEqual(PathText.displayName("/Applications/Google Chrome.app"), "Google Chrome")
        XCTAssertEqual(PathText.displayName("/Applications/Foo.bar.app"), "Foo.bar")
        XCTAssertEqual(PathText.displayName("/Applications/Foo.app/"), "Foo")
        XCTAssertEqual(PathText.displayName("/usr/bin/clang"), "clang")
        XCTAssertEqual(PathText.displayName("/Users/me/.hidden"), ".hidden")
    }

    func testEmptyAndRootPathsStayStable() {
        XCTAssertEqual(PathText.displayName(""), "")
        XCTAssertEqual(PathText.displayName("/"), "/")
        XCTAssertEqual(PathText.lastComponent("//"), "/")
        XCTAssertEqual(PathText.deletingExtension("archive."), "archive.")
    }

    func testParentMatchesDirectoryNesting() {
        XCTAssertEqual(PathText.parent("/Applications/Xcode.app/Contents/MacOS/Xcode"), "/Applications/Xcode.app/Contents/MacOS")
        XCTAssertEqual(PathText.parent("/Applications/"), "/")
        XCTAssertEqual(PathText.parent("/tool"), "/")
        XCTAssertEqual(PathText.parent("tool"), "")
        XCTAssertEqual(PathText.parent("/"), "/")
    }
}
