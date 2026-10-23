import Foundation

/// Momentos reales del turno donde cabe una pausa con el teléfono permitido.
nonisolated enum Moment: String, Codable, CaseIterable, Sendable, Identifiable {
    case entrada, colacion, salida, campamento

    var id: String { rawValue }

    var title: String {
        switch self {
        case .entrada: "Relevo de entrada"
        case .colacion: "Colación"
        case .salida: "Relevo de salida"
        case .campamento: "Campamento"
        }
    }

    /// Nombre corto para la línea de momentos de Hoy ("Entrada", "Colación"…).
    var shortTitle: String {
        switch self {
        case .entrada: "Entrada"
        case .colacion: "Colación"
        case .salida: "Salida"
        case .campamento: "Campamento"
        }
    }

    /// "en el relevo de salida", "en la colación": para frases como "La pausa calza ahora, en …".
    var inPhrase: String {
        switch self {
        case .entrada: "en el relevo de entrada"
        case .colacion: "en la colación"
        case .salida: "en el relevo de salida"
        case .campamento: "en el campamento"
        }
    }

    /// Símbolo SF del momento.
    var symbol: String {
        switch self {
        case .entrada: "sunrise.fill"
        case .colacion: "fork.knife"
        case .salida: "sunset.fill"
        case .campamento: "house.fill"
        }
    }

    /// Cualquier momento hace la ruta completa (pedido del usuario: sin molestias, ruta completa).
    /// La pausa rápida de 1 minuto es una elección explícita ("Solo tengo 1 minuto"), no del momento.
    var recipe: RecipeKind { .campamento5 }

    var minutes: Int { recipe.minutes }

    /// Ventanas por tipo de turno (hora local). Turno de día ≈ 08:00-20:00; noche ≈ 20:00-08:00.
    /// Sale de `windows(for:)`: la línea de momentos de Hoy y esta inferencia no pueden discrepar.
    static func infer(date: Date, shift: ShiftType, calendar: Calendar = .current) -> Moment {
        let minute = MomentWindow.minuteOfDay(date, calendar: calendar)
        return windows(for: shift).first { $0.contains(minuteOfDay: minute) }?.moment ?? .campamento
    }

    /// Las cuatro ventanas del turno, en el orden del día laboral (entrada → colación → salida → campamento).
    /// Entre las cuatro cubren las 24 horas sin solaparse.
    static func windows(for shift: ShiftType) -> [MomentWindow] {
        switch shift {
        case .day:
            [MomentWindow(moment: .entrada, startMinute: 4 * 60, endMinute: 9 * 60 + 30),
             MomentWindow(moment: .colacion, startMinute: 9 * 60 + 30, endMinute: 15 * 60),
             MomentWindow(moment: .salida, startMinute: 15 * 60, endMinute: 20 * 60 + 30),
             MomentWindow(moment: .campamento, startMinute: 20 * 60 + 30, endMinute: 4 * 60)]
        case .night:
            [MomentWindow(moment: .entrada, startMinute: 16 * 60, endMinute: 21 * 60 + 30),
             MomentWindow(moment: .colacion, startMinute: 21 * 60 + 30, endMinute: 3 * 60),
             MomentWindow(moment: .salida, startMinute: 3 * 60, endMinute: 8 * 60 + 30),
             MomentWindow(moment: .campamento, startMinute: 8 * 60 + 30, endMinute: 16 * 60)]
        }
    }

    /// Ventana de este momento en el turno dado.
    func window(shift: ShiftType) -> MomentWindow {
        Self.windows(for: shift).first { $0.moment == self }
            ?? MomentWindow(moment: self, startMinute: 0, endMinute: 0)
    }

    /// Instante en que termina la ventana vigente en `date` ("hasta las 20:30").
    static func windowEnd(after date: Date, shift: ShiftType, calendar: Calendar = .current) -> Date {
        let current = infer(date: date, shift: shift, calendar: calendar).window(shift: shift)
        let hour = current.endMinute / 60, minute = current.endMinute % 60
        let sameDay = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
        if sameDay > date { return sameDay }
        let nextDay = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: nextDay) ?? nextDay
    }
}

/// Ventana horaria de un momento, en minutos desde la medianoche local. `endMinute` es menor que
/// `startMinute` cuando la ventana cruza la medianoche (campamento de día, colación de noche).
nonisolated struct MomentWindow: Sendable, Hashable, Identifiable {
    var moment: Moment
    var startMinute: Int
    var endMinute: Int

    var id: Moment { moment }

    func contains(minuteOfDay minute: Int) -> Bool {
        if startMinute <= endMinute { return minute >= startMinute && minute < endMinute }
        return minute >= startMinute || minute < endMinute
    }

    /// "04:00"
    var startLabel: String { Self.clock(startMinute) }
    /// "09:30"
    var endLabel: String { Self.clock(endMinute) }

    static func clock(_ minute: Int) -> String {
        let m = ((minute % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }
}

// MARK: - Momentos de hoy (línea de Hoy)

/// Parada de la línea "Momentos de hoy": un momento del turno con su hora de inicio y su estado.
nonisolated struct MomentStop: Sendable, Hashable, Identifiable {
    nonisolated enum Phase: Sendable, Hashable { case past, now, next }

    var moment: Moment
    /// Hora de inicio ("15:00").
    var start: String
    var phase: Phase
    /// Hubo una pausa contada hoy en este momento.
    var done: Bool

    var id: Moment { moment }
}

extension Moment {
    /// Paradas del día laboral en `now`, en el orden de las ventanas. Pasado / ahora / después se mide
    /// desde el inicio del día laboral (`dayBoundaryHour`): en el turno de noche, a las 13:00 la
    /// entrada de las 16:00 todavía viene, y a las 10:00 ya pasó.
    nonisolated static func stops(now: Date, shift: ShiftType, doneMoments: Set<Moment>, calendar: Calendar = .current) -> [MomentStop] {
        let boundary = shift.dayBoundaryHour * 60
        func offset(_ minute: Int) -> Int { ((minute - boundary) % 1440 + 1440) % 1440 }
        let nowMinute = MomentWindow.minuteOfDay(now, calendar: calendar)
        let nowOffset = offset(nowMinute)
        return windows(for: shift).map { window in
            let phase: MomentStop.Phase
            if window.contains(minuteOfDay: nowMinute) {
                phase = .now
            } else if offset(window.startMinute) < nowOffset {
                phase = .past
            } else {
                phase = .next
            }
            return MomentStop(moment: window.moment, start: window.startLabel, phase: phase,
                              done: doneMoments.contains(window.moment))
        }
    }

    /// Línea bajo los momentos: "La pausa calza ahora, en el relevo de salida." y variantes con pausa hecha.
    nonisolated static func stopsLine(current: Moment, pausedToday: Bool, doneMoments: Set<Moment>) -> String {
        guard pausedToday else { return "La pausa calza ahora, \(current.inPhrase)." }
        if doneMoments.contains(current) { return "Pausa hecha \(current.inPhrase)." }
        return "Pausa de hoy hecha. Si quiere otra, calza ahora, \(current.inPhrase)."
    }
}
