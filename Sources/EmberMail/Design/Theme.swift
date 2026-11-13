import SwiftUI

enum Theme {
    /// Ember orange — the brand accent.
    static let accent = Color(red: 0.89, green: 0.40, blue: 0.18)
    /// Deep oak brown, used in gradients.
    static let oak = Color(red: 0.36, green: 0.22, blue: 0.13)

    static let accountColors: [Color] = [
        accent,
        Color(red: 0.20, green: 0.48, blue: 0.95),
        Color(red: 0.18, green: 0.65, blue: 0.45),
        Color(red: 0.55, green: 0.36, blue: 0.86),
        Color(red: 0.90, green: 0.30, blue: 0.50),
        Color(red: 0.10, green: 0.62, blue: 0.70),
    ]

    static func accountColor(_ index: Int) -> Color {
        accountColors[((index % accountColors.count) + accountColors.count) % accountColors.count]
    }

    private static let avatarPalette: [(Color, Color)] = [
        (Color(red: 0.98, green: 0.55, blue: 0.30), Color(red: 0.87, green: 0.32, blue: 0.16)),
        (Color(red: 0.40, green: 0.62, blue: 1.00), Color(red: 0.22, green: 0.40, blue: 0.90)),
        (Color(red: 0.36, green: 0.80, blue: 0.58), Color(red: 0.15, green: 0.58, blue: 0.42)),
        (Color(red: 0.74, green: 0.52, blue: 0.98), Color(red: 0.50, green: 0.30, blue: 0.86)),
        (Color(red: 1.00, green: 0.50, blue: 0.62), Color(red: 0.86, green: 0.26, blue: 0.44)),
        (Color(red: 0.32, green: 0.78, blue: 0.84), Color(red: 0.10, green: 0.54, blue: 0.66)),
        (Color(red: 0.95, green: 0.74, blue: 0.30), Color(red: 0.84, green: 0.52, blue: 0.10)),
        (Color(red: 0.62, green: 0.56, blue: 0.52), Color(red: 0.42, green: 0.36, blue: 0.32)),
    ]

    static func avatarGradient(for seed: String) -> LinearGradient {
        var hash: UInt64 = 5381
        for b in seed.lowercased().utf8 { hash = (hash &* 33) &+ UInt64(b) }
        let pair = avatarPalette[Int(hash % UInt64(avatarPalette.count))]
        return LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r, g, b: Double
        if s.count == 3 {
            r = Double((value >> 8) & 0xF) / 15; g = Double((value >> 4) & 0xF) / 15; b = Double(value & 0xF) / 15
        } else {
            r = Double((value >> 16) & 0xFF) / 255; g = Double((value >> 8) & 0xFF) / 255; b = Double(value & 0xFF) / 255
        }
        self.init(red: r, green: g, blue: b)
    }
}

struct AvatarView: View {
    let address: EmailAddress
    var size: CGFloat = 34

    private var initials: String {
        let source = address.name ?? address.email.components(separatedBy: "@").first ?? "?"
        let words = source.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    var body: some View {
        Circle()
            .fill(Theme.avatarGradient(for: address.email))
            .frame(width: size, height: size)
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}

/// Small rounded label, used for status pills.
struct Pill: View {
    let text: String
    var symbol: String?
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.13), in: Capsule())
    }
}

enum Format {
    static func listDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if cal.component(.year, from: date) == cal.component(.year, from: Date()) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    static func fullDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute())
    }

    static func relative(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func timeRange(_ event: CalendarEvent) -> String {
        if event.isAllDay { return "All day" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }
}
