import Foundation

// Test-only model stub. The production bridge depends on the generated framework.
enum SharedBridge {
    struct EpisodeRow {
        let title: String
        let trackId: Int64
        let index: Int32
        let durationMs: Int64
        let coverUrl: String
        let url: String
        let playable: Bool
        let hint: String

        init(title: String, trackId: Int64, index: Int32, durationMs: Int64,
             coverUrl: String, url: String, playable: Bool = true, hint: String = "") {
            self.title = title
            self.trackId = trackId
            self.index = index
            self.durationMs = durationMs
            self.coverUrl = coverUrl
            self.url = url
            self.playable = playable
            self.hint = hint
        }
    }
    struct BookCard {
        let bookUrl: String
        let title: String
        let author: String
        let coverUrl: String
        let albumId: Int64
        let trackCount: Int64
        let playCount: Int64
        let isFinished: Bool?
        var intro: String = ""
    }
    static func episodeRow(title: String, trackId: Int64, index: Int32,
                           durationMs: Int64, coverUrl: String, url: String,
                           playable: Bool = true, hint: String = "") -> EpisodeRow {
        EpisodeRow(title: title, trackId: trackId, index: index, durationMs: durationMs,
                   coverUrl: coverUrl, url: url, playable: playable, hint: hint)
    }
    static func albumId(from bookUrl: String) -> Int64 { 0 }
}
