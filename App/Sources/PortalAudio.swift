import AVFoundation
import Foundation
import RealityKit

/// Bundled, generated soundscape (see Tools/assetgen/audio.py).  Sources are
/// spatial and positioned at the doorway, so RealityKit applies distance
/// attenuation and direction as the user moves.
@MainActor
final class PortalAudio {
    private var rain: AudioFileResource?
    private var city: AudioFileResource?
    private var hum: AudioFileResource?
    private var openFX: AudioFileResource?
    private var closeFX: AudioFileResource?
    private var rainCtl: AudioPlaybackController?
    private var cityCtl: AudioPlaybackController?
    private var humCtl: AudioPlaybackController?
    private(set) var loadError: String?

    init(baseURL: URL) {
        func load(_ name: String, loop: Bool) -> AudioFileResource? {
            do {
                return try AudioFileResource.load(contentsOf: baseURL.appendingPathComponent("audio/\(name)"),
                                                  withName: name, inputMode: .spatial,
                                                  loadingStrategy: .preload, shouldLoop: loop)
            } catch {
                loadError = "\(name): \(error.localizedDescription)"
                return nil
            }
        }
        rain = load("rain_loop.wav", loop: true)
        city = load("city_loop.wav", loop: true)
        hum = load("hum_loop.wav", loop: true)
        openFX = load("portal_open.wav", loop: false)
        closeFX = load("portal_close.wav", loop: false)
    }

    static func configureSession() {
        // Ambient: mixes with other audio and respects the silent switch.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func start(ambient: Entity, hum humEmitter: Entity) {
        stop()
        if let rain { rainCtl = ambient.playAudio(rain) }
        if let city { cityCtl = ambient.playAudio(city) }
        if let hum { humCtl = humEmitter.playAudio(hum) }
        for c in [rainCtl, cityCtl, humCtl] { c?.gain = -80 }
    }

    func playOpen(on e: Entity, muted: Bool) {
        guard !muted, let openFX else { return }
        e.playAudio(openFX).gain = -8
    }

    func playClose(on e: Entity, muted: Bool) {
        guard !muted, let closeFX else { return }
        e.playAudio(closeFX).gain = -10
    }

    /// aperture 0..1 (how open the view is), frame 0..1 (doorway visible).
    func update(aperture: Float, frame: Float, muted: Bool) {
        func db(_ level: Float, _ base: Double) -> Double {
            muted || level <= 0.001 ? -80 : base + 20 * log10(Double(max(level, 0.02)))
        }
        rainCtl?.gain = db(aperture, -9)
        cityCtl?.gain = db(aperture, -15)
        humCtl?.gain = db(frame, -24)
    }

    func stop() {
        for c in [rainCtl, cityCtl, humCtl] { c?.stop() }
        rainCtl = nil; cityCtl = nil; humCtl = nil
    }
}
