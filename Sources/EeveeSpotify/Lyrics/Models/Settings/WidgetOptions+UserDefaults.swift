import Foundation

extension UserDefaults {
    /// Experimental home-screen lyrics widget (IPA installs only — the
    /// widget extension ships inside the patched IPA, not in the .deb).
    /// Off by default; see LyricsWidgetBridge.
    @UserDefault(
        key: "lyricsWidgetEnabled",
        defaultValue: false
    )
    static var lyricsWidgetEnabled
}
