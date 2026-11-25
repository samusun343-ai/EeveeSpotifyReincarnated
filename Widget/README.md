# Eevee Lyrics widget (experimental)

A WidgetKit extension that shows the track playing in Spotify and the
current lyric line, using the lyrics EeveeSpotify already fetched in the
main app. It ships **only in the sideloaded IPA** — the jailbreak `.deb`
contains no app extension (there is no supported way for a package to add
an `.appex` into Spotify's sealed app bundle), so on that route the
feature is absent rather than broken.

## Layout

- `project.yml` — XcodeGen spec. The extension is a standalone Xcode
  target, separate from the Theos tweak build.
- `Sources/EeveeLyricsWidget.swift` — payload reader, timeline provider,
  views, widget definition (single file).
- `EeveeLyricsWidget.entitlements` — App Groups. The list **and order**
  mirror Spotify.app's own entitlements on purpose; see the comment in
  the file before changing either.

## How it gets its data

The tweak side is `Sources/EeveeSpotify/Widget/LyricsWidgetBridge.swift`:
after a lyrics fetch for the playing track, it writes a small payload
(track, artwork, timed/plain lines, playback anchor) to
`UserDefaults(suiteName: "group.com.spotify.client.widget")` and asks
WidgetKit to reload. The bridge between the two processes is
`modules/zxPluginsInject`, which is LC-injected into the main app and
every `.appex` by ipapatch and mirrors group-suite defaults through the
shared group container. Two build consequences:

1. The appex must be copied into `Payload/Spotify.app/PlugIns` **before**
   the ipapatch step, or it never receives the shim.
2. The appex is ad-hoc signed **with** its entitlements in CI: sideloader
   tooling reads requested App Groups from the code signature, and an
   unsigned binary carries none.

Both are wired up in `.github/workflows/buildpatched.yml` and
`build-ipa-local.sh`. The feature is gated by the "Lyrics Widget
(Experimental)" toggle in Eevee's lyrics settings (default off).

## Known limits

- WidgetKit reloads are budgeted (~40–70/day for a frequently viewed
  widget), so the widget reloads on track changes only. Line changes
  inside a track are pre-scheduled as future-dated timeline entries from
  the playback anchor — no reloads are spent on them, but iOS may
  coalesce dense timelines, and pausing/seeking desyncs the projection
  until the next track publishes a fresh payload.
- Installs that strip App Group entitlements entirely (some free-cert
  signing tools) leave the widget on its placeholder; TrollStore and
  properly provisioned installs keep the data path intact.
