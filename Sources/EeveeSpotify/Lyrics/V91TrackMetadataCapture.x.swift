import Orion
import UIKit
import MediaPlayer

// Global variables to store captured track metadata for 9.1.6
var capturedTrackTitle: String?
var capturedArtistName: String?
var capturedTrackId: String?

// The capture globals above are written and read from several threads at
// once (Spotify's request threads, the prefetch queue, and the real fetch
// path during rapid skipping). All access goes through these helpers so a
// title/artist/id triple is never observed half-updated.
private let capturedTrackMetadataLock = NSLock()

/// Stores a captured metadata triple atomically.
func storeCapturedTrackMetadata(trackId: String, title: String?, artist: String?) {
    capturedTrackMetadataLock.lock()
    capturedTrackId = trackId
    capturedTrackTitle = title
    capturedArtistName = artist
    capturedTrackMetadataLock.unlock()
}

/// Returns the captured title/artist if they were captured for `trackId`.
func capturedTrackMetadata(for trackId: String) -> (title: String, artist: String)? {
    capturedTrackMetadataLock.lock()
    defer { capturedTrackMetadataLock.unlock() }
    
    guard capturedTrackId == trackId,
          let title = capturedTrackTitle,
          let artist = capturedArtistName
    else {
        return nil
    }
    
    return (title, artist)
}

/// Drops the captured metadata if it belongs to a different track.
func clearCapturedTrackMetadata(unlessTrackId trackId: String) {
    capturedTrackMetadataLock.lock()
    
    if capturedTrackId != trackId {
        capturedTrackTitle = nil
        capturedArtistName = nil
        capturedTrackId = nil
    }
    
    capturedTrackMetadataLock.unlock()
}

// Function to fetch track details using Spotify API if we have a token
func fetchTrackDetails(trackId: String, token: String) -> (title: String, artist: String)? {
    let urlString = "https://api.spotify.com/v1/tracks/\(trackId)"
    guard let url = URL(string: urlString) else { return nil }
    
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 3.0
    
    var result: (String, String)?
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
            result = (name, artistName)
        }
    }
    
    task.resume()
    _ = semaphore.wait(timeout: .now() + 3.0)
    
    return result
}
