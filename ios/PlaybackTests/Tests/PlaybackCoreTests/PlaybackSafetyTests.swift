import XCTest
@testable import PlaybackCore

final class PlaybackSafetyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "albumPlayback.v1")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "albumPlayback.v1")
        super.tearDown()
    }

    func testPageBoundaries() {
        for count in [0, 1, 19, 20, 5000] {
            let all = Array(0..<count)
            let page = ChapterPager.firstPage(all)
            let expectedSize = count == 0 ? 20 : min(50, count)
            XCTAssertEqual(ChapterPager.firstPageSize(totalCount: count), expectedSize)
            XCTAssertEqual(page.count, min(50, count))
            XCTAssertEqual(page, Array(all.prefix(50)))
            XCTAssertNil(ChapterPager.page(all, number: 1, pageSize: 0))
            XCTAssertNil(ChapterPager.page(all, number: -1, pageSize: 20))
            XCTAssertNil(ChapterPager.page(all, number: Int.max, pageSize: 20))
            if count > 0 {
                XCTAssertEqual(ChapterPager.page(all, number: 1, pageSize: 20), Array(all.prefix(20)))
            }
        }
    }

    func testNonFiniteSpeedIsNotPersistableJSON() {
        var prefs = LocalStore.PlayPrefs()
        prefs.defaultSpeed = .nan
        XCTAssertThrowsError(try JSONEncoder().encode(prefs))
    }

    func testOldPlayPrefsWithoutSpeedUsesOne() throws {
        let json = #"{"seekSeconds":10,"skipSilence":false}"#.data(using: .utf8)!
        let prefs = try JSONDecoder().decode(LocalStore.PlayPrefs.self, from: json)
        XCTAssertEqual(prefs.defaultSpeed, 1.0)
        XCTAssertTrue(prefs.useGlobalSpeed)
    }

    func testEffectiveClampsZeroNegativeAndNonFiniteSpeed() throws {
        let key = BookKey(sourceId: "test", albumId: 1, bookUrl: "/album/1")
        for (raw, expected) in [(0.0, 0.5), (-2.0, 0.5), (99.0, 3.0),
                                (Double.nan, 1.0), (Double.infinity, 1.0),
                                (-Double.infinity, 1.0)] {
            var prefs = LocalStore.PlayPrefs()
            prefs.defaultSpeed = raw
            prefs.useGlobalSpeed = true
            let out = LocalStore.effective(for: key, prefs: prefs)
            XCTAssertEqual(out.speed, expected, "raw=\(raw)")
            XCTAssertTrue(out.speed.isFinite)
            XCTAssertGreaterThanOrEqual(out.speed, 0.5)
            XCTAssertLessThanOrEqual(out.speed, 3.0)
        }
    }

    func testAlbumSpeedUsesSameSanitizer() throws {
        let key = BookKey(sourceId: "album-test", albumId: 0, bookUrl: "/book/1")
        var album = LocalStore.AlbumPlayback()
        album.speed = 0
        LocalStore.saveAlbumPlayback(album, for: key)
        var prefs = LocalStore.PlayPrefs()
        prefs.useGlobalSpeed = false
        prefs.defaultSpeed = 1.25
        XCTAssertEqual(LocalStore.effective(for: key, prefs: prefs).speed, 0.5)
        LocalStore.clearAlbumPlayback(for: key)
    }

    func testRecentLegacyJSONAndRoundTrip() throws {
        let legacy = #"{"bookUrl":"/album/1","bookTitle":"书","trackId":2,"episodeTitle":"集","playedAt":0}"#
            .data(using: .utf8)!
        let old = try JSONDecoder().decode(LocalStore.Recent.self, from: legacy)
        XCTAssertEqual(old.sourceId, "ximalaya-open")
        XCTAssertEqual(old.episodeUrl, "")
        XCTAssertEqual(old.coverUrl, "")
        let encoded = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(LocalStore.Recent.self, from: encoded)
        XCTAssertEqual(decoded.trackId, 2)
        XCTAssertEqual(decoded.bookTitle, "书")
    }

    func testBookKeyFallsBackToWholeURLButCacheUsesHexOnly() {
        let url = "https://www.ximalaya.com/album/123"
        let key = BookKey(sourceId: "ximalaya", albumId: 0, bookUrl: url)
        XCTAssertEqual(key.id, "ximalaya:" + url)
        let dir = AudioCache.dir(for: key.bookUrl)
        let name = dir.lastPathComponent
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.allSatisfy { $0.isHexDigit })
        XCTAssertFalse(dir.path.contains("www.ximalaya.com"))
    }
}
