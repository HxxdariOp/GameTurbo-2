import SwiftUI

// MARK: - Colors

extension Color {
    static let accentOrange = Color(red: 1.0, green: 0.56, blue: 0.10)
    static let deepOrange = Color(red: 0.96, green: 0.36, blue: 0.02)
    static let amber = Color(red: 1.0, green: 0.76, blue: 0.25)
    static let inkBlack = Color(red: 0.035, green: 0.035, blue: 0.045)
    static let okGreen = Color(red: 0.32, green: 0.86, blue: 0.52)
    static let badRed = Color(red: 1.0, green: 0.34, blue: 0.32)
    static let coolBlue = Color(red: 0.35, green: 0.70, blue: 1.0)
}

// MARK: - Formatting

extension String {
    var fa: String {
        let m: [Character: Character] = ["0": "۰", "1": "۱", "2": "۲", "3": "۳", "4": "۴",
                                          "5": "۵", "6": "۶", "7": "۷", "8": "۸", "9": "۹"]
        return String(self.map { m[$0] ?? $0 })
    }
}

func fnum(_ v: Int) -> String { String(v).fa }

func fmtPct(_ v: Double, _ d: Int = 0) -> String {
    guard v.isFinite else { return "—" }
    return (String(format: "%.\(d)f", v) + "٪").fa
}

func fmtBytes(_ b: UInt64) -> String {
    let gb = Double(b) / 1_073_741_824
    if gb >= 1 { return String(format: "%.2f GB", gb).fa }
    let mb = Double(b) / 1_048_576
    if mb >= 1 { return String(format: "%.0f MB", mb).fa }
    return String(format: "%.0f KB", Double(b) / 1024).fa
}

func fmtDuration(_ t: TimeInterval) -> String {
    let s = Int(t)
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(fnum(d)) روز و \(fnum(h)) ساعت" }
    if h > 0 { return "\(fnum(h)) ساعت و \(fnum(m)) دقیقه" }
    return "\(fnum(m)) دقیقه"
}

// MARK: - Background & glass

/// Heavy effects (materials, blur, shadows) are expensive on older GPUs; they are opt-in.
enum Fx {
    static var fancy: Bool = UserDefaults.standard.bool(forKey: "fancy")
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            Color.inkBlack
            if Fx.fancy {
                Circle().fill(Color.deepOrange.opacity(0.5)).frame(width: 360, height: 360)
                    .blur(radius: 90).offset(x: 140, y: -300)
                Circle().fill(Color.accentOrange.opacity(0.3)).frame(width: 300, height: 300)
                    .blur(radius: 90).offset(x: -150, y: 260)
            } else {
                RadialGradient(colors: [Color.deepOrange.opacity(0.38), Color.clear],
                               center: .topTrailing, startRadius: 0, endRadius: 460)
                RadialGradient(colors: [Color.accentOrange.opacity(0.24), Color.clear],
                               center: .bottomLeading, startRadius: 0, endRadius: 420)
            }
        }
        .ignoresSafeArea()
    }
}

struct GlassCard: ViewModifier {
    var radius: CGFloat
    var tint: Color?
    var pad: CGFloat

    func body(content: Content) -> some View {
        if Fx.fancy {
            content
                .padding(pad)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.ultraThinMaterial)
                        if let tint {
                            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tint.opacity(0.14))
                        }
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.02)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.45), Color.white.opacity(0.05), Color.accentOrange.opacity(0.28)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 8)
        } else {
            content
                .padding(pad)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(0.07))
                        if let tint {
                            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tint.opacity(0.12))
                        }
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(LinearGradient(colors: [Color.white.opacity(0.08), Color.white.opacity(0.0)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.30), Color.white.opacity(0.06)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                )
        }
    }
}

extension View {
    func glass(radius: CGFloat = 22, tint: Color? = nil, pad: CGFloat = 16) -> some View {
        modifier(GlassCard(radius: radius, tint: tint, pad: pad))
    }
}

struct GlassButtonStyle: ButtonStyle {
    var prominent = false
    var danger = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.bold())
            .foregroundColor(prominent ? Color.black : (danger ? Color.badRed : Color.white))
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(
                Group {
                    if prominent {
                        Capsule().fill(LinearGradient(colors: [Color.amber, Color.accentOrange, Color.deepOrange],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                    } else {
                        Capsule().fill(Color.white.opacity(0.10))
                    }
                }
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.24), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

struct GlassIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.bold())
            .foregroundColor(Color.accentOrange)
            .frame(width: 38, height: 38)
            .background(Circle().fill(Color.white.opacity(0.10)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.24), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
    }
}

// MARK: - Components

struct Pill: View {
    let text: String
    var color: Color = Color.accentOrange
    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18))
            .clipShape(Capsule())
    }
}

struct ChipToggle: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.bold())
                .foregroundColor(isOn ? Color.black : Color.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isOn ? Color.accentOrange : Color.white.opacity(0.1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.footnote.bold())
            .foregroundColor(Color.accentOrange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
    }
}

struct RingProgress: View {
    let progress: Double
    var lineWidth: CGFloat = 10
    var colors: [Color] = [Color.amber, Color.accentOrange, Color.deepOrange, Color.amber]
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(progress, 0), 1)))
                .stroke(AngularGradient(colors: colors, center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var color: Color = Color.accentOrange
    var maxV: Double = 100

    var body: some View {
        GeometryReader { g in
            let pts = points(g.size)
            ZStack {
                Path { p in
                    guard let first = pts.first, let last = pts.last else { return }
                    p.move(to: CGPoint(x: first.x, y: g.size.height))
                    p.addLine(to: first)
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                    p.addLine(to: CGPoint(x: last.x, y: g.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }

    func points(_ size: CGSize) -> [CGPoint] {
        let n = max(values.count - 1, 1)
        var out: [CGPoint] = []
        for (i, v) in values.enumerated() {
            let x = size.width * CGFloat(i) / CGFloat(n)
            let y = size.height * (1 - CGFloat(min(max(v / maxV, 0), 1)))
            out.append(CGPoint(x: x, y: y))
        }
        return out
    }
}

struct GlassSection<Content: View>: View {
    let title: String?
    let content: Content
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { SectionTitle(text: title) }
            VStack(alignment: .leading, spacing: 10) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glass(radius: 20)
        }
    }
}

struct InfoRow: View {
    let title: String
    let value: String
    var color: Color = Color.white
    var body: some View {
        HStack {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value).font(.subheadline.bold()).foregroundColor(color).multilineTextAlignment(.trailing)
        }
    }
}

struct StatTile: View {
    let icon: String
    let title: String
    let value: String
    var tint: Color = Color.accentOrange
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.title3).foregroundColor(tint)
            Text(value).font(.subheadline.bold()).minimumScaleFactor(0.6).lineLimit(1)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(radius: 20, pad: 14)
    }
}

struct EmptyState: View {
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 38)).foregroundColor(Color.accentOrange.opacity(0.8))
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .glass()
    }
}

struct SheetScaffold<Content: View>: View {
    let title: String
    let content: Content
    @Environment(\.presentationMode) private var presentation

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Button("بستن") { presentation.wrappedValue.dismiss() }
                        .buttonStyle(GlassButtonStyle())
                }
                .padding()
                ScrollView {
                    VStack(spacing: 14) { content }
                        .padding(.horizontal)
                        .padding(.bottom, 40)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
