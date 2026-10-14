import AVFoundation

/// Short tones: a tick when it scans, a two-note chime when it's done reading.
final class Cues {
    private var players: [AVAudioPlayer] = []
    private lazy var tick: Data = Self.tone([(1046, 0, 0.06)])
    private lazy var chime: Data = Self.tone([(659, 0, 0.14), (988, 0.14, 0.22)])

    func capture(volume: Double) { play(tick, volume) }
    func done(volume: Double) { play(chime, volume) }

    private func play(_ data: Data, _ volume: Double) {
        guard let p = try? AVAudioPlayer(data: data) else { return }
        p.volume = Float(max(0.05, min(1, volume))) * 0.5
        p.play()
        players.append(p)
        players.removeAll { !$0.isPlaying && $0 !== p }
    }

    /// Builds a small 16-bit mono WAV in memory.
    private static func tone(_ notes: [(freq: Double, start: Double, dur: Double)]) -> Data {
        let rate = 22050.0
        let total = (notes.map { $0.start + $0.dur }.max() ?? 0.1) + 0.05
        let n = Int(total * rate)
        var samples = [Int16](repeating: 0, count: n)
        for note in notes {
            let s0 = Int(note.start * rate), len = Int(note.dur * rate)
            for k in 0..<len where s0 + k < n {
                let t = Double(k) / rate
                let attack = min(1, t / 0.012)
                let env = attack * exp(-4.5 * t / note.dur)
                let v = sin(2 * Double.pi * note.freq * t) * env * 0.6
                samples[s0 + k] = Int16(max(-1, min(1, v)) * 32000)
            }
        }
        var d = Data()
        func put32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); put32(UInt32(36 + n * 2))
        d.append(contentsOf: Array("WAVE".utf8)); d.append(contentsOf: Array("fmt ".utf8))
        put32(16); put16(1); put16(1); put32(UInt32(rate)); put32(UInt32(rate * 2)); put16(2); put16(16)
        d.append(contentsOf: Array("data".utf8)); put32(UInt32(n * 2))
        for s in samples { put16(UInt16(bitPattern: s)) }
        return d
    }
}
