import Foundation

/// Lógica pura de racha y casco automático sobre el libro mayor `[String: WorkDay]`.
/// No guarda estado ni mira el reloj: siempre recibe el `WorkCalendar` y una fecha de referencia,
/// así se prueba con turnos de día y de noche sin tocar `.now`.
///
/// Reglas (docs/PLAN.md, "Gamificación"):
/// - Racha = días laborales de subida consecutivos con `countedPauses ≥ 1`.
/// - Los días de descanso no cortan ni suman (la bajada es un freeze automático).
/// - Un día con `cascoUsed` mantiene la racha sin sumar.
/// - Hoy sin pausa contada todavía no corta: se mira desde ayer.
/// - Casco automático: al cerrar un día de turno sin pausa contada, si el turno todavía tiene
///   casco (1 por turno de subida, repuesto el día 1), se marca solo. Solo protege días
///   posteriores a la primera pausa contada: antes no hay racha que cuidar.
nonisolated enum StreakEngine {
    /// Tope de días hacia atrás al recorrer el libro mayor.
    static let maxLookbackDays = 400
    /// Cascos con que parte cada turno de subida. Se reponen el día 1 y no se acumulan.
    static let cascosPerTurno = 1
    /// Bloques de turno que revisa el cierre automático: el vigente (o el último) y el anterior.
    static let rolloverLookbackBlocks = 2
    /// Horas sobre el cambio de día para ubicar un instante seguro dentro de un día laboral.
    static let instantMarginHours = 1

    nonisolated struct RolloverResult: Sendable, Equatable {
        var days: [String: WorkDay]
        /// Cascos que quedan disponibles en el bloque de turno vigente (o el último, en bajada).
        var cascos: Int
        /// Claves de los días marcados con casco en esta pasada, en orden cronológico.
        var protected: [String]
    }

    // MARK: - Fechas y claves

    /// Instante dentro del día laboral cuya medianoche (de calendario) es `workDate`.
    static func instant(ofWorkDate workDate: Date, calendar: WorkCalendar) -> Date {
        calendar.calendar.date(byAdding: .hour, value: calendar.boundaryHour + instantMarginHours, to: workDate) ?? workDate
    }

    /// Instante dentro del día laboral `key` ("yyyy-MM-dd"); nil si la clave está mal formada.
    static func instant(forKey key: String, calendar: WorkCalendar) -> Date? {
        guard let midnight = calendar.date(forKey: key) else { return nil }
        return instant(ofWorkDate: midnight, calendar: calendar)
    }

    static func key(ofWorkDate workDate: Date, calendar: WorkCalendar) -> String {
        WorkCalendar.key(ofWorkDate: workDate, calendar: calendar.calendar)
    }

    static func previous(_ workDate: Date, calendar: WorkCalendar) -> Date {
        calendar.calendar.date(byAdding: .day, value: -1, to: workDate) ?? workDate
    }

    static func kind(ofWorkDate workDate: Date, calendar: WorkCalendar) -> DayKind {
        calendar.kind(for: instant(ofWorkDate: workDate, calendar: calendar))
    }

    /// `true` si `workDate` es un día de calendario anterior a `other`.
    static func isBefore(_ workDate: Date, _ other: Date, calendar: WorkCalendar) -> Bool {
        calendar.calendar.compare(workDate, to: other, toGranularity: .day) == .orderedAscending
    }

    /// Registro del día laboral: el existente, o una plantilla con tipo, día del bloque y turno.
    static func workDay(ofWorkDate workDate: Date, in days: [String: WorkDay], calendar: WorkCalendar) -> WorkDay {
        let key = key(ofWorkDate: workDate, calendar: calendar)
        if let existing = days[key] { return existing }
        let instant = instant(ofWorkDate: workDate, calendar: calendar)
        return WorkDay(key: key,
                       kind: calendar.kind(for: instant),
                       dayInBlock: calendar.dayInBlock(for: instant),
                       turnoKey: calendar.turnoKey(for: instant))
    }

    /// Igual que `workDay(ofWorkDate:in:calendar:)` a partir de la clave; nil si está mal formada.
    static func workDay(forKey key: String, in days: [String: WorkDay], calendar: WorkCalendar) -> WorkDay? {
        guard let midnight = calendar.date(forKey: key) else { return nil }
        return workDay(ofWorkDate: midnight, in: days, calendar: calendar)
    }

    // MARK: - Racha

    static func isCounted(_ day: WorkDay?) -> Bool { (day?.countedPauses ?? 0) > 0 }

    /// Medianoche laboral del primer día con pausa contada del libro mayor (nil si no hay ninguno).
    static func earliestCountedWorkDate(days: [String: WorkDay], calendar: WorkCalendar) -> Date? {
        days.values
            .filter { isCounted($0) }
            .compactMap { calendar.date(forKey: $0.key) }
            .min()
    }

    /// Racha vigente en el instante `date`.
    static func streak(days: [String: WorkDay], calendar: WorkCalendar, at date: Date) -> Int {
        var cursor = calendar.workDate(for: date)
        // Hoy sin pausa contada todavía no corta la racha: se parte desde ayer.
        if !isCounted(days[key(ofWorkDate: cursor, calendar: calendar)]) {
            cursor = previous(cursor, calendar: calendar)
        }
        var count = 0
        for _ in 0..<maxLookbackDays {
            if kind(ofWorkDate: cursor, calendar: calendar) == .turno {
                let day = days[key(ofWorkDate: cursor, calendar: calendar)]
                if isCounted(day) {
                    count += 1
                } else if day?.cascoUsed != true {
                    break
                }
            }
            cursor = previous(cursor, calendar: calendar)
        }
        return count
    }

    /// Ayer fue día de turno con pausa contada (condición del Doblete).
    static func previousWorkDayCounted(days: [String: WorkDay], calendar: WorkCalendar, at date: Date) -> Bool {
        let yesterday = previous(calendar.workDate(for: date), calendar: calendar)
        return kind(ofWorkDate: yesterday, calendar: calendar) == .turno
            && isCounted(days[key(ofWorkDate: yesterday, calendar: calendar)])
    }

    /// Ayer laboral contado y hoy (día de turno) todavía sin pausa contada.
    static func dobleteAvailable(days: [String: WorkDay], calendar: WorkCalendar, at date: Date) -> Bool {
        let today = calendar.workDate(for: date)
        guard kind(ofWorkDate: today, calendar: calendar) == .turno,
              !isCounted(days[key(ofWorkDate: today, calendar: calendar)]) else { return false }
        return previousWorkDayCounted(days: days, calendar: calendar, at: date)
    }

    /// Ayer se marcó el casco automático ("Ayer usó el casco. Racha a salvo.").
    static func usedCascoYesterday(days: [String: WorkDay], calendar: WorkCalendar, at date: Date) -> Bool {
        let yesterday = previous(calendar.workDate(for: date), calendar: calendar)
        return days[key(ofWorkDate: yesterday, calendar: calendar)]?.cascoUsed == true
    }

    /// Días con pausa contada del bloque de turno que contiene `date` (o el último, en bajada).
    static func countedDays(days: [String: WorkDay], calendar: WorkCalendar, turnoContaining date: Date) -> Int {
        calendar.workDatesOfTurno(containing: date)
            .filter { isCounted(days[key(ofWorkDate: $0, calendar: calendar)]) }
            .count
    }

    /// Todos los días del bloque de turno que contiene `date` tienen pausa contada.
    static func isTiroLimpio(days: [String: WorkDay], calendar: WorkCalendar, turnoContaining date: Date) -> Bool {
        let dates = calendar.workDatesOfTurno(containing: date)
        return !dates.isEmpty && dates.allSatisfy { isCounted(days[key(ofWorkDate: $0, calendar: calendar)]) }
    }

    // MARK: - Casco automático

    /// Cierra los días de turno anteriores a `now` sin pausa contada: el primero de cada bloque
    /// que no tenga casco lo recibe, mientras al bloque le quede alguno y haya una racha anterior
    /// que proteger (algún día contado antes). Es idempotente: el casco de un bloque se deduce de
    /// sus propios días (`cascoUsed`), así revisar dos veces no cambia nada.
    static func rollover(days input: [String: WorkDay], calendar: WorkCalendar, now: Date) -> RolloverResult {
        var days = input
        let today = calendar.workDate(for: now)
        let origin = earliestCountedWorkDate(days: days, calendar: calendar)
        var protected: [String] = []
        var cascosVigentes = cascosPerTurno
        var anchor: Date? = today

        for blockIndex in 0..<rolloverLookbackBlocks {
            guard let from = anchor,
                  let turnoDate = latestTurnoWorkDate(onOrBefore: from, calendar: calendar) else { break }
            let turnoDates = calendar.workDatesOfTurno(containing: instant(ofWorkDate: turnoDate, calendar: calendar))
            guard let first = turnoDates.first else { break }

            let used = turnoDates.filter { days[key(ofWorkDate: $0, calendar: calendar)]?.cascoUsed == true }.count
            var available = max(0, cascosPerTurno - used)
            var marked: [String] = []
            for workDate in turnoDates where isBefore(workDate, today, calendar: calendar) {
                let key = key(ofWorkDate: workDate, calendar: calendar)
                let existing = days[key]
                if isCounted(existing) || existing?.cascoUsed == true { continue }
                guard available > 0 else { break }
                // Sin pausa contada anterior no hay racha que cuidar: el casco se guarda.
                guard let origin, isBefore(origin, workDate, calendar: calendar) else { continue }
                var day = existing ?? workDay(ofWorkDate: workDate, in: days, calendar: calendar)
                day.cascoUsed = true
                days[key] = day
                available -= 1
                marked.append(key)
            }
            if blockIndex == 0 { cascosVigentes = available }
            protected = marked + protected
            anchor = previous(first, calendar: calendar)
        }
        return RolloverResult(days: days, cascos: cascosVigentes, protected: protected)
    }

    /// Último día de turno (medianoche laboral) en o antes de `workDate`.
    static func latestTurnoWorkDate(onOrBefore workDate: Date, calendar: WorkCalendar) -> Date? {
        var cursor = workDate
        for _ in 0...calendar.cycleLength {
            if kind(ofWorkDate: cursor, calendar: calendar) == .turno { return cursor }
            cursor = previous(cursor, calendar: calendar)
        }
        return nil
    }
}
