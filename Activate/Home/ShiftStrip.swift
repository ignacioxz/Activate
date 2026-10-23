import SwiftUI

/// Tira del turno actual: una casilla por día laboral del bloque (7 en el 7×7).
/// Con pausa contada = cobre lleno · casco usado = gris · hoy = borde · futuro = vacío.
/// En bajada muestra el turno recién terminado con "Bajada: racha a salvo".
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

    private static let boxHeight: CGFloat = 44
    private static let boxRadius: CGFloat = 10
    private static let todayStroke: CGFloat = 3

    var body: some View {
        let now = Date.now
        let calendar = store.calendar
        let kind = calendar.kind(for: now)
        let boxes = Self.boxes(data: store.data, calendar: calendar, now: now)
        let headline = Self.headline(kind: kind,
                                     dayInBlock: calendar.dayInBlock(for: now),
                                     workDays: calendar.roster.workDays,
                                     pausedToday: game.pausedToday,
                                     allPaused: boxes.allSatisfy { $0.fill == .pausa })
        let note = Self.note(data: store.data, calendar: calendar, now: now)

        VStack(alignment: .leading, spacing: 14) {
            Text(headline)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(boxes) { box in
                    boxView(box)
                }
            }
            if let note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .flatCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(headline)
    }

    private func boxView(_ box: DayBox) -> some View {
        VStack(spacing: 6) {
            Text("D\(box.day)")
                .font(.caption.weight(.bold))
                .foregroundStyle(box.isToday ? Theme.copper : .secondary)
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
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .overlay {
                    if box.isToday {
                        RoundedRectangle(cornerRadius: Self.boxRadius)
                            .strokeBorder(Theme.copper, lineWidth: Self.todayStroke)
                    }
                }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(box))
    }

    private func fillColor(_ fill: Fill) -> Color {
        switch fill {
        case .pausa: Theme.copper
        case .casco: Color.gray.opacity(0.5)
        case .vacio: Color.primary.opacity(0.07)
        case .futuro: Color.clear
        }
    }

    private func symbol(_ fill: Fill) -> String? {
        switch fill {
        case .pausa: "checkmark"
        case .casco: "helmet.fill"
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
    nonisolated static func headline(kind: DayKind, dayInBlock: Int, workDays: Int, pausedToday: Bool, allPaused: Bool) -> String {
        guard kind == .turno else { return "Bajada: racha a salvo" }
        let prefix = "Turno · día \(dayInBlock) de \(workDays)"
        if dayInBlock <= 1 {
            return "\(prefix) · Mañana: día 2, Doblete"
        }
        if dayInBlock >= workDays {
            return allPaused ? "\(prefix) · Tiro limpio" : "\(prefix) · Vamos por el Tiro limpio"
        }
        return pausedToday ? "\(prefix) · Día \(dayInBlock) cumplido" : "\(prefix) · Vamos por el Doblete"
    }

    /// Nota corta bajo la tira: casco automático de ayer.
    nonisolated static func note(data: SaveData, calendar: WorkCalendar, now: Date) -> String? {
        guard calendar.kind(for: now) == .turno else { return nil }
        let yesterdayKey = calendar.key(for: calendar.previousWorkDay(of: now))
        if data.workDays[yesterdayKey]?.cascoUsed == true {
            return "Ayer usó el casco. Racha a salvo."
        }
        return nil
    }

    nonisolated static func spoken(_ box: DayBox) -> String {
        let state: String
        switch box.fill {
        case .pausa: state = "pausa cumplida"
        case .casco: state = "casco usado"
        case .vacio: state = box.isToday ? "hoy, aún sin pausa" : "sin pausa"
        case .futuro: state = "pendiente"
        }
        return box.isToday && box.fill != .vacio ? "Día \(box.day), hoy: \(state)" : "Día \(box.day): \(state)"
    }
}
