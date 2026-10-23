import SwiftUI

// Dueño: agente "stats-ui". Detalle verificado de una pausa; también sesiones simuladas, con banner.

// MARK: - Copy puro (testeable)

/// Anomalías en lenguaje claro. Las claves (`Anomaly.kind`) las define cada verificador;
/// aquí se traducen por palabras clave y, si no calza ninguna, se usa `detail`.
nonisolated enum StatsAnomalyCopy {
    private static let rules: [(keys: [String], text: String)] = [
        (["anticip"], "Respuestas antes de tiempo"),
        (["mash", "spam", "samekey", "repeat"], "La misma tecla muchas veces"),
        (["accuracy", "precision"], "Precisión muy baja"),
        (["timeout"], "Se acabó el tiempo"),
        (["background"], "La app pasó a segundo plano"),
        (["clock", "drift"], "El reloj del teléfono cambió"),
        (["partial", "half", "shallow", "descent"], "Repeticiones a medias"),
        (["blink", "wink"], "Parpadeos incompletos"),
        (["cue", "mismatch", "signal"], "No siguió la señal en pantalla"),
        (["loop", "replay", "video"], "La imagen se repetía"),
        (["static", "frozen", "photo", "still"], "La imagen no se movía"),
        (["camera"], "La cámara se movió"),
        (["shak", "sacud"], "El teléfono se sacudió sin caminar"),
        (["automotive", "vehicle", "driving"], "Parecía ir en vehículo"),
        (["walk", "gait", "march", "stationary", "pedometer"], "No pude verificar la marcha"),
        (["face", "tracking", "lost", "untracked"], "Perdí la cara de vista"),
        (["fast", "quick", "speed"], "Demasiado rápido para ser real"),
        (["short", "duration", "brief"], "Duró menos de lo necesario"),
        (["confidence"], "Poca confianza en la imagen"),
        (["light", "dark"], "Poca luz para la cámara"),
        (["distance", "far", "close"], "Distancia a la cámara fuera de rango"),
        (["time"], "El reloj del teléfono cambió"),
    ]

    static func text(forKind kind: String, detail: String?) -> String {
        let lowered = kind.lowercased()
        if let rule = rules.first(where: { rule in rule.keys.contains { lowered.contains($0) } }) {
            return rule.text
        }
        if let detail, !detail.isEmpty { return detail }
        return "No pude verificar: \(kind)"
    }

    static func text(for anomaly: Anomaly) -> String {
        text(forKind: anomaly.kind, detail: anomaly.detail)
    }

    static func severityText(_ severity: Anomaly.Severity) -> String {
        severity == .hard ? "Afectó la verificación" : "Aviso"
    }
}

/// Línea "etiqueta · valor" de métricas densas.
nonisolated struct StatsMetricLine: Identifiable, Sendable, Equatable {
    var label: String
    var value: String
    var id: String { label }
}

/// Métricas densas por actividad, ya formateadas.
nonisolated enum StatsMetricCopy {
    static func degrees(_ value: Double) -> String { "\(Int(value.rounded()))°" }

    /// Acepta fracciones 0-1 o porcentajes ya calculados.
    static func percentText(_ value: Double) -> String {
        let pct = value <= 1 ? value * 100 : value
        return "\(Int(pct.rounded())) %"
    }

    static func stroopEffect(congruentMs: Int, incongruentMs: Int) -> Int { incongruentMs - congruentMs }

    static func signedMs(_ value: Int) -> String { value > 0 ? "+\(value) ms" : "\(value) ms" }

    static func lines(for metrics: ActivityMetrics) -> [StatsMetricLine] {
        switch metrics {
        case let .steps(count, meanCadence, walkingFraction, rmsPeak):
            var lines = [StatsMetricLine(label: "Pasos verificados", value: "\(count)")]
            if let meanCadence { lines.append(.init(label: "Cadencia", value: "\(StatsCopy.format1(meanCadence)) pasos/s")) }
            if let walkingFraction { lines.append(.init(label: "Caminando", value: percentText(walkingFraction))) }
            if let rmsPeak { lines.append(.init(label: "Pico de movimiento", value: "\(rmsPeak.formatted(.number.precision(.fractionLength(2)))) g")) }
            return lines
        case let .reps(count, minDescentRatio, meanRepSeconds):
            var lines = [StatsMetricLine(label: "Repeticiones", value: "\(count)")]
            if let minDescentRatio { lines.append(.init(label: "Descenso mínimo", value: percentText(minDescentRatio))) }
            if let meanRepSeconds { lines.append(.init(label: "Tiempo por repetición", value: "\(StatsCopy.format1(meanRepSeconds)) s")) }
            return lines
        case let .neck(rotations, flexions, tilts, maxYaw, maxPitch, maxRoll, cueMatches, cueMismatches):
            return [
                .init(label: "Giros · flexiones · inclinaciones", value: "\(rotations) · \(flexions) · \(tilts)"),
                .init(label: "Giro máximo", value: degrees(maxYaw)),
                .init(label: "Flexión máxima", value: degrees(maxPitch)),
                .init(label: "Inclinación máxima", value: degrees(maxRoll)),
                .init(label: "Señales acertadas", value: "\(cueMatches) de \(cueMatches + cueMismatches)"),
            ]
        case let .eyes(completeBlinks, partialBlinks, blinksPerMinute, farGazeSeconds):
            return [
                .init(label: "Parpadeos completos", value: "\(completeBlinks)"),
                .init(label: "Parpadeos parciales", value: "\(partialBlinks)"),
                .init(label: "Parpadeos por minuto", value: StatsCopy.format1(blinksPerMinute)),
                .init(label: "Mirando lejos", value: "\(Int(farGazeSeconds.rounded())) s"),
            ]
        case let .stroop(trials, valid, accuracy, medianRTms, medianCongruentRTms, medianIncongruentRTms, anticipations, lapses, seed):
            return [
                .init(label: "Ensayos válidos", value: "\(valid) de \(trials)"),
                .init(label: "Precisión", value: percentText(accuracy)),
                .init(label: "Reacción (mediana)", value: "\(medianRTms) ms"),
                .init(label: "Congruentes · incongruentes", value: "\(medianCongruentRTms) · \(medianIncongruentRTms) ms"),
                .init(label: "Efecto Stroop", value: signedMs(stroopEffect(congruentMs: medianCongruentRTms, incongruentMs: medianIncongruentRTms))),
                .init(label: "Anticipaciones", value: "\(anticipations)"),
                .init(label: "Lapsos", value: "\(lapses)"),
                .init(label: "Semilla", value: String(seed, radix: 16)),
            ]
        case let .breath(cycles):
            return [.init(label: "Ciclos", value: "\(cycles)")]
        case .none:
            return []
        }
    }

    static func durationText(seconds: Double) -> String {
        guard seconds > 0 else { return StatsCopy.placeholder }
        return Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
    }
}

/// Símbolos y colores por nivel de verificación y por cierre (solo para las vistas de estadísticas).
enum StatsLevelStyle {
    static func symbol(_ level: VerificationLevel) -> String {
        switch level {
        case .full: "checkmark.seal.fill"
        case .reduced: "checkmark.circle"
        case .suspicious: "exclamationmark.triangle.fill"
        case .simulated: "testtube.2"
        }
    }

    static func color(_ level: VerificationLevel) -> Color {
        switch level {
        case .full: Theme.mint
        case .reduced: Theme.sky
        case .suspicious: Theme.copper
        case .simulated: Color.secondary
        }
    }

    static func postSymbol(_ post: PostResponse) -> String {
        switch post {
        case .mejor: "hand.thumbsup.fill"
        case .igual: "equal.circle.fill"
        case .peor: "hand.thumbsdown.fill"
        }
    }

    static func postColor(_ post: PostResponse) -> Color {
        switch post {
        case .mejor: Theme.mint
        case .igual: Theme.gold
        case .peor: Theme.danger
        }
    }
}

// MARK: - Piezas reutilizables

struct StatsLevelBadge: View {
    let level: VerificationLevel
    var body: some View {
        Label(level.title, systemImage: StatsLevelStyle.symbol(level))
            .font(.title3.weight(.bold))
            .foregroundStyle(StatsLevelStyle.color(level))
    }
}

/// Fila "etiqueta … valor"; pasa a dos líneas cuando no cabe (Dynamic Type).
struct StatsMetricRow: View {
    let label: String
    let value: String
    var emphasized: Bool = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .fontWeight(emphasized ? .heavy : .semibold)
                    .multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).foregroundStyle(.secondary)
                Text(value).fontWeight(emphasized ? .heavy : .semibold)
            }
        }
        .font(.body)
        .accessibilityElement(children: .combine)
    }
}

struct StatsAnomalyLine: View {
    let anomaly: Anomaly

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: anomaly.severity == .hard ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.body.weight(.bold))
                .foregroundStyle(anomaly.severity == .hard ? Theme.copper : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(StatsAnomalyCopy.text(for: anomaly))
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(StatsAnomalyCopy.severityText(anomaly.severity)) · a los \(Int(anomaly.at.rounded())) s")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SimulatedBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "testtube.2")
                .font(.title2.weight(.bold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Simulada").font(.title3.weight(.bold))
                Text("Datos de prueba. No cuenta ni suma.").font(.subheadline)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.gold.opacity(0.22), in: .rect(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.gold, lineWidth: 1.5))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detalle

struct SessionDetailView: View {
    let session: PauseSession

    private var isSimulated: Bool { session.simulated || session.level == .simulated }
    private var doneCount: Int { session.activities.filter { $0.completed && !$0.skipped }.count }
    private var isSigned: Bool { session.signature != nil && session.payloadData != nil }

    private var durationText: String {
        if session.monotonicSeconds > 0 { return StatsMetricCopy.durationText(seconds: session.monotonicSeconds) }
        if let end = session.endedAt { return StatsMetricCopy.durationText(seconds: end.timeIntervalSince(session.startedAt)) }
        return StatsCopy.placeholder
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isSimulated { SimulatedBanner() }
                headerCard
                checkInCard
                closureCard
                SectionTitle(title: "Actividades", subtitle: "\(doneCount) de \(session.activities.count) completadas")
                if session.activities.isEmpty {
                    Text("Sin actividades registradas.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .flatCard()
                }
                ForEach(session.activities) { result in
                    ActivityResultCard(result: result)
                }
                if !session.integrityFlags.isEmpty { integrityCard }
                signatureCard
                if let note = session.coachNote, !note.isEmpty { coachCard(note) }
            }
            .padding()
        }
        .appScreen()
        .navigationTitle("Detalle de la pausa")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.recipe.title).font(.title2.weight(.bold))
            Text(session.moment.title).font(.title3).foregroundStyle(.secondary)
            StatsLevelBadge(level: session.level)
            Divider()
            StatsMetricRow(label: "Inicio", value: session.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
            StatsMetricRow(label: "Duración", value: durationText)
            StatsMetricRow(label: "Racha", value: session.counted ? "Cuenta para la racha" : "No cuenta para la racha")
            if session.xpEarned > 0 {
                StatsMetricRow(label: "XP", value: "\(session.xpEarned)")
            }
        }
        .flatCard()
    }

    private var checkInCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Antes de la pausa").font(.title3.weight(.bold))
            if let score = session.checkInScore {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(score) de 6")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Theme.rdqColor(score))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RDQ-6").font(.title3)
                        Text("menos es mejor").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Label(PainZone.listTitle(session.allZones), systemImage: "figure.stand")
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Dónde le dolía: \(PainZone.listTitle(session.allZones))")
                let marked = zip(RDQ6.items, session.checkInAnswers).filter { $0.1 }.map { $0.0 }
                if !marked.isEmpty {
                    Divider()
                    ForEach(marked, id: \.self) { item in
                        Label(item, systemImage: "checkmark")
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("Sin cuestionario registrado.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .flatCard()
    }

    private var closureCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Después de la pausa").font(.title3.weight(.bold))
            if let post = session.postResponse {
                Label(post.title, systemImage: StatsLevelStyle.postSymbol(post))
                    .font(.largeTitle.weight(.heavy))
                    .foregroundStyle(StatsLevelStyle.postColor(post))
            } else {
                Text("Sin cierre registrado.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .flatCard()
    }

    private var integrityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Integridad de la sesión").font(.title3.weight(.bold))
            ForEach(Array(session.integrityFlags.enumerated()), id: \.offset) { _, flag in
                StatsAnomalyLine(anomaly: flag)
            }
        }
        .flatCard()
    }

    private var signatureCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Firma").font(.title3.weight(.bold))
            Label(isSigned ? "Firmada en el teléfono" : "Sin firma",
                  systemImage: isSigned ? "checkmark.seal.fill" : "seal")
                .font(.title3.weight(.semibold))
                .foregroundStyle(isSigned ? Theme.mint : Color.secondary)
            if let keyID = session.keyID, !keyID.isEmpty {
                StatsMetricRow(label: "Clave", value: keyID.count > 16 ? "\(keyID.prefix(16))…" : keyID)
            }
            if let backing = session.backing {
                StatsMetricRow(label: "Respaldo", value: backing == .secureEnclave ? "Secure Enclave" : "Clave de software")
            }
            if let signature = session.signature {
                StatsMetricRow(label: "Firma", value: "\(signature.count) bytes · P-256")
            }
            if let payload = session.payloadData {
                StatsMetricRow(label: "Datos firmados", value: "\(payload.count) bytes")
            }
        }
        .flatCard()
    }

    private func coachCard(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Nota del coach", systemImage: "text.bubble.fill").font(.title3.weight(.bold))
            Text(note).font(.body).fixedSize(horizontal: false, vertical: true)
        }
        .flatCard()
    }
}

private struct ActivityResultCard: View {
    let result: ActivityResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: result.kind.symbol)
                    .font(.title2)
                    .frame(minWidth: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.kind.name).font(.title3.weight(.bold))
                    StatsLevelBadge(level: result.level)
                }
            }
            StatsMetricRow(label: "Meta", value: "\(result.target) \(result.kind.unit)")
            StatsMetricRow(label: "Logrado", value: "\(result.achieved) \(result.kind.unit)", emphasized: true)
            StatsMetricRow(label: "Duración", value: StatsMetricCopy.durationText(seconds: result.durationSeconds))
            if result.skipped {
                Label("Saltada", systemImage: "forward.fill").font(.body.weight(.semibold)).foregroundStyle(.secondary)
            } else if !result.completed {
                Label("No completada", systemImage: "xmark.circle").font(.body.weight(.semibold)).foregroundStyle(.secondary)
            }
            let lines = StatsMetricCopy.lines(for: result.metrics)
            if !lines.isEmpty {
                Divider()
                ForEach(lines) { line in
                    StatsMetricRow(label: line.label, value: line.value)
                }
            }
            if !result.anomalies.isEmpty {
                Divider()
                ForEach(Array(result.anomalies.enumerated()), id: \.offset) { _, anomaly in
                    StatsAnomalyLine(anomaly: anomaly)
                }
            }
        }
        .flatCard()
    }
}
