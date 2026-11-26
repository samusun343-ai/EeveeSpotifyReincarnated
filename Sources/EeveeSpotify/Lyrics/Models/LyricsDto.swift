import Foundation

struct LyricsDto {
    var lines: [LyricsLineDto]
    var timeSynced: Bool
    var romanization: LyricsRomanizationStatus
    var translation: LyricsTranslationDto?
    var providerCredit: String? = nil
    /// The ISRC of the recording these lyrics actually came from, when
    /// the producing stage resolved one *and* verified the match
    /// (currently the lrc.red stage of the combined source: its search
    /// hit must match the query on normalized title/artist — an
    /// unverified first-hit fallback never sets this). The offline
    /// cache files the entry under this identity so duplicate track
    /// IDs of the same recording share it (LyricsIdentity). It is
    /// provenance, not display data, and is never adopted from another
    /// track's metadata.
    var resolvedIsrc: String? = nil

    /// Returns a copy with every line's timestamp shifted by `offsetMs`
    /// (clamped at zero), applying the user's timing correction for the
    /// native lyrics view. The karaoke overlay compensates on the
    /// playback-position side instead (see KaraokeLyricsView), so DTOs
    /// handed to it — directly or via `KaraokeLyricsDto.lineSynced` —
    /// must stay unshifted.
    func applyingTimingOffset(_ offsetMs: Int) -> LyricsDto {
        guard offsetMs != 0 else { return self }

        var copy = self
        copy.lines = lines.map { line in
            var line = line
            if let offset = line.offsetMs {
                line.offsetMs = max(0, offset + offsetMs)
            }
            return line
        }
        return copy
    }

    func toSpotifyLyricsData(source: String) -> LyricsData {
        var lyricsData = LyricsData.with {
            // Real response schema field 1 is a 3-value syncType enum;
            // .lineSynced (1) encodes exactly like the old Bool `true`.
            $0.syncType = timeSynced ? .lineSynced : .unsynced
            // Eevee serves complete lyrics, never a capped preview, so
            // the truthful cap status is .uncapped. The client's
            // internal v3 lyrics model likewise stores a capStatus, and
            // the NPV lyrics surfaces are fed from that model — leaving
            // it at the .none default reports Eevee-served lyrics as of
            // unknown capping state.
            $0.capStatus = .uncapped
            $0.provider = providerCredit ?? source
            $0.providedBy = "\(providerCredit ?? source) (EeveeSpotify)"
        }
        
        let shouldRomanize = UserDefaults.lyricsOptions.romanization
        
        if lines.isEmpty {
            lyricsData.lines = [
                LyricsLine.with {
                    $0.content = "song_is_instrumental".localized
                },
                LyricsLine.with {
                    $0.content = "let_the_music_play".localized
                },
                LyricsLine.with {
                    $0.content = ""
                }
            ]
        }
        else {
            let sortedLines = lines.sorted {
                ($0.offsetMs ?? 0) < ($1.offsetMs ?? 0)
            }
            lyricsData.lines = sortedLines.enumerated().map { index, line in
                let startMs = line.offsetMs ?? 0
                // Spotify's native lyrics block needs a per-line end time
                // (endTimeMs, schema field 4) to highlight and seek.
                // Derive it exactly like the karaoke side does
                // (KaraokeLyricsDto.lineSynced): the next line's start —
                // searching the full sorted list, so a trailing empty
                // end-marker line still terminates the previous line —
                // or start + 4s for the final line.
                var endTimeMs: Int64 = 0
                if timeSynced {
                    let nextStartMs = sortedLines[(index + 1)...]
                        .first { ($0.offsetMs ?? 0) > startMs }
                        .map { $0.offsetMs ?? 0 }
                    endTimeMs = Int64(nextStartMs ?? startMs + 4000)
                }
                return LyricsLine.with {
                    $0.content = (shouldRomanize && romanization == .canBeRomanized)
                        ? line.content.applyingTransform(.toLatin, reverse: false)!
                        : line.content
                    $0.offsetMs = Int32(startMs)
                    $0.endTimeMs = endTimeMs
                }
            }
        }
        
        if !lines.isEmpty {
            // Real schema field 17 is `previewLines`: the short preview
            // the NPV lyrics card shows (the card element has dedicated
            // snippet states). Official responses carry the opening
            // lines there; mirror that with the first lines of the
            // lyrics actually served above.
            lyricsData.previewLines = Array(lyricsData.lines.prefix(4))
        }

        if let translation = translation {
            // Real schema field 9 is `alternatives` (repeated): the
            // client reads a translation as an alternative-language
            // version of the lyrics. The wire layout is unchanged from
            // the previous singular `translation` modelling.
            lyricsData.alternatives = [
                LyricsAlternative.with {
                    $0.language = translation.languageCode
                    $0.lines = translation.lines
                }
            ]
        }

        ensureCardGateAlternative(&lyricsData)

        return lyricsData
    }

    /// Spotify's own key for the user's selected lyrics translation
    /// language (owned by PersistentSelectedTranslationLanguageState,
    /// which reads it from the standard UserDefaults domain). Absent
    /// when the user has never picked a translation language.
    private static let selectedTranslationLanguageKey =
        "com.spotify.lyrics.selectedTranslationLanguage"

    /// Seed an empty-but-present translation language selection.
    ///
    /// The native card's binder never evaluates its snapshot at all
    /// when no translation language is selected: the load request's
    /// language field is then the nil Optional pair (0, 0), and the
    /// binder's entry check (second word == 0) routes it straight to
    /// the event-driven path, whose trigger is outside the response's
    /// control. So on an unselected device no response content — the
    /// `alternatives` guarantee below included — can make the card
    /// appear at bind time.
    ///
    /// The state class reads this key exactly once, when it is first
    /// created, and treats any stored string as an existing selection
    /// (its own setter likewise only distinguishes nil from non-nil).
    /// Storing an empty string therefore makes the state read back an
    /// existing-but-empty selection: the request's language field
    /// becomes a genuine empty string, the binder takes the snapshot
    /// path, and its language comparison matches the empty-language
    /// element `ensureCardGateAlternative` guarantees. A real user
    /// selection is never overwritten — this only fills the absent
    /// case, and Spotify's own setter replaces the value as usual if
    /// the user later picks a language.
    ///
    /// Must run before the state class is first created. It is
    /// demand-created by the lyrics view pipeline, so tweak
    /// initialization (Tweak.x.swift) is early enough; calling this
    /// after the state exists would only take effect next launch.
    static func seedEmptyTranslationLanguageSelectionIfAbsent() {
        let defaults = UserDefaults.standard

        guard defaults.object(forKey: selectedTranslationLanguageKey) == nil
        else { return }

        defaults.set("", forKey: selectedTranslationLanguageKey)
        writeDebugLog(
            "[Lyrics] Seeded empty translation language selection "
                + "so the native lyrics card gate sees a selection"
        )
    }

    /// The seeded selection is only ever read when Spotify's lyrics
    /// configuration vends the state above as enabled, and that is
    /// gated on the remote-config flag
    /// `ios-feature-lyrics.enable_lyrics_multilanguage_npv`: the
    /// configuration test manager reads it (default false) and vends
    /// the state only when it — or the fullscreen sibling — is on,
    /// and the NPV lyrics pipeline likewise only forwards the state
    /// to its publisher when the same flag (or the entry-point /
    /// context-menu toggles) reads on. Both evaluations go through
    /// `ConfigurationProviderImpl.boolValueForId:defaultValue:` via
    /// objc_msgSend, so supply the value at that evaluation seam
    /// only, through the RemoteFlags hook, instead of writing it
    /// into the resolved configuration: the store, its persistence
    /// and every other consumer of the raw configuration never see
    /// it. Only the NPV flag is forced — the fullscreen flag feeds
    /// the fullscreen lyrics card element and the lyrics context
    /// menu as well, and leaving it off keeps those surfaces exactly
    /// as shipped while the NPV flag alone opens both gates.
    ///
    /// Must be registered before `activateRemoteFlags()` prepares
    /// the effective override table; Tweak.x.swift calls it next to
    /// the seed, which runs earlier in the same init.
    static func forceLyricsCardGateFlag() {
        RemoteFlags.shared.force(
            ["ios-feature-lyrics.enable_lyrics_multilanguage_npv": true],
            by: "LyricsCardGate"
        )
    }

    /// The native lyrics card is gated on `alternatives`: once the
    /// binder takes its snapshot path (which requires a translation
    /// language selection to exist — see
    /// `seedEmptyTranslationLanguageSelectionIfAbsent`), it only
    /// forwards the lyrics entry to the card when one element's
    /// `language` equals the selected language. A substituted
    /// response without a matching element is silently dropped by
    /// that check, which is why replaced lyrics rendered in Eevee's
    /// own views but the native card never appeared. Guarantee a
    /// matching element. The element carries the track's own lines,
    /// shaped like a genuine translation entry; the gate compares
    /// only the language, and the display conversion discards
    /// alternatives.
    ///
    /// The client's read of the stored selection is itself gated by
    /// a Bool in the state class: on a device where that gate is off,
    /// the effective key is empty even though a selection is stored.
    /// So when a selection is stored, guarantee BOTH the stored
    /// language and the empty language are present — the gate passes
    /// if either matches, and the settings action's lookup only ever
    /// picks the element matching its own key, so the extra element
    /// stays inert. Elements already present (e.g. from a genuine
    /// translation) are never duplicated.
    private func ensureCardGateAlternative(_ lyricsData: inout LyricsData) {
        let storedLanguage = UserDefaults.standard.string(
            forKey: Self.selectedTranslationLanguageKey
        )

        var targetLanguages = [""]
        if let storedLanguage, storedLanguage != "" {
            targetLanguages.insert(storedLanguage, at: 0)
        }

        for language in targetLanguages {
            guard !lyricsData.alternatives.contains(
                where: { $0.language == language }
            ) else { continue }

            lyricsData.alternatives.append(
                LyricsAlternative.with {
                    $0.language = language
                    $0.lines = lyricsData.lines.map { $0.content }
                }
            )
        }
    }
}

// Codable for the offline lyrics cache (LyricsOfflineCache.swift).
extension LyricsDto: Codable {}
