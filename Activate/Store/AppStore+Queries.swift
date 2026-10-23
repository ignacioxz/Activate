import Foundation

// MARK: - Paquete store: consultas y mutaciones de alto nivel sobre `AppStore`.
// `AppStore.swift` es contrato congelado; todo lo de aquí vive en extensiones.
//
// Reglas:
// - `addSession` / `updateSession` / `addCheckIn` solo guardan el registro y aseguran que exista
//   el `WorkDay` de su día laboral. NO tocan `countedPauses` ni `cascoUsed`: ese libro mayor
//   lo lleva `GameStore` (racha, Doblete, casco automático) con `updateWorkDay(forKey:_:)`.
// - Las claves (`workDayKey`, `turnoKey`) salen siempre de `calendar` (WorkCalendar del perfil).
//   Use `makeCheckIn` / `makeSession` para no calcularlas a mano.

extension AppStore {

    // MARK: Claves del calendario laboral

    /// Clave "yyyy-MM-dd" del día laboral que contiene `now`.
    func todayKey(now: Date = .now) -> String { calendar.key(for: now) }

    /// Clave del turno 7×7 (primer día de subida) que contiene `now`.
    func currentTurnoKey(now: Date = .now) -> String { calendar.turnoKey(for: now) }

    // MARK: Días laborales

    func workDay(for key: String) -> WorkDay? { data.workDays[key] }

    /// WorkDay del día laboral que contiene `date` (nil si aún no existe).
    func workDay(on date: Date) -> WorkDay? { data.workDays[calendar.key(for: date)] }

    /// Devuelve el WorkDay del día laboral de `date`; si no existe lo crea con
    /// `kind` / `dayInBlock` / `turnoKey` calculados por `WorkCalendar`.
    @discardableResult
    func ensureWorkDay(for date: Date) -> WorkDay {
        let key = calendar.key(for: date)
        if let existing = data.workDays[key] { return existing }
        let day = newWorkDay(for: date)
        mutate { $0.workDays[key] = day }
        return day
    }

    /// Variante por clave "yyyy-MM-dd"; nil si la clave no se puede interpretar.
    @discardableResult
    func ensureWorkDay(forKey key: String) -> WorkDay? {
        if let existing = data.workDays[key] { return existing }
        guard let day = newWorkDay(forKey: key) else { return nil }
        mutate { $0.workDays[key] = day }
        return day
    }

    /// Modifica (creándolo si hace falta) el WorkDay de una clave. Para `countedPauses` / `cascoUsed`.
    func updateWorkDay(forKey key: String, _ body: (inout WorkDay) -> Void) {
        guard var day = data.workDays[key] ?? newWorkDay(forKey: key) else { return }
        body(&day)
        mutate { $0.workDays[key] = day }
    }

    /// WorkDays registrados de un turno, ordenados por fecha.
    func workDays(inTurno turnoKey: String) -> [WorkDay] {
        data.workDays.values.filter { $0.turnoKey == turnoKey }.sorted { $0.key < $1.key }
    }

    // MARK: Check-ins

    /// Último check-in de fuente `.pausa` (RDQ-6) del día laboral que contiene `now`.
    func todayCheckIn(now: Date = .now) -> DailyCheckIn? {
        let key = calendar.key(for: now)
        return data.checkIns
            .filter { $0.source == .pausa && $0.workDayKey == key }
            .max { $0.date < $1.date }
    }

    /// Check-ins (RDQ-6 y "Me duele ahora") de un día laboral, por fecha.
    func checkIns(onWorkDay key: String) -> [DailyCheckIn] {
        data.checkIns.filter { $0.workDayKey == key }.sorted { $0.date < $1.date }
    }

    /// Check-ins de un turno, por fecha.
    func checkIns(inTurno turnoKey: String) -> [DailyCheckIn] {
        data.checkIns.filter { $0.turnoKey == turnoKey }.sorted { $0.date < $1.date }
    }

    /// Guarda un check-in (reemplaza si ya existe su `id`) y asegura el WorkDay de su día.
    func addCheckIn(_ checkIn: DailyCheckIn) {
        let newDay = data.workDays[checkIn.workDayKey] == nil ? newWorkDay(forKey: checkIn.workDayKey) : nil
        mutate { d in
            if let newDay { d.workDays[newDay.key] = newDay }
            if let i = d.checkIns.firstIndex(where: { $0.id == checkIn.id }) {
                d.checkIns[i] = checkIn
            } else {
                d.checkIns.append(checkIn)
            }
        }
    }

    /// Factoría: check-in con `workDayKey` / `turnoKey` calculados desde `date`.
    /// Zonas (selección múltiple): `zones` si viene; si no, `[zone]`; si no, las zonas habituales del perfil.
    /// Para "Me duele ahora": `source: .meDueleAhora`, `answers: []`, `context`.
    func makeCheckIn(date: Date = .now,
                     source: CheckInSource = .pausa,
                     answers: [Bool],
                     alarmAnswers: [Bool] = [],
                     zone: PainZone? = nil,
                     zones: [PainZone]? = nil,
                     moment: Moment? = nil,
                     context: PainContext? = nil) -> DailyCheckIn {
        var entry = DailyCheckIn(date: date,
                                 workDayKey: calendar.key(for: date),
                                 turnoKey: calendar.turnoKey(for: date),
                                 source: source,
                                 answers: answers,
                                 alarmAnswers: alarmAnswers,
                                 zone: zone ?? profile.usualZone,
                                 moment: moment,
                                 context: context)
        entry.setZones(Self.resolvedZones(zones, zone: zone, fallback: profile.allUsualZones))
        return entry
    }

    /// Selección explícita (vacía = "No me duele") > zona única > zonas de respaldo.
    nonisolated static func resolvedZones(_ zones: [PainZone]?, zone: PainZone?, fallback: [PainZone]) -> [PainZone] {
        if let zones { return PainZone.ordered(zones) }
        if let zone { return [zone] }
        return PainZone.ordered(fallback)
    }

    // MARK: Sesiones

    func session(id: UUID) -> PauseSession? { data.sessions.first { $0.id == id } }

    /// Sesiones de un día laboral, por inicio.
    func sessions(onWorkDay key: String) -> [PauseSession] {
        data.sessions.filter { $0.workDayKey == key }.sorted { $0.startedAt < $1.startedAt }
    }

    /// Sesiones de un turno, por inicio.
    func sessions(inTurno turnoKey: String) -> [PauseSession] {
        data.sessions.filter { $0.turnoKey == turnoKey }.sorted { $0.startedAt < $1.startedAt }
    }

    /// Guarda una sesión nueva (si el `id` ya existe la reemplaza) y asegura el WorkDay de su día.
    /// No cambia `countedPauses`: eso lo hace `GameStore.record`.
    func addSession(_ session: PauseSession) { upsertSession(session) }

    /// Reemplaza la sesión con el mismo `id` (si no existe, la agrega).
    func updateSession(_ session: PauseSession) { upsertSession(session) }

    func removeSession(id: UUID) {
        mutate { $0.sessions.removeAll { $0.id == id } }
    }

    /// Factoría: sesión recién iniciada con claves, receta del momento, zonas (las dadas, las del
    /// RDQ-6 de hoy o las habituales del perfil) y el snapshot del RDQ-6 de hoy si ya se respondió.
    func makeSession(moment: Moment, startedAt: Date = .now, zone: PainZone? = nil, zones: [PainZone]? = nil) -> PauseSession {
        let checkIn = todayCheckIn(now: startedAt)
        var session = PauseSession(workDayKey: calendar.key(for: startedAt),
                                   turnoKey: calendar.turnoKey(for: startedAt),
                                   recipe: moment.recipe,
                                   moment: moment,
                                   startedAt: startedAt,
                                   checkInScore: checkIn?.score,
                                   checkInAnswers: checkIn?.answers ?? [],
                                   zone: zone ?? checkIn?.zone ?? profile.usualZone)
        session.setZones(Self.resolvedZones(zones, zone: zone, fallback: checkIn?.allZones ?? profile.allUsualZones))
        return session
    }

    // MARK: Perfil, demo y cachés

    func setProfile(_ profile: PlayerProfile) {
        mutate { $0.profile = profile }
    }

    func updateProfile(_ body: (inout PlayerProfile) -> Void) {
        mutate { body(&$0.profile) }
    }

    func setDemo(_ demo: DemoConfig) {
        mutate { $0.demo = demo }
    }

    var isDemo: Bool { data.demo.enabled }

    /// Lectura del coach ya redactada para un día laboral (nil la borra).
    func cacheStatsReading(_ text: String?, forWorkDay key: String) {
        mutate { $0.statsReadingCache[key] = text }
    }

    func setKineSheetJSON(_ json: String?) {
        mutate { $0.lastKineSheetJSON = json }
    }

    /// Borra todo y vuelve al estado inicial (perfil por defecto con `rosterStart` = hoy, demo apagada).
    func resetAll(now: Date = .now) {
        replace(with: SaveData(profile: PlayerProfile(rosterStart: Calendar.current.startOfDay(for: now))))
    }

    // MARK: - Privado

    private func newWorkDay(for date: Date) -> WorkDay {
        WorkDay(key: calendar.key(for: date),
                kind: calendar.kind(for: date),
                dayInBlock: calendar.dayInBlock(for: date),
                turnoKey: calendar.turnoKey(for: date))
    }

    private func newWorkDay(forKey key: String) -> WorkDay? {
        guard let date = dateInsideWorkDay(forKey: key) else { return nil }
        return newWorkDay(for: date)
    }

    /// Un instante dentro del día laboral `key`: su medianoche de calendario más la hora de corte
    /// (`WorkCalendar.date(forKey:)` devuelve la medianoche, que cae en el día laboral anterior).
    private func dateInsideWorkDay(forKey key: String) -> Date? {
        guard let midnight = calendar.date(forKey: key) else { return nil }
        return calendar.calendar.date(byAdding: .hour, value: calendar.boundaryHour, to: midnight)
    }

    private func upsertSession(_ session: PauseSession) {
        let newDay = data.workDays[session.workDayKey] == nil ? newWorkDay(forKey: session.workDayKey) : nil
        mutate { d in
            if let newDay { d.workDays[newDay.key] = newDay }
            if let i = d.sessions.firstIndex(where: { $0.id == session.id }) {
                d.sessions[i] = session
            } else {
                d.sessions.append(session)
            }
        }
    }
}
