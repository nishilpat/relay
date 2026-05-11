//
//  ElevenLabsTTSClient.swift
//
//  Streams text-to-speech audio from ElevenLabs and plays it back
//  through the system audio output. Downloads the full audio then plays
//  via AVAudioPlayer so the reference is kept alive for the duration.
//  Apple Speech (NSSpeechSynthesizer) is the fallback — handled in CompanionManager.
//

import AVFoundation
import Foundation

@MainActor
final class ElevenLabsTTSClient {
    private let proxyURL: URL
    private let session: URLSession

    /// Kept alive so audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?

    init(proxyURL: String) {
        self.proxyURL = URL(string: proxyURL)!

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest  = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    /// Sends `text` to ElevenLabs TTS via the Cloudflare Worker proxy and plays the audio.
    /// Throws on network or decoding errors. Cancellation-safe.
    func speakText(_ text: String) async throws {
        print("🔊 [ElevenLabs] speakText called — \(text.prefix(60))")

        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg",        forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text":      text,
            "model_id":  "eleven_turbo_v2_5",
            "voice_settings": [
                "stability":        0.5,
                "similarity_boost": 0.75
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("🔊 [ElevenLabs] POSTing to \(proxyURL.absoluteString)")
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            print("🔊 [ElevenLabs] ❌ Not an HTTP response")
            throw NSError(domain: "ElevenLabsTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        print("🔊 [ElevenLabs] HTTP \(httpResponse.statusCode) — \(data.count) bytes — content-type: \(httpResponse.value(forHTTPHeaderField: "content-type") ?? "none")")

        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("🔊 [ElevenLabs] ❌ Error response: \(errorBody)")
            throw NSError(domain: "ElevenLabsTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey:
                              "TTS API error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        try Task.checkCancellation()

        do {
            let player = try AVAudioPlayer(data: data)
            player.prepareToPlay()
            self.audioPlayer = player
            let started = player.play()
            print("🔊 [ElevenLabs] AVAudioPlayer.play() returned: \(started) — duration: \(player.duration)s")
        } catch {
            print("🔊 [ElevenLabs] ❌ AVAudioPlayer init failed: \(error)")
            throw error
        }
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
    }
}
