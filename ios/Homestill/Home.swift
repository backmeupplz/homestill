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
                // the color wheel, the long media/climate sheets and the alarm's number pad need the full height
                let t = ha.tile(d.id)
                let color = !Set(t?.modes ?? []).isDisjoint(with: ["hs", "rgb", "rgbw", "rgbww", "xy"])
                let tall = color || ["climate", "media_player", "alarm_control_panel"].contains(t?.domain ?? "")
                DetailSheet(id: d.id).presentationDetents(tall ? [.large] : [.medium])
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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let action = Ha.tapAction(t)
        if action == .menu { // selects: a menu of options, no sheet (a clear menu on top: as a Menu label the card draws darker)
            card.overlay {
                Menu {
                    Picker(t.name, selection: Binding<String> { t.s } set: { o in ha.service(t.id, t.domain, "select_option", ["option": o], optimistic: o) }) {
                        ForEach(t.strs("options"), id: \.self) { Text($0).tag($0) }
                    }
                } label: { Color.clear.contentShape(.rect) }
                .accessibilityLabel("\(t.name), \(Ha.stateText(t))")
                .accessibilityIdentifier(t.id)
            }
        } else {
            card
                .onTapGesture { if action == .sheet { details() } else { ha.tap(t) } }
                .onLongPressGesture { if Self.hasDetails(t) { details() } }
                .accessibilityAddTraits(action == .none ? [] : .isButton)
                .accessibilityAction(named: "Details") { if Self.hasDetails(t) { details() } }
                .accessibilityIdentifier(t.id)
        }
    }

    private var card: some View {
        let on = Ha.active(t)
        let tint = Self.tint(t)
        return VStack(alignment: .leading, spacing: 6) {
            Image(systemName: Self.icon(t)).font(.title2).foregroundStyle(on ? Self.legible(tint, dark: scheme == .dark) : .secondary).frame(height: 28)
            Text(t.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(Ha.stateText(t)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(on ? AnyShapeStyle(tint.opacity(0.22)) : AnyShapeStyle(.fill.tertiary), in: .rect(cornerRadius: 18))
        .overlay { if ha.flashing == t.id { RoundedRectangle(cornerRadius: 18).fill(.tint.opacity(0.35)) } }
        .opacity(t.unavailable ? 0.45 : 1)
        .contentShape(.rect(cornerRadius: 18))
        .animation(.easeOut(duration: 0.2), value: ha.flashing == t.id)
        .accessibilityElement(children: .combine)
    }

    static let sheetDomains: Set = ["light", "fan", "cover", "siren", "valve", "climate", "water_heater", "humidifier", "media_player",
                                    "vacuum", "lawn_mower", "alarm_control_panel", "number", "input_number"]
    static func hasDetails(_ t: Tile) -> Bool { !t.unavailable && sheetDomains.contains(t.domain) }

    static func tint(_ t: Tile) -> Color {
        switch t.domain {
        case "light":
            // white-ish colors would vanish on a light background: amber instead
            guard let c = t.rgb, c.count == 3, (c.max() ?? 0) - (c.min() ?? 0) > 40 else { return .orange }
            return Color(red: Double(c[0]) / 255, green: Double(c[1]) / 255, blue: Double(c[2]) / 255)
        case "lock": return t.s == "jammed" ? .red : .orange
        case "alarm_control_panel": return t.s == "triggered" ? .red : .accentColor
        default: return .accentColor
        }
    }

    /// `c` blended toward the text color just enough to stand out 3:1 (the WCAG minimum for icons) from the card: `c` at
    /// 22% over the page.
    static func legible(_ c: Color, dark: Bool) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        let rgb = [r, g, b].map { min(max($0, 0), 1) }, page: CGFloat = dark ? 0 : 1, ink: CGFloat = dark ? 1 : 0
        func lum(_ x: [CGFloat]) -> CGFloat {
            let l = x.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2]
        }
        let bg = lum(rgb.map { $0 * 0.22 + page * 0.78 })
        for i in 0...10 {
            let x = rgb.map { $0 + (ink - $0) * CGFloat(i) / 10 }, l = lum(x)
            if (max(l, bg) + 0.05) / (min(l, bg) + 0.05) >= 3 { return Color(red: x[0], green: x[1], blue: x[2]) }
        }
        return dark ? .white : .black
    }

    static func icon(_ t: Tile) -> String {
        let on = t.s == "on", dc = t.str("device_class") ?? ""
        switch t.domain {
        case "light": return on ? "lightbulb.fill" : "lightbulb"
        case "switch", "input_boolean": return on ? "power.circle.fill" : "power.circle"
        case "fan": return "fan.fill"
        case "cover": return ["open", "opening"].contains(t.s) ? "blinds.horizontal.open" : "blinds.horizontal.closed"
        case "lock": return t.s == "locked" ? "lock.fill" : t.s == "jammed" ? "lock.trianglebadge.exclamationmark.fill" : "lock.open.fill"
        case "button", "input_button": return "button.programmable"
        case "scene": return "sparkles"
        case "script": return "scroll"
        case "siren": return "light.beacon.max.fill"
        case "remote": return "av.remote.fill"
        case "valve": return "spigot.fill"
        case "climate": return "thermometer.medium"
        case "water_heater": return "heater.vertical.fill"
        case "humidifier": return "humidifier.fill"
        case "media_player": return "hifispeaker.fill"
        case "vacuum": return "robotic.vacuum.fill"
        case "lawn_mower": return "leaf.fill"
        case "alarm_control_panel": return Ha.active(t) ? "lock.shield.fill" : "shield"
        case "number", "input_number": return "slider.horizontal.3"
        case "select", "input_select": return "list.bullet"
        case "weather": return "cloud.sun.fill"
        case "sensor":
            switch dc {
            case "temperature": return "thermometer.medium"
            case "humidity", "moisture": return "humidity.fill"
            case "battery": return "battery.75percent"
            case "power", "energy", "voltage", "current": return "bolt.fill"
            case "illuminance": return "sun.max.fill"
            default: return "gauge.medium"
            }
        case "binary_sensor":
            switch dc {
            case "door", "garage_door", "opening": return on ? "door.left.hand.open" : "door.left.hand.closed"
            case "window": return "window.vertical.closed"
            case "motion", "occupancy", "presence": return "figure.walk"
            case "moisture": return "drop.fill"
            case "smoke", "gas", "carbon_monoxide": return "smoke.fill"
            case "battery": return "battery.25percent"
            case "connectivity": return "wifi"
            default: return "sensor.fill"
            }
        default: return "circle"
        }
    }
}

/// Long-press sheet: lights, fans and covers have their own rows; every other domain is built from `Row`s.
struct DetailSheet: View {
    let id: String
    @State private var code = "" // alarm code: never stored
    @State private var ask: Btn?

    var body: some View {
        NavigationStack {
            if let t = ha.tile(id) {
                Form {
                    switch t.domain {
                    case "cover": cover(t)
                    case "light", "fan":
                        Toggle("On", isOn: Binding { t.s == "on" } set: { on in
                            ha.service(id, t.domain, on ? "turn_on" : "turn_off", optimistic: on ? "on" : "off")
                        })
                        if t.domain == "light" { light(t) }
                        if t.domain == "fan", t.features & 1 != 0 {
                            SendSlider(label: "Speed", value: Double(t.percentage ?? 0), range: 0...100, unit: "%") {
                                ha.service(id, "fan", "set_percentage", ["percentage": Int($0)])
                            }
                        }
                    default:
                        let rows = Self.rows(t, code: code) { code = "" }
                        ForEach(rows.indices, id: \.self) { i in row(rows[i]) }
                    }
                }
                .navigationTitle(t.name).navigationSubtitle(Ha.stateText(t)).navigationBarTitleDisplayMode(.inline)
                .disabled(!ha.connected)
                .alert(ask?.confirm ?? "", isPresented: Binding { ask != nil } set: { if !$0 { ask = nil } }) {
                    if let b = ask { Button(b.label, role: .destructive) { b.action() } }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
        .toast()
    }

    /// The control kinds of SPEC "More devices".
    enum Row {
        case text(String)
        case toggle(String, Bool, (Bool) -> Void)
        case slider(String, Double, ClosedRange<Double>, step: Double, unit: String, (Double) -> Void)
        case stepper(String, Double, ClosedRange<Double>, step: Double, unit: String, (Double) -> Void)
        case picker(String, String, [String], labels: Bool, (String) -> Void)
        case buttons([Btn])
        case code(numeric: Bool)
    }

    struct Btn {
        var label: String
        var icon: String
        var enabled = true
        var confirm: String?
        var action: () -> Void
    }

    @ViewBuilder private func row(_ r: Row) -> some View {
        switch r {
        case .text(let s): Text(s)
        case .toggle(let l, let on, let send): Toggle(l, isOn: Binding(get: { on }, set: send))
        case .slider(let l, let v, let range, let step, let unit, let send):
            SendSlider(label: l, value: v, range: range, unit: unit, step: step, send: send)
        case .stepper(let l, let v, let range, let step, let unit, let send):
            SendStepper(label: l, value: v, range: range, step: step, unit: unit, send: send)
        case .picker(let l, let cur, let opts, let labels, let send):
            Picker(l, selection: Binding(get: { cur }, set: send)) {
                ForEach(opts, id: \.self) { Text(labels ? Ha.label($0) : $0).tag($0) }
            }
        case .buttons(let bs):
            HStack {
                ForEach(bs.indices, id: \.self) { i in
                    let b = bs[i]
                    Button { if b.confirm != nil { ask = b } else { b.action() } } label: {
                        VStack(spacing: 4) {
                            Image(systemName: b.icon).font(.title3)
                            Text(b.label).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(!b.enabled)
                    .accessibilityLabel(b.label)
                }
            }
            .buttonStyle(.bordered)
        case .code(let numeric):
            SecureField("Code", text: $code).keyboardType(numeric ? .numberPad : .default).textContentType(.oneTimeCode)
        }
    }

    /// The rows for one tile (SPEC "More devices" table): rows whose feature bit is missing or whose list is empty are left out.
    static func rows(_ t: Tile, code: String, sent: @escaping () -> Void) -> [Row] {
        func call(_ service: String, _ data: [String: Any] = [:], optimistic: String? = nil) {
            ha.service(t.id, t.domain, service, data, optimistic: optimistic)
        }
        func power(_ label: String = "On", optimistic: Bool = false) -> Row {
            .toggle(label, t.s != "off") { on in call(on ? "turn_on" : "turn_off", optimistic: optimistic ? (on ? "on" : "off") : nil) }
        }
        func picker(_ label: String, _ key: String, _ list: String, labels: Bool = false, _ service: String) -> Row? {
            let opts = t.strs(list)
            return opts.isEmpty ? nil : .picker(label, t.str(key) ?? "", opts, labels: labels) { call(service, [key: $0]) }
        }
        let f = t.features
        let unit = t.str("temperature_unit") ?? ""
        let tempStep = t.num("target_temp_step") ?? (unit == "°F" ? 1 : 0.5)
        /// A temperature stepper (bounds `min_temp`…`max_temp`); left out without a current value or bounds.
        func temp(_ label: String, _ key: String, send: @escaping (Double) -> Void) -> Row? {
            guard let v = t.num(key), let lo = t.num("min_temp"), let hi = t.num("max_temp"), lo < hi else { return nil }
            return .stepper(label, v, lo...hi, step: tempStep, unit: unit.isEmpty ? "" : " " + unit, send)
        }
        var rows: [Row?] = []
        switch t.domain {
        case "siren": rows = [power(optimistic: true)]
        case "valve":
            var b: [Btn] = []
            if f & 1 != 0 { b.append(Btn(label: "Open", icon: "arrow.up") { call("open_valve") }) }
            if f & 8 != 0 { b.append(Btn(label: "Stop", icon: "stop.fill") { call("stop_valve") }) }
            if f & 2 != 0 { b.append(Btn(label: "Close", icon: "arrow.down") { call("close_valve") }) }
            if !b.isEmpty { rows.append(.buttons(b)) }
            if f & 4 != 0 {
                rows.append(.slider("Position", Double(t.position ?? 0), 0...100, step: 1, unit: "%") { call("set_valve_position", ["position": Int($0)]) })
            }
        case "climate":
            let mode = t.s
            rows = [t.str("hvac_action").map { Row.text(Ha.label($0)) }]
            if f & 1 != 0, mode != "heat_cool" { rows.append(temp("Target", "temperature") { call("set_temperature", ["temperature": $0]) }) }
            if f & 2 != 0, mode == "heat_cool", let lo = t.num("target_temp_low"), let hi = t.num("target_temp_high") {
                // both are sent: the other bound is read live at send time, so quick Low-then-High edits don't undo each other
                func live(_ k: String, _ v: Double) -> Double { ha.tile(t.id)?.num(k) ?? v }
                rows.append(temp("Low", "target_temp_low") { call("set_temperature", ["target_temp_low": $0, "target_temp_high": live("target_temp_high", hi)]) })
                rows.append(temp("High", "target_temp_high") { call("set_temperature", ["target_temp_low": live("target_temp_low", lo), "target_temp_high": $0]) })
            }
            let modes = t.strs("hvac_modes")
            if !modes.isEmpty {
                rows.append(.picker("Mode", mode, modes, labels: true) { call("set_hvac_mode", ["hvac_mode": $0], optimistic: $0) })
            }
            if f & 16 != 0 { rows.append(picker("Preset", "preset_mode", "preset_modes", "set_preset_mode")) }
            if f & 8 != 0 { rows.append(picker("Fan", "fan_mode", "fan_modes", "set_fan_mode")) }
        case "water_heater":
            if f & 8 != 0 { rows.append(power()) }
            if f & 1 != 0 { rows.append(temp("Target", "temperature") { call("set_temperature", ["temperature": $0]) }) }
            if f & 2 != 0 { rows.append(picker("Mode", "operation_mode", "operation_list", labels: true, "set_operation_mode")) }
            if f & 4 != 0 { rows.append(.toggle("Away", t.str("away_mode") == "on") { call("set_away_mode", ["away_mode": $0]) }) }
        case "humidifier":
            rows = [power(optimistic: true)]
            if let lo = t.num("min_humidity"), let hi = t.num("max_humidity"), lo < hi {
                rows.append(.slider("Target", t.num("humidity") ?? lo, lo...hi, step: t.num("target_humidity_step") ?? 1, unit: "%") {
                    call("set_humidity", ["humidity": $0])
                })
            }
            if f & 1 != 0 { rows.append(picker("Mode", "mode", "available_modes", "set_mode")) }
        case "media_player":
            rows = [t.str("media_title").map { Row.text($0) }, t.str("media_artist").map { Row.text($0) }]
            var b: [Btn] = []
            if f & 16 != 0 { b.append(Btn(label: "Previous", icon: "backward.fill") { call("media_previous_track") }) }
            if f & (1 | 16384) != 0 {
                b.append(Btn(label: t.s == "playing" ? "Pause" : "Play", icon: t.s == "playing" ? "pause.fill" : "play.fill") { call("media_play_pause") })
            }
            if f & 32 != 0 { b.append(Btn(label: "Next", icon: "forward.fill") { call("media_next_track") }) }
            if !b.isEmpty { rows.append(.buttons(b)) }
            if f & 4 != 0 {
                rows.append(.slider("Volume", (t.num("volume_level") ?? 0) * 100, 0...100, step: 1, unit: "%") { call("volume_set", ["volume_level": $0 / 100]) })
            }
            if f & 8 != 0 { rows.append(.toggle("Mute", t.a["is_volume_muted"]?.bool == true) { call("volume_mute", ["is_volume_muted": $0]) }) }
            if f & (128 | 256) != 0 { rows.append(power("Power")) }
            if f & 2048 != 0 { rows.append(picker("Source", "source", "source_list", "select_source")) }
        case "vacuum":
            var b: [Btn] = []
            if f & 8192 != 0 { b.append(Btn(label: "Start", icon: "play.fill") { call("start") }) }
            if f & 4 != 0 { b.append(Btn(label: "Pause", icon: "pause.fill") { call("pause") }) }
            if f & 16 != 0 { b.append(Btn(label: "Return home", icon: "house.fill") { call("return_to_base") }) }
            if f & 512 != 0 { b.append(Btn(label: "Locate", icon: "location.fill") { call("locate") }) }
            if !b.isEmpty { rows.append(.buttons(b)) }
            if f & 32 != 0 { rows.append(picker("Fan speed", "fan_speed", "fan_speed_list", "set_fan_speed")) }
        case "lawn_mower":
            var b: [Btn] = []
            if f & 1 != 0 { b.append(Btn(label: "Start", icon: "play.fill") { call("start_mowing") }) }
            if f & 2 != 0 { b.append(Btn(label: "Pause", icon: "pause.fill") { call("pause") }) }
            if f & 4 != 0 { b.append(Btn(label: "Dock", icon: "house.fill") { call("dock") }) }
            if !b.isEmpty { rows.append(.buttons(b)) }
        case "alarm_control_panel":
            let format = t.str("code_format")
            if let format { rows.append(.code(numeric: format == "number")) }
            let data: [String: Any] = code.isEmpty ? [:] : ["code": code]
            let send = { (s: String) in call(s, data); sent() }
            let canArm = format == nil || t.a["code_arm_required"]?.bool != true || !code.isEmpty
            var b: [Btn] = []
            for (bit, label, service, icon) in [(1, "Arm home", "alarm_arm_home", "house.fill"), (2, "Arm away", "alarm_arm_away", "figure.walk"),
                                                (4, "Arm night", "alarm_arm_night", "moon.fill"), (32, "Arm vacation", "alarm_arm_vacation", "airplane")]
            where f & bit != 0 {
                b.append(Btn(label: label, icon: icon, enabled: canArm) { send(service) })
            }
            if !b.isEmpty { rows.append(.buttons(b)) }
            if t.s != "disarmed" {
                // with a code format, Disarm needs the code; without one it asks first (like unlock)
                rows.append(.buttons([Btn(label: "Disarm", icon: "shield.slash", enabled: format == nil || !code.isEmpty,
                                          confirm: format == nil ? "Disarm \(t.name)?" : nil) { send("alarm_disarm") }]))
            }
        case "number", "input_number":
            if let lo = t.num("min"), let hi = t.num("max"), lo < hi {
                let u = t.str("unit_of_measurement").map { " " + $0 } ?? ""
                rows.append(.slider("Value", Double(t.s) ?? lo, lo...hi, step: t.num("step") ?? 1, unit: u) { call("set_value", ["value": $0]) })
            }
        default: break
        }
        return rows.compactMap { $0 }
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
    var step: Double = 1
    var track: LinearGradient? = nil
    let send: (Double) -> Void
    @State private var drag: Double?
    @State private var lastSent = Date.distantPast
    @State private var editing = false

    var body: some View {
        let shown = drag ?? min(max(value, range.lowerBound), range.upperBound)
        VStack(alignment: .leading) {
            LabeledContent(label, value: Ha.fmt(shown, dp: Self.decimals(step)) + unit)
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
                    .accessibilityElement().accessibilityValue(Ha.fmt(shown, dp: 0) + unit)
                    .accessibilityAdjustableAction { dir in
                        let step = (range.upperBound - range.lowerBound) / 10
                        set(min(max(shown + (dir == .increment ? step : -step), range.lowerBound), range.upperBound)); end()
                    }
                } else {
                    Slider(value: Binding(get: { shown }, set: set), in: range, step: step) { e in
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

    /// Decimals a step needs: 1 → 0, 0.5 → 1, 0.01 → 2.
    static func decimals(_ step: Double) -> Int { step >= 1 ? 0 : Int(ceil(-log10(step) - 1e-9)) }
}

/// − value +; sends 600 ms after the last press and follows the live value otherwise.
struct SendStepper: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let send: (Double) -> Void
    @State private var picked: Double?
    @State private var sent: Double?

    var body: some View {
        let shown = picked ?? value
        Stepper(value: Binding { shown } set: { picked = $0 }, in: range, step: step) {
            LabeledContent(label, value: Ha.fmt(shown) + unit)
        }
        .task(id: picked) {
            guard let p = picked else { return }
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            send(p); sent = p
        }
        .onChange(of: value) { picked = nil }
        .onDisappear { if let p = picked, p != sent { send(p) } } // the sheet closed within 600 ms
        .accessibilityIdentifier(label)
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
