import SwiftUI
import UIKit

struct PhotoFinishView: View {
    let raceId: UUID
    @EnvironmentObject var store: DataStore
    @EnvironmentObject var settings: AppSettings

    @State private var image: UIImage?
    @State private var info: StripInfo?
    @State private var zoom: Double = 1
    @State private var invertTime = false
    @State private var flipVertical = false
    @State private var selected: UUID?
    @State private var share: ShareItem?

    private let imageHeight: CGFloat = 300
    private let markColors: [Color] = [.red, .blue, .green, .orange, .purple, .pink, .teal, .yellow]

    private var raceRuns: [Run] {
        store.runs(forRace: raceId)
    }

    /// true: il tempo avanza verso sinistra (immagine "naturale" per chi corre da sinistra a destra)
    private var laterToLeft: Bool {
        settings.leftToRight ? !invertTime : invertTime
    }

    var body: some View {
        VStack(spacing: 10) {
            if let img = image, let inf = info {
                content(img, inf)
            } else {
                Spacer()
                Text("Immagine non disponibile")
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .navigationTitle("Fotofinish")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
        .sheet(item: $share) { item in
            ShareSheet(items: [item.url])
        }
    }

    private func load() {
        if let loaded = store.loadStrip(raceId) {
            image = loaded.0
            info = loaded.1
        }
    }

    // MARK: Contenuto

    private func content(_ img: UIImage, _ inf: StripInfo) -> some View {
        VStack(spacing: 10) {
            Text(selected == nil
                 ? "Tocca l’immagine dove l’atleta taglia il traguardo (il torso)."
                 : "Tocca l’immagine per spostare il segno selezionato.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            GeometryReader { geo in
                let width = max(geo.size.width, 300) * CGFloat(zoom)
                ScrollView(.horizontal, showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: img)
                            .resizable()
                            .frame(width: width, height: imageHeight)
                            .scaleEffect(x: 1, y: flipVertical ? -1 : 1)
                        ruler(inf, width: width)
                            .frame(width: width, height: imageHeight)
                        ForEach(Array(raceRuns.enumerated()), id: \.element.id) { idx, r in
                            marker(r, index: idx, inf: inf, width: width)
                        }
                    }
                    .frame(width: width, height: imageHeight)
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            tapped(value.location.x, width: width, inf: inf)
                        }
                    )
                }
            }
            .frame(height: imageHeight + 12)

            controls(img)

            List {
                Section("Arrivi") {
                    ForEach(Array(raceRuns.enumerated()), id: \.element.id) { idx, r in
                        runRow(r, index: idx)
                    }
                    if raceRuns.isEmpty {
                        Text("Nessun segno. Tocca l’immagine per aggiungere un arrivo.")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func controls(_ img: UIImage) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "minus.magnifyingglass")
                Slider(value: $zoom, in: 1...8)
                Image(systemName: "plus.magnifyingglass")
            }
            .padding(.horizontal)
            HStack(spacing: 8) {
                Button {
                    invertTime.toggle()
                } label: {
                    Label("Inverti tempo", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.bordered)
                Button {
                    flipVertical.toggle()
                } label: {
                    Label("Capovolgi", systemImage: "arrow.up.arrow.down")
                }
                .buttonStyle(.bordered)
                Button {
                    shareImage(img)
                } label: {
                    Label("Condividi", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
            .font(.footnote)
        }
    }

    private func shareImage(_ img: UIImage) {
        guard let data = img.jpegData(compressionQuality: 0.9) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fotofinish.jpg")
        try? data.write(to: url, options: .atomic)
        share = ShareItem(url: url)
    }

    // MARK: Disegno

    private func ruler(_ inf: StripInfo, width: CGFloat) -> some View {
        Canvas { ctx, size in
            guard let first = inf.colTimes.first, let last = inf.colTimes.last else { return }
            let band = CGRect(x: 0, y: size.height - 34, width: size.width, height: 34)
            ctx.fill(Path(band), with: .color(Color.black.opacity(0.45)))
            let step = 0.1
            var k = Int((first / step).rounded(.up))
            while Double(k) * step <= last {
                let t = Double(k) * step
                let x = xFor(time: t, inf: inf, width: size.width)
                let major = k % 5 == 0
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x, y: size.height - (major ? 14 : 7)))
                ctx.stroke(p, with: .color(.white), lineWidth: 1)
                if major {
                    ctx.draw(Text(String(format: "%.1f", t)).font(.system(size: 10)).foregroundColor(.white),
                             at: CGPoint(x: x, y: size.height - 24))
                }
                k += 1
            }
        }
        .allowsHitTesting(false)
    }

    private func marker(_ r: Run, index: Int, inf: StripInfo, width: CGFloat) -> some View {
        let x = xFor(time: r.time, inf: inf, width: width)
        let color = markColors[index % markColors.count]
        let isSelected = selected == r.id
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(color)
                .frame(width: isSelected ? 4 : 2, height: imageHeight)
            Text("\(index + 1)° \(fmtTime(r.time))")
                .font(.caption2.bold())
                .padding(3)
                .background(color)
                .foregroundColor(.white)
                .cornerRadius(4)
                .offset(y: 2)
                .fixedSize()
        }
        .frame(width: 80, height: imageHeight)
        .position(x: x, y: imageHeight / 2)
        .allowsHitTesting(false)
    }

    // MARK: Conversione tra tempo e posizione

    private func xFor(time: Double, inf: StripInfo, width: CGFloat) -> CGFloat {
        let n = inf.colTimes.count
        guard n > 1 else { return 0 }
        var lo = 0
        var hi = n - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if inf.colTimes[mid] < time { lo = mid + 1 } else { hi = mid }
        }
        let frac = (CGFloat(lo) + 0.5) / CGFloat(n)
        return (laterToLeft ? (1 - frac) : frac) * width
    }

    private func timeFor(x: CGFloat, inf: StripInfo, width: CGFloat) -> Double {
        let n = inf.colTimes.count
        guard n > 0, width > 0 else { return 0 }
        var frac = Double(x / width)
        if laterToLeft { frac = 1 - frac }
        let i = min(max(Int(frac * Double(n)), 0), n - 1)
        return inf.colTimes[i]
    }

    // MARK: Azioni

    private func tapped(_ x: CGFloat, width: CGFloat, inf: StripInfo) {
        let t = timeFor(x: x, inf: inf, width: width)
        if let sel = selected, var r = raceRuns.first(where: { $0.id == sel }) {
            r.time = t
            store.update(r)
            selected = nil
        } else {
            addRun(at: t)
        }
    }

    private func addRun(at t: Double) {
        let base = raceRuns.first
        let r = Run(athlete: "", distance: base?.distance ?? 100, mode: base?.mode ?? .manual, time: t,
                    uncertaintyMs: base?.uncertaintyMs, raceId: raceId, sessionId: base?.sessionId)
        store.addAssigning(r)
    }

    private func runRow(_ r: Run, index: Int) -> some View {
        let color = markColors[index % markColors.count]
        let leader = raceRuns.first
        return HStack(spacing: 10) {
            Circle().fill(color).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(fmtTime(r.time))
                    .font(.title3.weight(.semibold).monospacedDigit())
                if let l = leader, l.id != r.id, r.distance > 0, r.time > 0 {
                    let dt = r.time - l.time
                    Text(String(format: "+%.2f s · %.1f m", dt, dt * (r.distance / r.time)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Menu {
                let options = optionsFor(r)
                ForEach(options, id: \.self) { name in
                    Button(name) { store.assign(r.id, athlete: name) }
                }
                Button("Senza nome") { store.assign(r.id, athlete: "") }
            } label: {
                Text(r.athlete.isEmpty ? "Assegna atleta" : r.athlete)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(r.athlete.isEmpty ? Color.orange.opacity(0.25) : Color(.tertiarySystemBackground))
                    .clipShape(Capsule())
            }
            Button {
                selected = (selected == r.id) ? nil : r.id
            } label: {
                Image(systemName: selected == r.id ? "scope" : "arrow.left.and.right")
                    .foregroundColor(selected == r.id ? .accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) {
                store.delete(ids: [r.id])
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func optionsFor(_ r: Run) -> [String] {
        if let sid = r.sessionId, let s = store.sessions.first(where: { $0.id == sid }) {
            return s.athletes
        }
        return store.athletes
    }
}
