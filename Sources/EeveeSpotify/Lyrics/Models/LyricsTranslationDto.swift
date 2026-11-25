import Foundation

struct LyricsTranslationDto {
    var languageCode: String
    var lines: [String]
}

extension LyricsTranslationDto: Codable {}
