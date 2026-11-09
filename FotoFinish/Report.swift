import UIKit

/// Piccolo strumento per scrivere un PDF a pagine A4 con testo, tabelle, barre e immagini.
final class PDFWriter {
    private let pageW: CGFloat = 595
    private let pageH: CGFloat = 842
    private let margin: CGFloat = 40
    private var ctx: UIGraphicsPDFRendererContext?
    private(set) var y: CGFloat = 0

    var contentWidth: CGFloat { pageW - margin * 2 }

    func render(to url: URL, _ draw: (PDFWriter) -> Void) -> Bool {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageW, height: pageH))
        do {
            try renderer.writePDF(to: url) { c in
                self.ctx = c
                c.beginPage()
                self.y = self.margin
                draw(self)
            }
            return true
        } catch {
            return false
        }
    }

    func space(_ h: CGFloat) {
        y += h
    }

    private func ensure(_ h: CGFloat) {
        if y + h > pageH - margin {
            ctx?.beginPage()
            y = margin
        }
    }

    /// Disegna il testo alla posizione corrente e restituisce l'altezza usata (non sposta y).
    @discardableResult
    func text(_ s: String, size: CGFloat = 11, bold: Bool = false, color: UIColor = .black,
              x: CGFloat? = nil, width: CGFloat? = nil) -> CGFloat {
        let font = bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let w = width ?? contentWidth
        let box = (s as NSString).boundingRect(with: CGSize(width: w, height: 3000),
                                               options: .usesLineFragmentOrigin,
                                               attributes: attrs, context: nil)
        let h = ceil(box.height)
        ensure(h)
        (s as NSString).draw(in: CGRect(x: x ?? margin, y: y, width: w, height: h), withAttributes: attrs)
        return h
    }

    func line(_ s: String, size: CGFloat = 11, bold: Bool = false, color: UIColor = .black) {
        let h = text(s, size: size, bold: bold, color: color)
        y += h + 3
    }

    func row(_ cells: [String], widths: [CGFloat], bold: Bool = false, size: CGFloat = 10) {
        var x = margin
        var maxH: CGFloat = 0
        for (i, c) in cells.enumerated() where i < widths.count {
            let h = text(c, size: size, bold: bold, x: x, width: widths[i] - 4)
            maxH = max(maxH, h)
            x += widths[i]
        }
        y += maxH + 4
    }

    func bars(_ items: [(String, Double)]) {
        guard let maxV = items.map({ $0.1 }).max(), maxV > 0 else { return }
        for (name, v) in items {
            ensure(18)
            _ = text(name, size: 10, x: margin, width: 100)
            let w = CGFloat(v / maxV) * 280
            UIColor.systemBlue.setFill()
            UIBezierPath(rect: CGRect(x: margin + 105, y: y + 2, width: max(2, w), height: 11)).fill()
            _ = text(fmtTime(v), size: 10, x: margin + 110 + w, width: 60)
            y += 18
        }
    }

    func image(_ img: UIImage, height: CGFloat = 110) {
        ensure(height + 6)
        img.draw(in: CGRect(x: margin, y: y, width: contentWidth, height: height))
        y += height + 6
    }
}

enum ReportBuilder {
    static func sessionReport(session: Session, store: DataStore) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fotofinish-report.pdf")
        let writer = PDFWriter()
        let ok = writer.render(to: url) { w in
            w.line(session.displayTitle, size: 20, bold: true)
            w.line("\(session.kind.title) · \(session.plan.label) m · \(session.date.formatted(date: .complete, time: .shortened))",
                   size: 11, color: .darkGray)
            var details: [String] = []
            if !session.place.isEmpty { details.append("Luogo: \(session.place)") }
            if !session.temperature.isEmpty { details.append("Temperatura: \(session.temperature)") }
            if !session.wind.isEmpty { details.append("Vento: \(session.wind)") }
            if !details.isEmpty { w.line(details.joined(separator: "  ·  "), size: 10, color: .darkGray) }
            if !session.notes.isEmpty { w.line("Note: \(session.notes)", size: 10) }
            w.space(10)

            // Tabelle dei tempi per serie
            let reps = max(1, session.plan.reps)
            let nameW: CGFloat = 100
            let cellW = min(52, (w.contentWidth - nameW - 60) / CGFloat(reps))
            var widths: [CGFloat] = [nameW]
            for _ in 0..<reps { widths.append(cellW) }
            widths.append(60)
            for s in 1...max(1, session.plan.series) {
                w.line("Serie \(s)", size: 13, bold: true)
                var header = ["Atleta"]
                for r in 1...reps { header.append("R\(r)") }
                header.append("Media")
                w.row(header, widths: widths, bold: true)
                for a in session.athletes {
                    var cells = [a]
                    var times: [Double] = []
                    for r in 1...reps {
                        if let run = store.cellRun(session, a, s, r) {
                            cells.append(fmtTime(run.time))
                            times.append(run.time)
                        } else {
                            cells.append("—")
                        }
                    }
                    cells.append(times.isEmpty ? "—" : fmtTime(times.reduce(0, +) / Double(times.count)))
                    w.row(cells, widths: widths)
                }
                w.space(8)
            }

            // Statistiche per atleta
            w.line("Statistiche", size: 13, bold: true)
            let sw: [CGFloat] = [110, 70, 70, 70, 80]
            w.row(["Atleta", "Migliore", "Media", "Calo", "Costanza"], widths: sw, bold: true)
            var avgBars: [(String, Double)] = []
            for a in session.athletes {
                let t = store.sessionTimes(session, athlete: a)
                if let st = Stats(t) {
                    let calo = Analytics.fatigue(t).map { String(format: "%+.1f%%", $0) } ?? "—"
                    w.row([a, fmtTime(st.best), fmtTime(st.mean), calo, String(format: "%.1f%%", st.cv)], widths: sw)
                    avgBars.append((a, st.mean))
                } else {
                    w.row([a, "—", "—", "—", "—"], widths: sw)
                }
            }
            w.space(10)
            if !avgBars.isEmpty {
                w.line("Tempo medio per atleta", size: 13, bold: true)
                w.bars(avgBars)
                w.space(10)
            }

            // Fotofinish delle gare dell'allenamento
            var seen = Set<UUID>()
            var shown = 0
            for r in store.runs where r.sessionId == session.id {
                guard shown < 6, let rid = r.raceId, !seen.contains(rid) else { continue }
                seen.insert(rid)
                if let strip = store.loadStrip(rid) {
                    let racers = store.runs(forRace: rid)
                        .map { "\($0.athlete.isEmpty ? "?" : $0.athlete) \(fmtTime($0.time))" }
                        .joined(separator: " · ")
                    w.line("Fotofinish: \(racers)", size: 10, bold: true)
                    w.image(strip.0)
                    shown += 1
                }
            }
            w.space(6)
            w.line("Generato da FotoFinish. Tempi non omologati.", size: 8, color: .gray)
        }
        return ok ? url : nil
    }

    static func athleteReport(athlete: String, distance: Double, runs: [Run], stats st: Stats) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fotofinish-atleta.pdf")
        let writer = PDFWriter()
        let name = athlete.isEmpty ? "Senza nome" : athlete
        let ok = writer.render(to: url) { w in
            w.line(name, size: 20, bold: true)
            w.line("\(fmtDist(distance)) m · \(st.n) prove", size: 11, color: .darkGray)
            w.space(10)
            w.line("Riepilogo", size: 13, bold: true)
            w.line("Record personale: \(fmtTime(st.best)) s")
            w.line("Ultima prova: \(fmtTime(st.last)) s (\(fmtSigned(st.last - st.best)) s dal record)")
            w.line("Media: \(fmtTime(st.mean)) s · Mediana: \(fmtTime(st.median)) s")
            w.line(String(format: "Deviazione standard: %.2f s · Costanza: %.1f%%", st.sd, st.cv))
            if st.n > 1 { w.line("Tendenza per prova: \(fmtSigned(st.slope, 3)) s") }
            w.space(10)
            w.line("Ultime prove", size: 13, bold: true)
            let cw: [CGFloat] = [140, 80, 80, 90]
            w.row(["Data", "Tempo", "km/h", "Modalità"], widths: cw, bold: true)
            for r in runs.suffix(40).reversed() {
                w.row([r.date.formatted(date: .abbreviated, time: .shortened),
                       fmtTime(r.time),
                       String(format: "%.1f", r.speedKMH),
                       r.mode.title], widths: cw)
            }
            w.space(8)
            w.line("Generato da FotoFinish. Tempi non omologati.", size: 8, color: .gray)
        }
        return ok ? url : nil
    }
}
