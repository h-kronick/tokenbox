import AVFoundation
import AppKit

/// AVAudioEngine-based sound engine for split-flap click sounds.
/// Uses a pool of player nodes for low-latency polyphonic playback with
/// subtle per-trigger randomization (pitch, volume) for natural feel.
@MainActor
final class FlapSoundEngine {
    static let shared = FlapSoundEngine()

    private var engine: AVAudioEngine?
    private var mixer: AVAudioMixerNode?
    private var playerNodes: [AVAudioPlayerNode] = []
    private var flapBuffer: AVAudioPCMBuffer?
    private var nextNodeIndex = 0
    private var isSetUp = false

    /// Master volume (0...1), set from user preference.
    var volume: Double = 0.5 {
        didSet {
            mixer?.outputVolume = Float(volume)
        }
    }

    /// Whether sound is enabled.
    var enabled: Bool = true

    private let nodePoolSize = 16

    private init() {}

    // MARK: - Setup

    /// Initialize the audio engine and synthesize the flap sound buffer.
    /// Call once at app launch. Safe to call multiple times (idempotent).
    func setUp() {
        guard !isSetUp else { return }

        let engine = AVAudioEngine()
        let mixer = AVAudioMixerNode()
        engine.attach(mixer)
        engine.connect(mixer, to: engine.mainMixerNode, format: nil)

        let sampleRate: Double = 44100
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return
        }

        // Create player node pool
        for _ in 0..<nodePoolSize {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: mixer, format: format)
            playerNodes.append(player)
        }

        // Synthesize the flap click sound
        flapBuffer = synthesizeFlapSound(format: format, sampleRate: sampleRate)

        mixer.outputVolume = Float(volume)

        do {
            try engine.start()
            // Start all player nodes
            for player in playerNodes {
                player.play()
            }
            self.engine = engine
            self.mixer = mixer
            isSetUp = true
        } catch {
            // Audio setup failed silently — sound just won't play
        }
    }

    // MARK: - Playback

    /// Trigger a single flap click with subtle randomization.
    func playFlap() {
        guard enabled, isSetUp, let buffer = flapBuffer else { return }

        let player = playerNodes[nextNodeIndex]
        nextNodeIndex = (nextNodeIndex + 1) % nodePoolSize

        // Subtle random volume variation: ±15%
        let baseVolume: Float = 0.35
        let variation = Float.random(in: -0.05...0.05)
        player.volume = baseVolume + variation

        // Subtle random pitch variation: ±4%
        let rate = Float.random(in: 0.96...1.04)
        player.rate = rate

        // Ensure the node is playing before scheduling (restart if stopped)
        if !player.isPlaying {
            player.play()
        }

        // Schedule and play immediately
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    // MARK: - Teardown

    func stop() {
        for player in playerNodes {
            player.stop()
        }
        engine?.stop()
        isSetUp = false
        engine = nil
        mixer = nil
        playerNodes.removeAll()
        flapBuffer = nil
    }

    // MARK: - Sound Synthesis

    /// Synthesize a realistic split-flap click sound.
    ///
    /// The sound has three components layered together:
    /// 1. Sharp transient click (2-3ms) — the solenoid/mechanism release
    /// 2. Brief filtered noise flutter (15-25ms) — flap moving through air
    /// 3. Soft settle click (1-2ms) — flap hitting the stop
    ///
    /// The result is a warm, mechanical "tck" that sounds satisfying at low volume.
    private func synthesizeFlapSound(format: AVAudioFormat, sampleRate: Double) -> AVAudioPCMBuffer? {
        let totalDuration: Double = 0.055  // 55ms total
        let frameCount = AVAudioFrameCount(sampleRate * totalDuration)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData?[0] else { return nil }

        // Zero out
        for i in 0..<Int(frameCount) {
            channelData[i] = 0
        }

        // Component 1: Initial click transient (0-3ms)
        // Sharp bandpass-filtered impulse centered around 2.5kHz
        let clickEnd = Int(sampleRate * 0.003)
        for i in 0..<clickEnd {
            let t = Double(i) / sampleRate
            // Damped sine burst at ~2500Hz with harmonics
            let envelope = exp(-t * 1500) // Fast exponential decay
            let fundamental = sin(2 * Double.pi * 2500 * t)
            let harmonic1 = 0.4 * sin(2 * Double.pi * 5000 * t)
            let harmonic2 = 0.15 * sin(2 * Double.pi * 7500 * t)
            channelData[i] = Float((fundamental + harmonic1 + harmonic2) * envelope * 0.7)
        }

        // Component 2: Flutter/whoosh (3-35ms)
        // Filtered noise with bandpass around 1.5-3.5kHz, fast decay
        let flutterStart = clickEnd
        let flutterEnd = Int(sampleRate * 0.035)
        for i in flutterStart..<min(flutterEnd, Int(frameCount)) {
            let t = Double(i - flutterStart) / sampleRate
            let envelope = exp(-t * 120) * 0.15  // Gentler decay, lower amplitude
            // Filtered noise approximation using multiple sine waves at random-ish frequencies
            let noise = sin(2 * Double.pi * 1800 * t + 0.7)
                      + 0.6 * sin(2 * Double.pi * 2700 * t + 1.3)
                      + 0.3 * sin(2 * Double.pi * 3400 * t + 2.1)
                      + 0.4 * sin(2 * Double.pi * 1200 * t + 0.4)
            channelData[i] += Float(noise * envelope)
        }

        // Component 3: Settle click (at ~35ms, 2ms duration)
        // Softer secondary transient — the flap hitting its stop
        let settleStart = Int(sampleRate * 0.035)
        let settleEnd = Int(sampleRate * 0.038)
        for i in settleStart..<min(settleEnd, Int(frameCount)) {
            let t = Double(i - settleStart) / sampleRate
            let envelope = exp(-t * 2000) * 0.3  // Softer than initial click
            let fundamental = sin(2 * Double.pi * 2000 * t)  // Slightly lower pitch
            let harmonic = 0.3 * sin(2 * Double.pi * 4000 * t)
            channelData[i] += Float((fundamental + harmonic) * envelope)
        }

        // Component 4: Very subtle resonance tail (38-55ms)
        // Faint damped ring of the housing/enclosure
        let tailStart = Int(sampleRate * 0.038)
        for i in tailStart..<Int(frameCount) {
            let t = Double(i - tailStart) / sampleRate
            let envelope = exp(-t * 250) * 0.04
            let ring = sin(2 * Double.pi * 800 * t)
            channelData[i] += Float(ring * envelope)
        }

        // Apply a gentle high-pass to remove any DC offset / low rumble
        // Simple first-order high-pass at ~200Hz
        let rc = 1.0 / (2.0 * Double.pi * 200.0)
        let dt = 1.0 / sampleRate
        let alpha = Float(rc / (rc + dt))
        var prevIn: Float = 0
        var prevOut: Float = 0
        for i in 0..<Int(frameCount) {
            let input = channelData[i]
            let output = alpha * (prevOut + input - prevIn)
            channelData[i] = output
            prevIn = input
            prevOut = output
        }

        // Normalize peak to 0.8 to leave headroom
        var peak: Float = 0
        for i in 0..<Int(frameCount) {
            peak = max(peak, abs(channelData[i]))
        }
        if peak > 0 {
            let scale = 0.8 / peak
            for i in 0..<Int(frameCount) {
                channelData[i] *= scale
            }
        }

        return buffer
    }
}
