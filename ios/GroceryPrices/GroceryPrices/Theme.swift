import SwiftUI
import UIKit

// The look: a grocery flyer. Newsprint paper, black ink, yellow price tags with
// flyer-style cents, New York serif for names and SF Mono for the small print.

private func rgb(_ hex: UInt32) -> UIColor {
    UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

extension Color {
    init(_ light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) })
    }

    static let paper = Color(0xF3EEE2, dark: 0x141511)
    static let card = Color(0xFBF8F1, dark: 0x1F201B)
    static let ink = Color(0x1B1D17, dark: 0xF1ECDF)
    static let inkSoft = Color(0x5F5C52, dark: 0xB4AF9F)
    static let rule = Color(0xDDD6C5, dark: 0x34352E)
    static let tag = Color(uiColor: rgb(0xFFD21F))       // flyer yellow, both modes
    static let tagInk = Color(uiColor: rgb(0x1B1D17))    // text on the tag, both modes
    static let deal = Color(uiColor: rgb(0xD23A26))      // flyer red, for sale badges
    static let cheaper = Color(0x006300, dark: 0x0CA30C)
    static let pricier = Color(0xC43333, dark: 0xE66767)

    // Chart colour per store: the dataviz reference palette, light and dark steps,
    // validated in this order against .card for colour-blind separation.
    private static let storeHues: [(UInt32, UInt32)] = [
        (0x2A78D6, 0x3987E5), (0xEB6834, 0xD95926), (0x1BAF7A, 0x199E70), (0xEDA100, 0xC98500),
        (0xE87BA4, 0xD55181), (0x008300, 0x0CA30C), (0x6250D6, 0x9085E9), (0xE34948, 0xE66767),
    ]

    /// A store's colour, by its place among every store in the data so it's the same on every screen.
    // ponytail: past 8 stores the rest share gray; fold them into "Other" if that ever happens.
    static func store(_ name: String, among stores: [String]) -> Color {
        guard let i = stores.firstIndex(of: name), i < storeHues.count else { return .inkSoft }
        return Color(storeHues[i].0, dark: storeHues[i].1)
    }
}

extension Font {
    /// Flyer numerals: SF Compressed Black.
    static func price(_ style: TextStyle) -> Font { .system(style, weight: .black).width(.compressed) }
    /// The small print: SF Mono.
    static func label(_ style: TextStyle = .caption) -> Font { .system(style, design: .monospaced, weight: .medium) }
    /// Item and product names: New York.
    static func name(_ style: TextStyle) -> Font { .system(style, design: .serif, weight: .semibold) }
}

/// Small-caps style caption: mono, uppercase, spaced out.
struct Kicker: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.label(.caption2)).tracking(1.2).foregroundStyle(Color.inkSoft)
    }
}

/// A price the way flyers print it: big dollars, small raised cents, the unit under the cents.
struct FlyerPrice: View {
    let amount: Double
    var per: String?  // kg, lb, L, dozen, each
    var size: Font.TextStyle = .largeTitle

    private var unit: String? {
        switch per {
        case nil: nil
        case "each": "EA"
        case "dozen": "/DOZ"
        case let p?: "/" + p.uppercased()
        }
    }

    var body: some View {
        let cents = Int((amount * 100).rounded())
        // ponytail: "$" up front assumes an English-Canadian locale, like the rest of the app's copy.
        HStack(alignment: .top, spacing: 1) {
            Text("$").font(.price(size == .largeTitle ? .title3 : .caption)).padding(.top, 2)
            Text("\(cents / 100)").font(.price(size))
            VStack(alignment: .leading, spacing: -1) {
                Text(String(format: "%02d", cents % 100))
                    .font(.price(size == .largeTitle ? .title2 : .subheadline))
                if let unit { Text(unit).font(.label(.caption2)).fontWeight(.bold) }
            }
            .padding(.top, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(amount.formatted(.currency(code: "CAD")) + (per.map { $0 == "each" ? " each" : " per \($0)" } ?? ""))
    }
}

/// The yellow tag behind the best price, with a hard printed shadow.
struct TagStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color.tagInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.tag, in: .rect(cornerRadius: 3))
            .background(Color.ink, in: .rect(cornerRadius: 3).offset(x: 3, y: 3))
    }
}

extension View {
    func priceTag() -> some View { modifier(TagStyle()) }

    /// Paper background behind a List or Form.
    func paper() -> some View { scrollContentBackground(.hidden).background(Color.paper) }
}

/// A store name with its chart colour, so colour never carries the store alone.
struct StoreDot: View {
    let name: String
    let stores: [String]
    var body: some View {
        Circle().fill(Color.store(name, among: stores)).frame(width: 8, height: 8)
    }
}

/// A horizontal dashed line, like the perforations on a receipt.
struct Perforation: View {
    var body: some View {
        Line().stroke(Color.inkSoft.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(height: 1)
    }

    private struct Line: Shape {
        func path(in r: CGRect) -> Path {
            Path { $0.move(to: CGPoint(x: r.minX, y: r.midY)); $0.addLine(to: CGPoint(x: r.maxX, y: r.midY)) }
        }
    }
}

/// A receipt: a rectangle with torn, saw-tooth top and bottom edges.
struct ReceiptShape: Shape {
    var tooth: CGFloat = 12
    var depth: CGFloat = 5

    func path(in r: CGRect) -> Path {
        let n = max(1, Int(r.width / tooth)), w = r.width / CGFloat(n)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + depth))
        for i in 0..<n {  // top edge, left to right
            let x = r.minX + CGFloat(i) * w
            p.addLine(to: CGPoint(x: x + w / 2, y: r.minY))
            p.addLine(to: CGPoint(x: x + w, y: r.minY + depth))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - depth))
        for i in 0..<n {  // bottom edge, right to left
            let x = r.maxX - CGFloat(i) * w
            p.addLine(to: CGPoint(x: x - w / 2, y: r.maxY))
            p.addLine(to: CGPoint(x: x - w, y: r.maxY - depth))
        }
        p.closeSubpath()
        return p
    }
}
