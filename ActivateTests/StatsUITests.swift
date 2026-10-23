import Testing
import Foundation
@testable import Activate

/// Reglas puras de la pestaña Estadísticas (copy, comparación entre turnos, casillas, métricas densas).
struct StatsUITests {
    private func turno(key: String, days: Int = 7, withPause: Int, mean: Double?, better: Int, same: Int, worse: Int) -> TurnoSummary {
        TurnoSummary(turnoKey: key, label: "Turno \(key)", workDays: days, daysWithPause: withPause,
                     countedPauses: withPause, meanRDQ: mean, maxRDQ: mean.map { Int($0.rounded(.up)) },
                     itemFrequency: [0, 0, 0, 0, 0, 0], betterCount: better, sameCount: same, worseCount: worse,
                     verifiedSteps: 0, verifiedReps: 0, maxStreak: withPause,
                     stroopMedianRTms: nil, blinksPerMinute: nil, neckMaxYaw: nil)
    }

    private func day(_ n: Int, key: String, rdq: Int? = nil, pauses: Int = 0, casco: Bool = false, today: Bool = false) -> DayStat {
        DayStat(workDayKey: key, dayInBlock: n, rdq: rdq, countedPauses: pauses, cascoUsed: casco, isToday: today)
    }

    @Test func comparacionEntreTurnosConFlechas() {
        let current = turno(key: "2026-10-26", withPause: 5, mean: 2.5, better: 7, same: 1, worse: 0)
        let previous = turno(key: "2026-10-12", withPause: 3, mean: 4.0, better: 2, same: 2, worse: 1)
        let lines = StatsCopy.comparisonLines(current: current, previous: previous)
        #expect(lines.count == 3)
        #expect(lines[0].direction == .better)
        #expect(lines[0].direction.symbol(lowerIsBetter: true) == "arrow.down.right")
        #expect(lines[1].direction == .better)
        #expect(lines[1].current == "88 %")
        #expect(lines[2].direction == .better)
        #expect(lines[2].current == "5 de 7")
        #expect(StatsCopy.comparisonLines(current: current, previous: nil).allSatisfy { $0.direction == .unknown })
    }

    @Test func toleranciaParaIgual() {
        #expect(StatsCopy.direction(current: 3.1, previous: 3.0, lowerIsBetter: true, tolerance: StatsCopy.rdqSameTolerance) == .same)
        #expect(StatsCopy.direction(current: 4.0, previous: 3.0, lowerIsBetter: true, tolerance: StatsCopy.rdqSameTolerance) == .worse)
        #expect(StatsCopy.direction(current: 80, previous: 50, lowerIsBetter: false, tolerance: StatsCopy.percentSameTolerance) == .better)
        #expect(StatsCopy.direction(current: nil, previous: 3, lowerIsBetter: true, tolerance: 0.25) == .unknown)
    }

    @Test func estadoDeCasillasDelTurno() {
        #expect(StatsCopy.cellState(for: day(3, key: "2026-10-28", today: true), todayIndex: 3) == .today)
        #expect(StatsCopy.cellState(for: day(1, key: "2026-10-26", pauses: 1), todayIndex: 3) == .pause)
        #expect(StatsCopy.cellState(for: day(2, key: "2026-10-27", casco: true), todayIndex: 3) == .casco)
        #expect(StatsCopy.cellState(for: day(5, key: "2026-10-30"), todayIndex: 3) == .future)
        #expect(StatsCopy.cellState(for: day(2, key: "2026-10-20"), todayIndex: nil) == .missed)
        #expect(TurnoDayState.future.symbol == nil)
    }

    @Test func plantillaDeLecturaMientrasLlegaElCoach() {
        let current = turno(key: "2026-10-26", withPause: 4, mean: 2.5, better: 7, same: 1, worse: 0)
        let previous = turno(key: "2026-10-12", withPause: 3, mean: 4.0, better: 2, same: 2, worse: 1)
        let days = [
            day(1, key: "2026-10-26", rdq: 4, pauses: 1), day(2, key: "2026-10-27", rdq: 3, pauses: 1),
            day(3, key: "2026-10-28", rdq: 3, pauses: 1), day(4, key: "2026-10-29", rdq: 2, pauses: 1),
            day(5, key: "2026-10-30", rdq: 2, today: true), day(6, key: "2026-10-31"), day(7, key: "2026-11-01"),
        ]
        let summary = StatsSummary(currentTurno: current, previousTurno: previous, turnos: [previous, current],
                                   streak: 4, totalCountedPauses: 9, todayRDQ: 2, recentSessions: [],
                                   worsensHints: [], historyLines: [], currentTurnoDays: days)
        let lines = StatsCopy.templateSentences(summary, name: "Marco", isRestDay: false)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("Marco, 4 de 5"))
        #expect(lines[1].contains("2 de 6"))
        #expect(lines[2].contains("7 de 8"))
        #expect(!lines.joined().lowercased().contains("trampa"))
        #expect(StatsCopy.daysSoFar(summary) == 5)
    }

    @Test func anomaliasEnLenguajeClaro() {
        #expect(StatsAnomalyCopy.text(forKind: "notWalking", detail: nil) == "No pude verificar la marcha")
        #expect(StatsAnomalyCopy.text(forKind: "clockDrift", detail: nil) == "El reloj del teléfono cambió")
        #expect(StatsAnomalyCopy.text(forKind: "anticipation", detail: nil) == "Respuestas antes de tiempo")
        #expect(StatsAnomalyCopy.text(forKind: "staticImage", detail: nil) == "La imagen no se movía")
        #expect(StatsAnomalyCopy.text(forKind: "xyz", detail: "Detalle del verificador") == "Detalle del verificador")
        #expect(StatsAnomalyCopy.text(forKind: "xyz", detail: nil).contains("xyz"))
        let anomaly = Anomaly(kind: "shake", severity: .hard, at: 12.4)
        #expect(StatsAnomalyCopy.text(for: anomaly) == "El teléfono se sacudió sin caminar")
        #expect(StatsAnomalyCopy.severityText(.hard) == "Afectó la verificación")
        // Pararse y sentarse / sentadilla en las manos: claves propias antes de las genéricas.
        #expect(StatsAnomalyCopy.text(forKind: SitStandAnomaly.altitudeDrift, detail: nil) == "Cambió de altura: escalera o ascensor")
        #expect(StatsAnomalyCopy.text(forKind: SitStandAnomaly.flatFace, detail: nil) == "La cara se veía plana, como una foto")
        #expect(StatsAnomalyCopy.text(forKind: SitStandAnomaly.armsOnly, detail: nil) == "Subió el teléfono con los brazos")
        #expect(StatsAnomalyCopy.text(forKind: SitStandAnomaly.torsoOnly, detail: nil) == "Se inclinó sin pararse del todo")
        #expect(StatsAnomalyCopy.text(forKind: SitStandAnomaly.holdChallengeFailed, detail: nil) == "No aguantó los 2 segundos que pedía la pantalla")
        #expect(StatsAnomalyCopy.text(forKind: SitStandAnomaly.staticFace, detail: nil) == "La imagen no se movía")
    }

    @Test func metricasDensasPorActividad() {
        let stroop = ActivityMetrics.stroop(trials: 40, valid: 38, accuracy: 0.92, medianRTms: 612,
                                            medianCongruentRTms: 580, medianIncongruentRTms: 665,
                                            anticipations: 1, lapses: 0, seed: 42)
        let lines = StatsMetricCopy.lines(for: stroop)
        #expect(lines.contains { $0.label == "Efecto Stroop" && $0.value == "+85 ms" })
        #expect(lines.contains { $0.label == "Precisión" && $0.value == "92 %" })
        #expect(lines.contains { $0.label == "Ensayos válidos" && $0.value == "38 de 40" })
        let eyes = ActivityMetrics.eyes(completeBlinks: 15, partialBlinks: 3, blinksPerMinute: 14.0, farGazeSeconds: 20)
        #expect(StatsMetricCopy.lines(for: eyes).contains { $0.label == "Parpadeos por minuto" })
        let neck = ActivityMetrics.neck(rotations: 5, flexions: 5, tilts: 5, maxYaw: 47.6, maxPitch: 30, maxRoll: 22,
                                        cueMatches: 12, cueMismatches: 3)
        #expect(StatsMetricCopy.lines(for: neck).contains { $0.label == "Giro máximo" && $0.value == "48°" })
        #expect(StatsMetricCopy.lines(for: neck).contains { $0.label == "Señales acertadas" && $0.value == "12 de 15" })
        #expect(StatsMetricCopy.lines(for: .none).isEmpty)
        // Pararse y sentarse: `.reps` lleva la mayor subida del teléfono en metros.
        let sitStand = ActivityMetrics.reps(count: 8, minDescentRatio: 0.42, meanRepSeconds: 3.6)
        let sitLines = StatsMetricCopy.lines(for: sitStand, kind: .pararseSentarse)
        #expect(sitLines.first == StatsMetricLine(label: "Veces de pie", value: "8"))
        #expect(sitLines.contains { $0.label == "Subida máxima" && $0.value == "42 cm" })
        #expect(sitLines.contains { $0.label == "Tiempo por vez" })
        #expect(!sitLines.contains { $0.label == "Descenso mínimo" })
        // La sentadilla sigue leyendo el descenso relativo.
        #expect(StatsMetricCopy.lines(for: sitStand, kind: .sentadilla).contains { $0.label == "Descenso mínimo" && $0.value == "42 %" })
        #expect(StatsFormatting.activityName(.pararseSentarse) == "pararse y sentarse")
    }

    @Test func porcentajesYEtiquetas() {
        #expect(StatsCopy.percent(7, of: 8) == 88)
        #expect(StatsCopy.percent(1, of: 0) == nil)
        #expect(StatsCopy.percentText(nil) == StatsCopy.placeholder)
        #expect(StatsCopy.turnoDateLabel(key: "no-es-fecha", fallback: "Etiqueta") == "Etiqueta")
        #expect(StatsCopy.turnoDateLabel(key: "2026-10-12", fallback: "Etiqueta") != "Etiqueta")
    }
}
