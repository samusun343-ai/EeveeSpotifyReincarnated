import Orion
import UIKit
import MediaPlayer

// Global variables to store captured track metadata for 9.1.6
var capturedTrackTitle: String?
var capturedArtistName: String?
var capturedTrackId: String?
var capturedTrackIsrc: String?

// The capture globals above are written and read from several threads at
// once (Spotify's request threads, the prefetch queue, and the real fetch
// path during rapid skipping). All access goes through these helpers so a
// title/artist/id triple is never observed half-updated.
private let capturedTrackMetadataLock = NSLock()

/// Stores a captured metadata triple atomically. The ISRC is stored
/// alongside (only the Web API step can supply one); it belongs to the
/// same positively ID-matched resolution as the title/artist pair, so
/// it inherits their trust — see the adoption rules in CustomLyrics.
func storeCapturedTrackMetadata(trackId: String, title: String?, artist: String?, isrc: String? = nil) {
    capturedTrackMetadataLock.lock()
    capturedTrackId = trackId
    capturedTrackTitle = title
    capturedArtistName = artist
    capturedTrackIsrc = isrc
    capturedTrackMetadataLock.unlock()
}

/// Returns the captured title/artist if they were captured for `trackId`.
func capturedTrackMetadata(for trackId: String) -> (title: String, artist: String, isrc: String?)? {
    capturedTrackMetadataLock.lock()
    defer { capturedTrackMetadataLock.unlock() }

    guard capturedTrackId == trackId,
          let title = capturedTrackTitle,
          let artist = capturedArtistName
    else {
        return nil
    }

    return (title, artist, capturedTrackIsrc)
}

/// Drops the captured metadata if it belongs to a different track.
func clearCapturedTrackMetadata(unlessTrackId trackId: String) {
    capturedTrackMetadataLock.lock()

    if capturedTrackId != trackId {
        capturedTrackTitle = nil
        capturedArtistName = nil
        capturedTrackId = nil
        capturedTrackIsrc = nil
    }

    capturedTrackMetadataLock.unlock()
}

// Function to fetch track details using Spotify API if we have a token.
// The response also carries the track's ISRC (`external_ids.isrc`),
// which used to be parsed away; it is returned as well because the
// offline cache's identity keying needs it, and this ID-keyed request
// is the one resolution whose ISRC is certainly this track's own.
func fetchTrackDetails(trackId: String, token: String) -> (title: String, artist: String, isrc: String?)? {
    let urlString = "https://api.spotify.com/v1/tracks/\(trackId)"
    guard let url = URL(string: urlString) else { return nil }
    
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 3.0
    
    var result: (String, String, String?)?
    let semaphore = DispatchSemaphore(value: 0)

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }

        guard let data = data, error == nil else { return }

        // Simple JSON parsing
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String,
           let artists = json["artists"] as? [[String: Any]],
           let firstArtist = artists.first,
           let artistName = firstArtist["name"] as? String {
            let isrc = (json["external_ids"] as? [String: Any])?["isrc"] as? String
            result = (name, artistName, (isrc?.isEmpty == false) ? isrc : nil)
        }
    }
    
    task.resume()
    _ = semaphore.wait(timeout: .now() + 3.0)
    
    return result
}
