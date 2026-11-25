import AVFoundation
import SwiftUI

struct CamerasView: View {
    @State private var full = Hooks.string("camera").map { DetailID(id: $0) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(ha.cameras) { cam in
                        VStack(alignment: .leading, spacing: 6) {
                            Group {
                                // full screen plays this camera already: don't run a second stream underneath
                                if full?.id == cam.id { Color.black } else { CameraFeed(cam: cam) }
                            }
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(.rect(cornerRadius: 16))
                            .contentShape(.rect)
                            .onTapGesture { if cam.s != "unavailable" { full = DetailID(id: cam.id) } }
                            Text(cam.name).font(.subheadline.weight(.semibold)).padding(.leading, 4)
                        }
                        .opacity(cam.s == "unavailable" ? 0.5 : 1)
                        .accessibilityIdentifier(cam.id)
                    }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .top, spacing: 0) { Banner() }
            .navigationTitle("Cameras")
            .fullScreenCover(item: $full) { FullCamera(id: $0.id) }
        }
    }
}

/// Full-screen live view: black, aspect-fit, pinch to zoom (drag to pan, double-tap to reset).
struct FullCamera: View {
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale = 1.0
    @State private var offset = CGSize.zero
    @GestureState private var pinch = 1.0
    @GestureState private var pan = CGSize.zero

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let cam = ha.tile(id) {
                CameraFeed(cam: cam)
                    .scaleEffect(scale * pinch)
                    .offset(x: offset.width + pan.width, y: offset.height + pan.height)
                    .ignoresSafeArea()
                    .gesture(MagnifyGesture().updating($pinch) { v, s, _ in s = v.magnification }
                        .onEnded { scale = min(max(scale * $0.magnification, 1), 6); if scale == 1 { offset = .zero } })
                    .simultaneousGesture(DragGesture().updating($pan) { v, s, _ in if scale > 1 { s = v.translation } }
                        .onEnded { v in if scale > 1 { offset.width += v.translation.width; offset.height += v.translation.height } })
                    .onTapGesture(count: 2) { withAnimation { scale = 1; offset = .zero } }
            }
            Button("Close", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly).font(.title3).buttonStyle(.glass).padding()
        }
        .statusBarHidden()
    }
}

/// One camera, live: HLS when the camera offers it, else (or if the stream can't start) its snapshot every second.
struct CameraFeed: View {
    let cam: Tile
    @State private var player: AVPlayer?
    @State private var ready = false
    @State private var still: UIImage?
    @State private var failed = false
    @State private var start = Date.now

    var body: some View {
        ZStack {
            Color.black
            if let still { Image(uiImage: still).resizable().scaledToFit() }
            if let player { PlayerLayer(player: player) {
                if !ready { logger.info("camera \(cam.id, privacy: .public): first frame after \(Int(-start.timeIntervalSinceNow * 1000)) ms") }
                ready = true
            }.opacity(ready ? 1 : 0) }
            if cam.s == "unavailable" { label("Unavailable") }
            else if failed { label("Stream unavailable") }
            else if !ready && still == nil { ProgressView().tint(.white) }
        }
        .task(id: "\(cam.id) \(ha.connected) \(cam.s == "unavailable")") { await run() }
    }

    private func label(_ s: String) -> some View { Text(s).font(.subheadline).foregroundStyle(.white.opacity(0.8)) }

    private func run() async {
        start = .now
        ready = false; failed = false
        defer { player?.pause(); player = nil }
        guard cam.s != "unavailable", ha.connected, let base = ha.base else { return }
        let poster = Task { if let i = await snapshot(base) { if !ready { still = i } } }
        defer { poster.cancel() }
        let caps = try? await ha.call(["type": "camera/capabilities", "entity_id": cam.id]) as? [String: Any]
        if (caps?["frontend_stream_types"] as? [String])?.contains("hls") == true {
            for attempt in 0..<2 {
                guard let r = try? await ha.call(["type": "camera/stream", "entity_id": cam.id]) as? [String: Any],
                      let path = r["url"] as? String, let url = URL(string: base + path) else { break } // no stream: snapshots
                logger.info("camera \(cam.id, privacy: .public): stream url after \(Int(-start.timeIntervalSinceNow * 1000)) ms")
                let item = AVPlayerItem(url: url)
                let p = AVPlayer(playerItem: item)
                p.isMuted = true
                p.play()
                player = p
                for await s in item.publisher(for: \.status).values where s == .failed { break } // ends on failure or cancel
                p.pause()
                if Task.isCancelled { return }
                logger.info("camera \(cam.id, privacy: .public): playback failed: \(item.error?.localizedDescription ?? "?", privacy: .public)")
                player = nil; ready = false
                if attempt == 1 { failed = true; return }
            }
        }
        poster.cancel()
        while !Task.isCancelled {
            if let i = await snapshot(base) { still = i }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// `<base>` + `entity_picture` (carries its own token); nil when the camera can't make a still (HTTP 500).
    private func snapshot(_ base: String) async -> UIImage? {
        guard let pic = ha.tile(cam.id)?.picture ?? cam.picture, let url = URL(string: base + pic),
              let res = try? await URLSession.shared.data(from: url), (res.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return UIImage(data: res.0)
    }
}

/// AVPlayerLayer without controls; calls `onReady` once the first frame can be shown.
struct PlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    let onReady: () -> Void

    final class View: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var pl: AVPlayerLayer { layer as! AVPlayerLayer }
        var obs: NSKeyValueObservation?
    }

    func makeUIView(context: Context) -> View {
        let v = View()
        v.pl.videoGravity = .resizeAspect
        v.pl.player = player
        let ready = onReady
        v.obs = v.pl.observe(\.isReadyForDisplay, options: [.initial, .new]) { l, _ in
            if l.isReadyForDisplay { DispatchQueue.main.async { ready() } }
        }
        return v
    }

    func updateUIView(_ v: View, context: Context) { if v.pl.player !== player { v.pl.player = player } }
}
