import SwiftUI

struct HomeView: View {
    @State private var detail = Hooks.string("detail").map { DetailID(id: $0) }
    @State private var settings = Hooks.string("settings") != nil

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(ha.home) { sec in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(sec.name).font(.title3.bold()).padding(.leading, 4)
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                                ForEach(sec.tiles) { t in TileView(t: t) { detail = DetailID(id: t.id) } }
                            }
                        }
                    }
                }
                .padding(16)
                .opacity(ha.connected ? 1 : 0.55)
                .allowsHitTesting(ha.connected)
            }
            .overlay { if ha.home.isEmpty && ha.connected { ContentUnavailableView("No devices", systemImage: "house") } }
            .safeAreaInset(edge: .top, spacing: 0) { Banner() }
            .navigationTitle("Home")
            .toolbar { Button("Settings", systemImage: "gearshape") { settings = true } }
            .sheet(isPresented: $settings) { SettingsView() }
            .sheet(item: $detail) { d in
                // the color wheel needs the full height
                let color = !Set(ha.tile(d.id)?.modes ?? []).isDisjoint(with: ["hs", "rgb", "rgbw", "rgbww", "xy"])
                DetailSheet(id: d.id).presentationDetents(color ? [.large] : [.medium])
            }
            .alert(ha.unlockAsk.map { "Unlock \($0.name)?" } ?? "", isPresented: Binding { ha.unlockAsk != nil } set: { if !$0 { ha.unlockAsk = nil } }) {
                Button("Unlock", role: .destructive) { if let t = ha.unlockAsk { ha.unlock(t) } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

struct DetailID: Identifiable { var id: String }

/// "Connecting…" / "Can't reach Home Assistant" (tap retries) while not connected.
struct Banner: View {
    var body: some View {
        if !ha.connected {
            Button { ha.reconnect() } label: {
                HStack(spacing: 8) {
                    if ha.conn == .connecting { ProgressView().controlSize(.small) } else { Image(systemName: "wifi.exclamationmark") }
                    Text(ha.conn == .connecting ? "Connecting…" : "Can't reach Home Assistant")
                }
                .font(.footnote.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.plain).background(.bar, ignoresSafeAreaEdges: [])
        }
    }
}

struct TileView: View {
    let t: Tile
    let details: () -> Void

    var body: some View {
        let on = Self.isOn(t)
        let tint = Self.tint(t)
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: Self.icon(t)).font(.title2).foregroundStyle(on ? tint : .secondary).frame(height: 28)
            Text(t.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(Ha.stateText(t)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(on ? AnyShapeStyle(tint.opacity(0.22)) : AnyShapeStyle(.fill.tertiary), in: .rect(cornerRadius: 18))
        .overlay { if ha.flashing == t.id { RoundedRectangle(cornerRadius: 18).fill(.tint.opacity(0.35)) } }
        .opacity(t.unavailable ? 0.45 : 1)
        .contentShape(.rect(cornerRadius: 18))
        .onTapGesture { ha.tap(t) }
        .onLongPressGesture { if Self.hasDetails(t) { details() } }
        .animation(.easeOut(duration: 0.2), value: ha.flashing == t.id)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Details") { if Self.hasDetails(t) { details() } }
        .accessibilityIdentifier(t.id)
    }

    static func hasDetails(_ t: Tile) -> Bool { !t.unavailable && ["light", "fan", "cover"].contains(t.domain) }

    static func isOn(_ t: Tile) -> Bool {
        ["on", "open", "opening", "unlocked", "jammed"].contains(t.s) && !t.stateless
    }

    static func tint(_ t: Tile) -> Color {
        if t.domain == "light" {
            // white-ish colors would vanish on a light background: amber instead
            guard let c = t.rgb, c.count == 3, (c.max() ?? 0) - (c.min() ?? 0) > 40 else { return .orange }
            return Color(red: Double(c[0]) / 255, green: Double(c[1]) / 255, blue: Double(c[2]) / 255)
        }
        if t.domain == "lock" { return t.s == "jammed" ? .red : .orange }
        return .accentColor
    }

    static func icon(_ t: Tile) -> String {
        switch t.domain {
        case "light": t.s == "on" ? "lightbulb.fill" : "lightbulb"
        case "switch", "input_boolean": t.s == "on" ? "power.circle.fill" : "power.circle"
        case "fan": "fan.fill"
        case "cover": ["open", "opening"].contains(t.s) ? "blinds.horizontal.open" : "blinds.horizontal.closed"
        case "lock": t.s == "locked" ? "lock.fill" : t.s == "jammed" ? "lock.trianglebadge.exclamationmark.fill" : "lock.open.fill"
        case "button", "input_button": "button.programmable"
        case "scene": "sparkles"
        case "script": "scroll"
        default: "circle"
        }
    }
}

/// Long-press sheet for lights, fans and covers.
struct DetailSheet: View {
    let id: String

    var body: some View {
        NavigationStack {
            if let t = ha.tile(id) {
                Form {
                    switch t.domain {
                    case "cover": cover(t)
                    default:
                        Toggle("On", isOn: Binding { t.s == "on" } set: { on in
                            ha.service(id, t.domain, on ? "turn_on" : "turn_off", optimistic: on ? "on" : "off")
                        })
                        if t.domain == "light" { light(t) }
                        if t.domain == "fan", t.features & 1 != 0 {
                            SendSlider(label: "Speed", value: Double(t.percentage ?? 0), range: 0...100, unit: "%") {
                                ha.service(id, "fan", "set_percentage", ["percentage": Int($0)])
                            }
                        }
                    }
                }
                .navigationTitle(t.name).navigationBarTitleDisplayMode(.inline)
                .disabled(!ha.connected)
            }
        }
    }

    @ViewBuilder private func light(_ t: Tile) -> some View {
        let modes = Set(t.modes ?? [])
        if !modes.subtracting(["onoff"]).isEmpty {
            SendSlider(label: "Brightness", value: Double(t.brightness ?? 0) / 255 * 100, range: 1...100, unit: "%") {
                ha.service(id, "light", "turn_on", ["brightness_pct": Int($0)])
            }
        }
        if modes.contains("color_temp"), let lo = t.minK, let hi = t.maxK, lo < hi {
            SendSlider(label: "Warmth", value: Double(t.kelvin ?? (lo + hi) / 2), range: Double(lo)...Double(hi), unit: "K",
                       track: LinearGradient(colors: [Color(red: 1, green: 0.64, blue: 0.29), Color(red: 1, green: 0.95, blue: 0.88),
                                                      Color(red: 0.81, green: 0.87, blue: 1)], startPoint: .leading, endPoint: .trailing)) {
                ha.service(id, "light", "turn_on", ["color_temp_kelvin": Int($0)])
            }
        }
        if !modes.isDisjoint(with: ["hs", "rgb", "rgbw", "rgbww", "xy"]) {
            let hs = t.hs ?? []
            Wheel(hue: hs.first ?? 0, sat: hs.count > 1 ? hs[1] : 0) { h, s in
                ha.service(id, "light", "turn_on", ["hs_color": [Int(h.rounded()), Int(s.rounded())]])
            }
        }
    }

    @ViewBuilder private func cover(_ t: Tile) -> some View {
        HStack {
            Button("Open", systemImage: "arrow.up") { ha.service(id, "cover", "open_cover") }
            Spacer()
            Button("Stop", systemImage: "stop.fill") { ha.service(id, "cover", "stop_cover") }
            Spacer()
            Button("Close", systemImage: "arrow.down") { ha.service(id, "cover", "close_cover") }
        }
        .buttonStyle(.bordered).labelStyle(.iconOnly).font(.title3)
        if t.features & 4 != 0 {
            SendSlider(label: "Position", value: Double(t.position ?? 0), range: 0...100, unit: "%") {
                ha.service(id, "cover", "set_cover_position", ["position": Int($0)])
            }
        }
    }
}

/// A slider that sends on release and at most every 300 ms while dragging; follows the live value otherwise.
struct SendSlider: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let unit: String
    var track: LinearGradient? = nil
    let send: (Double) -> Void
    @State private var drag: Double?
    @State private var lastSent = Date.distantPast
    @State private var editing = false

    var body: some View {
        let shown = drag ?? min(max(value, range.lowerBound), range.upperBound)
        VStack(alignment: .leading) {
            LabeledContent(label, value: "\(Int(shown.rounded()))\(unit)")
            Group {
                if let track { // a gradient bar instead of the system track
                    GeometryReader { g in
                        let w = g.size.width - 28
                        Capsule().fill(track).frame(height: 16).frame(maxHeight: .infinity)
                            .overlay(alignment: .leading) {
                                Circle().fill(.white).frame(width: 28, height: 28).shadow(radius: 2)
                                    .offset(x: (shown - range.lowerBound) / (range.upperBound - range.lowerBound) * w)
                            }
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { e in
                                    editing = true
                                    set(range.lowerBound + min(max((e.location.x - 14) / w, 0), 1) * (range.upperBound - range.lowerBound))
                                }
                                .onEnded { _ in end() })
                    }
                    .frame(height: 32)
                    .accessibilityElement().accessibilityValue("\(Int(shown.rounded()))\(unit)")
                    .accessibilityAdjustableAction { dir in
                        let step = (range.upperBound - range.lowerBound) / 10
                        set(min(max(shown + (dir == .increment ? step : -step), range.lowerBound), range.upperBound)); end()
                    }
                } else {
                    Slider(value: Binding(get: { shown }, set: set), in: range) { e in
                        editing = e
                        if !e { end() }
                    }
                }
            }
            .accessibilityIdentifier(label)
            .onChange(of: value) { if !editing { drag = nil } }
        }
    }

    private func set(_ v: Double) {
        drag = v
        if Date.now.timeIntervalSince(lastSent) >= 0.3 { lastSent = .now; send(v) }
    }

    /// Keeps showing the dragged value until the live value moves.
    private func end() {
        editing = false
        if let d = drag { send(d); lastSent = .now }
    }
}

/// Hue/saturation wheel: angle = hue (clockwise from red at 3 o'clock), distance from the center = saturation.
/// Sends like SendSlider.
struct Wheel: View {
    let hue: Double
    let sat: Double
    let send: (Double, Double) -> Void
    static let hues = (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) }
    @State private var drag: [Double]?
    @State private var lastSent = Date.distantPast
    @State private var editing = false

    var body: some View {
        let (h, s) = drag.map { ($0[0], $0[1]) } ?? (hue, min(max(sat, 0), 100))
        VStack(alignment: .leading) {
            Text("Color")
            GeometryReader { g in
                let r: Double = min(g.size.width, g.size.height) / 2
                let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
                let a: Double = h * .pi / 180, d: Double = r * s / 100
                ZStack {
                    Circle().fill(AngularGradient(colors: Self.hues, center: .center))
                    Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: r))
                    Circle().fill(Color(hue: h / 360, saturation: s / 100, brightness: 1)).frame(width: 28, height: 28)
                        .overlay(Circle().stroke(.white, lineWidth: 3)).shadow(radius: 2)
                        .position(x: c.x + cos(a) * d, y: c.y + sin(a) * d)
                }
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { e in
                        editing = true
                        let dx = e.location.x - c.x, dy = e.location.y - c.y
                        let v = [(atan2(dy, dx) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360), min(hypot(dx, dy) / r, 1) * 100]
                        drag = v
                        if Date.now.timeIntervalSince(lastSent) >= 0.3 { lastSent = .now; send(v[0], v[1]) }
                    }
                    .onEnded { _ in
                        editing = false
                        if let d = drag { send(d[0], d[1]); lastSent = .now }
                    })
            }
            .aspectRatio(1, contentMode: .fit).frame(maxWidth: 260).frame(maxWidth: .infinity).padding(.vertical, 8)
            .accessibilityElement().accessibilityLabel("Color").accessibilityValue("Hue \(Int(h)) degrees, saturation \(Int(s)) percent")
            .accessibilityIdentifier("wheel")
        }
        .onChange(of: hue) { if !editing { drag = nil } }
        .onChange(of: sat) { if !editing { drag = nil } }
    }
}
