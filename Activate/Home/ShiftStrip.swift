import SwiftUI

/// Tira del turno actual: una casilla por día laboral del bloque (7 en el 7×7).
/// Con pausa contada = acento lleno · comodín usado (`casco` en los datos) = escudo · hoy = borde ·
/// futuro = punteado. En bajada muestra el turno recién terminado con "Bajada: racha a salvo".
struct ShiftStrip: View {
    @Environment(AppStore.self) private var store
    @Environment(GameStore.self) private var game

    /// Estado visual de una casilla (lógica pura, testeable).
    nonisolated enum Fill: Sendable, Hashable { case pausa, casco, vacio, futuro }

    nonisolated struct DayBox: Sendable, Hashable, Identifiable {
        var day: Int
        var workDayKey: String
        var fill: Fill
        var isToday: Bool
        var id: String { workDayKey }
    }

    private static let boxHeight: CGFloat = 34
    private static let boxRadius: CGFloat = 9
    private static let todayStroke: CGFloat = 2.5

    var body: some View {
        let now = Date.now
        let calendar = store.calendar
        let kind = calendar.kind(for: now)
        let boxes = Self.boxes(data: store.data, calendar: calendar, now: now)
        let headline = Self.headline(kind: kind,
                                     dayInBlock: calendar.dayInBlock(for: now),
                                     workDays: calendar.roster.workDays,
                                     pausedToday: game.pausedToday,
                                     allPaused: boxes.allSatisfy { $0.fill == .pausa },
                                     dobleteAvailable: game.dobleteAvailable,
                                     tiroLimpioAvailable: Self.tiroLimpioAvailable(boxes: boxes))
        let note = Self.note(data: store.data, calendar: calendar, now: now)

        VStack(alignment: .leading, spacing: 12) {
            Text(headline)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(boxes) { box in
                    boxView(box)
                }
            }
            if let note {
                Label(note, systemImage: StreakChips.comodinSymbol)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .flatCard(padding: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(headline)
    }

    private func boxView(_ box: DayBox) -> some View {
        VStack(spacing: 4) {
            Text("D\(box.day)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(box.isToday ? Theme.accent : .secondary)
            RoundedRectangle(cornerRadius: Self.boxRadius)
                .fill(fillColor(box.fill))
                .frame(height: Self.boxHeight)
                .overlay {
                    if box.fill == .futuro {
                        RoundedRectangle(cornerRadius: Self.boxRadius)
                            .strokeBorder(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    }
                }
                .overlay {
                    if let symbol = symbol(box.fill) {
                        Image(systemName: symbol)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(box.fill == .pausa ? Color.white : Theme.accent)
                    }
                }
                .overlay {
                    if box.isToday {
                        RoundedRectangle(cornerRadius: Self.boxRadius)
                            .strokeBorder(Theme.accent, lineWidth: Self.todayStroke)
                    }
                }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(box))
    }

    private func fillColor(_ fill: Fill) -> Color {
        switch fill {
        case .pausa: Theme.accent
        case .casco: Theme.accent.opacity(0.15)
        case .vacio: Color.primary.opacity(0.07)
        case .futuro: Color.clear
        }
    }

    private func symbol(_ fill: Fill) -> String? {
        switch fill {
        case .pausa: "checkmark"
        case .casco: StreakChips.comodinSymbol
        case .vacio, .futuro: nil
        }
    }

    // MARK: - Lógica pura

    /// Casillas del bloque de turno al que pertenece `now` (en bajada: el turno recién terminado).
    nonisolated static func boxes(data: SaveData, calendar: WorkCalendar, now: Date) -> [DayBox] {
        let today = calendar.workDate(for: now)
        let todayKey = WorkCalendar.key(ofWorkDate: today, calendar: calendar.calendar)
        return calendar.workDatesOfTurno(containing: now).enumerated().map { index, workDate in
            let key = WorkCalendar.key(ofWorkDate: workDate, calendar: calendar.calendar)
            let record = data.workDays[key]
            let fill: Fill
            if (record?.countedPauses ?? 0) > 0 {
                fill = .pausa
            } else if record?.cascoUsed == true {
                fill = .casco
            } else if workDate > today {
                fill = .futuro
            } else {
                fill = .vacio
            }
            return DayBox(day: index + 1, workDayKey: key, fill: fill, isToday: key == todayKey)
        }
    }

    /// "Turno · día N de 7 · Vamos por el Doblete" y variantes del día 1, del último día y de la bajada.
    /// Solo promete un hito que todavía se puede lograr hoy: el Doblete si ayer hubo pausa
    /// (`dobleteAvailable`) y el Tiro limpio si todos los días anteriores del turno la tuvieron.
    nonisolated static func headline(kind: DayKind, dayInBlock: Int, workDays: Int, pausedToday: Bool, allPaused: Bool,
                                     dobleteAvailable: Bool, tiroLimpioAvailable: Bool) -> String {
        guard kind == .turno else { return "Bajada: racha a salvo" }
        let prefix = "Turno · día \(dayInBlock) de \(workDays)"
        if dayInBlock <= 1 {
            return "\(prefix) · Mañana: día 2, Doblete"
        }
        if dayInBlock >= workDays {
            if allPaused { return "\(prefix) · Tiro limpio" }
            if tiroLimpioAvailable { return "\(prefix) · Vamos por el Tiro limpio" }
        }
        if pausedToday { return "\(prefix) · Día \(dayInBlock) cumplido" }
        if dobleteAvailable { return "\(prefix) · Vamos por el Doblete" }
        return prefix
    }

    /// Hoy sin pausa todavía y todos los días anteriores del turno con pausa contada.
    nonisolated static func tiroLimpioAvailable(boxes: [DayBox]) -> Bool {
        guard let todayIndex = boxes.firstIndex(where: \.isToday), boxes[todayIndex].fill != .pausa else { return false }
        return boxes[..<todayIndex].allSatisfy { $0.fill == .pausa }
    }

    /// Nota corta bajo la tira: comodín automático de ayer.
    nonisolated static func note(data: SaveData, calendar: WorkCalendar, now: Date) -> String? {
        guard calendar.kind(for: now) == .turno else { return nil }
        let yesterdayKey = calendar.key(for: calendar.previousWorkDay(of: now))
        if data.workDays[yesterdayKey]?.cascoUsed == true {
            return CelebrationCopy.comodinUsedYesterdayLine
        }
        return nil
    }

    nonisolated static func spoken(_ box: DayBox) -> String {
        let state: String
        switch box.fill {
        case .pausa: state = "pausa cumplida"
        case .casco: state = "comodín usado, racha a salvo"
        case .vacio: state = box.isToday ? "hoy, aún sin pausa" : "sin pausa"
        case .futuro: state = "pendiente"
        }
        return box.isToday && box.fill != .vacio ? "Día \(box.day), hoy: \(state)" : "Día \(box.day): \(state)"
    }
}
