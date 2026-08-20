import SwiftUI
import AppKit

extension Color {
    init(hex: String) {
        var sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    /// Round-trips with `init(hex:)` — used to persist a user-picked
    /// ColorPicker value (the goniometer's trace color) as a plain
    /// UserDefaults string, since Color itself isn't natively
    /// persistence-friendly.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(self)
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "%02x%02x%02x", r, g, b)
    }
}

/// Shared "something is happening" overlay, reused for both app-update
/// downloads and folder scan/convert progress — same radar-ping + alien
/// treatment and color palette as the Budget app, for series consistency.
/// Pass `progress` for a determinate bar, or leave it nil for just the
/// ping animation (indeterminate).
struct BusyOverlayView: View {
    var message: String = "Communicating with aliens…"
    var progress: Double? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var pingScale: [CGFloat] = [0.3, 0.3, 0.3]
    @State private var pingOpacity: [Double] = [0.6, 0.6, 0.6]

    private var bg: Color { colorScheme == .dark ? Color(hex: "2b2a28") : Color(hex: "fdfcf8") }
    private var fg: Color { colorScheme == .dark ? Color(hex: "fdfcf8") : Color(hex: "2b2a28") }
    private var track: Color { colorScheme == .dark ? Color(hex: "4a4844") : Color(hex: "e3e0d8") }
    private let accent = Color(hex: "4a90d9")

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(accent, lineWidth: 1.5)
                        .frame(width: 34, height: 34)
                        .scaleEffect(pingScale[i])
                        .opacity(pingOpacity[i])
                }
                Text("👽").font(.system(size: 22))
            }
            .frame(width: 60, height: 60)

            Text(message)
                .font(.system(size: 13))
                .foregroundColor(fg)

            if let progress {
                VStack(spacing: 6) {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(track).frame(width: 220, height: 8)
                        RoundedRectangle(cornerRadius: 4).fill(accent).frame(width: 220 * max(0, min(1, progress)), height: 8)
                    }
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11))
                        .foregroundColor(fg.opacity(0.7))
                }
            }
        }
        .padding(24)
        .background(bg)
        .onAppear(perform: startPinging)
    }

    private func startPinging() {
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.8) {
                animatePing(index: i)
            }
        }
    }

    private func animatePing(index: Int) {
        pingScale[index] = 0.3
        pingOpacity[index] = 0.6
        withAnimation(.easeOut(duration: 2.4)) {
            pingScale[index] = 2.2
            pingOpacity[index] = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            animatePing(index: index)
        }
    }
}
