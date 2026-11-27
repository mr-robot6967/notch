// Synthesizes Islet's lock / unlock sounds (original, iPhone-like "latch" clicks) as WAV files.
// Usage: swift Scripts/make-sounds.swift <output-dir>
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let rate = 44_100.0

/// Deterministic noise so the sounds are identical on every build.
var seed: UInt64 = 0x1234_5678
func noise() -> Double {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Double(Int64(bitPattern: seed >> 11) % 2_000_000) / 1_000_000.0 - 1.0
}

/// One mechanical click: a filtered noise transient plus a short resonant body.
func click(into buffer: inout [Double], at time: Double, gain: Double, body: Double, bodyDecay: Double,
           brightness: Double, noiseDecay: Double) {
    let start = Int(time * rate)
    let length = Int(0.09 * rate)
    var lowpass = 0.0
    for i in 0..<length where start + i < buffer.count {
        let t = Double(i) / rate
        let attack = min(1, t / 0.0006)
        // Noise transient, low-passed by `brightness` (0...1, higher = brighter).
        lowpass += brightness * (noise() - lowpass)
        let tick = lowpass * exp(-t / noiseDecay)
        // Resonant body that gives the click its "clack".
        let tone = sin(2 * .pi * body * t) * exp(-t / bodyDecay)
        let tone2 = sin(2 * .pi * body * 2.71 * t) * exp(-t / (bodyDecay * 0.5)) * 0.35
        buffer[start + i] += gain * attack * (0.9 * tick + 0.55 * tone + tone2)
    }
}

func writeWAV(_ samples: [Double], to url: URL) {
    let peak = samples.map(abs).max() ?? 1
    let scale = 0.85 / max(peak, 0.0001)
    var pcm = Data()
    for s in samples {
        var v = Int16(max(-1, min(1, s * scale)) * Double(Int16.max)).littleEndian
        withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
    }
    func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    var wav = Data("RIFF".utf8) + u32(UInt32(36 + pcm.count)) + Data("WAVE".utf8)
    wav += Data("fmt ".utf8) + u32(16) + u16(1) + u16(1) + u32(UInt32(rate)) + u32(UInt32(rate) * 2) + u16(2) + u16(16)
    wav += Data("data".utf8) + u32(UInt32(pcm.count)) + pcm
    try! wav.write(to: url)
    print("wrote \(url.path)")
}

// Lock: a crisp, short two-stage latch — bright "tk-tk".
var lock = [Double](repeating: 0, count: Int(0.14 * rate))
click(into: &lock, at: 0.000, gain: 1.0, body: 1250, bodyDecay: 0.006, brightness: 0.85, noiseDecay: 0.0022)
click(into: &lock, at: 0.026, gain: 0.8, body: 820, bodyDecay: 0.008, brightness: 0.7, noiseDecay: 0.0028)
writeWAV(lock, to: outDir.appendingPathComponent("lock.wav"))

// Unlock: a softer, lower single "tock".
var unlock = [Double](repeating: 0, count: Int(0.12 * rate))
click(into: &unlock, at: 0.000, gain: 1.0, body: 640, bodyDecay: 0.009, brightness: 0.55, noiseDecay: 0.003)
writeWAV(unlock, to: outDir.appendingPathComponent("unlock.wav"))
