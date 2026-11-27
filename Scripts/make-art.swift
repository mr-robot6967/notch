// Generates Islet's app icon (AppIcon_1024.png → AppIcon.icns via package-app.sh) and DMG artwork.
// Usage: swift Scripts/make-art.swift <output-dir>
import AppKit
import SwiftUI

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Lagoon palette
let night = Color(red: 0.03, green: 0.06, blue: 0.16)
let deep = Color(red: 0.05, green: 0.18, blue: 0.33)
let lagoon = Color(red: 0.06, green: 0.55, blue: 0.62)
let foam = Color(red: 0.55, green: 0.95, blue: 0.92)
let coral = Color(red: 1.00, green: 0.45, blue: 0.42)
let sun = Color(red: 1.00, green: 0.74, blue: 0.36)

/// The "islet": a glossy black island pill with a glowing art dot and waveform, floating on water.
struct IsletMark: View {
    var width: CGFloat
    var showRipples = true

    var body: some View {
        let height = width * 0.34
        ZStack {
            if showRipples {
                // Ripples under the island
                ForEach(0..<3, id: \.self) { i in
                    Ellipse()
                        .stroke(foam.opacity(0.32 - Double(i) * 0.09), lineWidth: width * 0.012)
                        .frame(width: width * (1.08 + CGFloat(i) * 0.22), height: height * (0.55 + CGFloat(i) * 0.22))
                        .offset(y: height * 0.78)
                }
                // Soft glow of the island on the water
                Ellipse()
                    .fill(RadialGradient(colors: [lagoon.opacity(0.7), .clear], center: .center, startRadius: 0, endRadius: width * 0.55))
                    .frame(width: width * 1.2, height: height * 0.9)
                    .offset(y: height * 0.72)
                    .blur(radius: width * 0.03)
            }
            // The island
            Capsule()
                .fill(LinearGradient(colors: [Color(white: 0.13), .black, .black], startPoint: .top, endPoint: .bottom))
                .frame(width: width, height: height)
                .overlay(
                    // Glass highlight on the top edge
                    Capsule()
                        .stroke(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05), .clear],
                                               startPoint: .top, endPoint: .bottom), lineWidth: width * 0.012)
                )
                .overlay(alignment: .leading) {
                    // Album-art dot
                    Circle()
                        .fill(LinearGradient(colors: [sun, coral], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: height * 0.62, height: height * 0.62)
                        .shadow(color: coral.opacity(0.9), radius: width * 0.03)
                        .padding(.leading, height * 0.19)
                }
                .overlay(alignment: .trailing) {
                    // Waveform
                    HStack(spacing: width * 0.022) {
                        ForEach([0.45, 0.85, 0.6, 1.0, 0.5], id: \.self) { level in
                            Capsule()
                                .fill(LinearGradient(colors: [foam, lagoon], startPoint: .top, endPoint: .bottom))
                                .frame(width: width * 0.028, height: height * 0.55 * level)
                        }
                    }
                    .shadow(color: foam.opacity(0.7), radius: width * 0.02)
                    .padding(.trailing, height * 0.32)
                }
                .shadow(color: .black.opacity(0.55), radius: width * 0.05, y: width * 0.03)
        }
    }
}

struct AppIcon: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 185, style: .continuous)
        ZStack {
            shape
                .fill(LinearGradient(colors: [night, deep, lagoon], startPoint: .top, endPoint: .bottom))
                .overlay(
                    // Light from above, like sun on a lagoon
                    RadialGradient(colors: [foam.opacity(0.28), .clear], center: UnitPoint(x: 0.5, y: 0.08),
                                   startRadius: 0, endRadius: 520)
                        .clipShape(shape)
                )
                .overlay(
                    // Gentle horizon band
                    LinearGradient(colors: [.clear, lagoon.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 220)
                        .offset(y: 150)
                        .blur(radius: 30)
                        .clipShape(shape)
                )
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.04)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 3))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            IsletMark(width: 560)
                .offset(y: -40)
                .mask(RoundedRectangle(cornerRadius: 185, style: .continuous).frame(width: 824, height: 824))
        }
        .frame(width: 1024, height: 1024)
    }
}

struct DMGBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [night, deep, lagoon.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [foam.opacity(0.14), .clear], center: .init(x: 0.5, y: 0.0), startRadius: 0, endRadius: 420)
            VStack(spacing: 8) {
                IsletMark(width: 92, showRipples: false)
                Text("Notch").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text("Your notch and lock screen, alive")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
            }
            .padding(.top, 26)
            // Finder places the icons at x=170 and x=490, y=230 (centre).
            Image(systemName: "arrow.right")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
                .position(x: 330, y: 230)
            Text("Drag Notch to Applications")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .position(x: 330, y: 365)
        }
        .frame(width: 660, height: 400)
    }
}

@MainActor
func png<V: View>(_ view: V, scale: CGFloat, to url: URL) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let cg = renderer.cgImage,
          let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
        fatalError("render failed: \(url.lastPathComponent)")
    }
    try! data.write(to: url)
    print("wrote \(url.path)")
}

MainActor.assumeIsolated {
    png(AppIcon(), scale: 1, to: outDir.appendingPathComponent("AppIcon_1024.png"))
    png(DMGBackground(), scale: 1, to: outDir.appendingPathComponent("dmg-background.png"))
    png(DMGBackground(), scale: 2, to: outDir.appendingPathComponent("dmg-background@2x.png"))
}
