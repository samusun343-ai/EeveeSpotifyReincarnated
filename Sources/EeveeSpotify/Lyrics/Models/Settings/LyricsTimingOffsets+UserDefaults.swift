import Foundation

extension UserDefaults {
    @UserDefault(
        key: "lyricsTimingOffsets",
        defaultValue: LyricsTimingOffsets()
    )
    static var lyricsTimingOffsets
}
