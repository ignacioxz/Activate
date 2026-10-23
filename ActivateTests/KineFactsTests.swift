import Testing
import Foundation
@testable import Activate

/// Hechos para la consulta con el kine (Swift puro): qué sale, en qué orden y con qué cifras.
struct KineFactsTests {
    private var santiago: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Santiago")!
        return c
    }

    private var now: Date { santiago.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 15))! }

    private func facts(_ data: SaveData) -> [KineFact] {
        let summary = StatsEngine.summary(data: data, calendar: WorkCalendar(profile: data.profile, calendar: santiago), now: now)
        return KineFacts.build(data: data, summary: summary, calendar: santiago)
    }

    private func value(_ facts: [KineFact], _ id: KineFactID) -> String? {
        facts.first { $0.id == id.rawValue }?.value
    }

    @Test func demoDeMarcoTieneLosOchoHechosEnOrden() {
        let f = facts(DemoSeed.data(now: now, calendar: santiago))
        #expect(f.map(\.id) == ["rdq_tendencia", "peor_fase_turno", "contexto_dominante", "item_frecuente",
                                "mejora_post", "ejercicio_que_ayuda", "alertas", "adherencia"])
        #expect(value(f, .rdqTendencia) == "4,0 → 3,6 → 3,0")
        #expect(value(f, .peorFaseTurno) == "Día 5: 6,0 de 6")
        #expect(value(f, .contextoDominante) == "Al bajar · 2 de 4")
        #expect(value(f, .itemFrecuente) == "11 de 11 días")
        #expect(value(f, .mejoraPost) == "6 de 8 pausas")  // el día 7 del turno B es check-in sin pausa
        #expect(value(f, .ejercicioQueAyuda) == "Caminata · 5 de 6")
        #expect(value(f, .alertas) == "2 días con RDQ 5 o más")
        #expect(value(f, .adherencia) == "8 de 16 días")
        // Ids estables y conocidos; cada hecho trae frase sin cifras, pregunta en primera persona y foco.
        #expect(Set(f.map(\.id)).isSubset(of: Set(KineFactID.all)))
        for fact in f {
            #expect(!fact.gist.isEmpty && !fact.detail.isEmpty && !fact.focus.isEmpty, "\(fact.id)")
            #expect(fact.question.contains("¿") && fact.question.hasSuffix("?"), "\(fact.id)")
            #expect(!fact.mustInclude)
            #expect(!KineConsultRules.hasClinicalTerm(fact.detail + fact.gist + fact.question + fact.focus))
        }
        // El detalle trae las cifras; la frase simple no trae dígitos salvo el día del turno.
        #expect(f.first { $0.id == "rdq_tendencia" }?.detail.contains("bajó 0,6 puntos") == true)
        #expect(f.first { $0.id == "peor_fase_turno" }?.gist == "El día 5 del turno es el de más dolor de espalda.")
        #expect(f.first { $0.id == "contexto_dominante" }?.gist == "Le duele más al bajar del camión que en otros momentos.")
        #expect(f.first { $0.id == "item_frecuente" }?.gist == "Todos los días marca que camina más lento que lo habitual.")
    }

    @Test func sinRegistrosNoHayHechos() {
        let data = SaveData(profile: PlayerProfile(rosterStart: santiago.date(from: DateComponents(year: 2026, month: 10, day: 22))!))
        #expect(facts(data).isEmpty)
        let consult = KineConsultRules.template([], profile: data.profile)
        #expect(consult.findings.isEmpty && consult.questions.count == 3)
    }

    @Test func unaAlarmaVaPrimeroYEsObligatoria() {
        var data = DemoSeed.data(now: now, calendar: santiago)
        let i = data.checkIns.lastIndex { $0.source == .pausa }!
        data.checkIns[i].alarmAnswers = [false, false, true]
        let f = facts(data)
        #expect(f.first?.id == "alertas")
        #expect(f.first?.mustInclude == true)
        #expect(f.first?.value == "1 respuesta de alarma")
        #expect(f.first?.detail.contains(RDQ6.alarmQuestions[2]) == true)
        #expect(KineConsultRules.template(f, profile: data.profile).findings.first?.factID == "alertas")
    }

    @Test func contextoNecesitaDosRegistrosYCuentaZonasMultiples() {
        let profile = PlayerProfile(rosterStart: santiago.date(from: DateComponents(year: 2026, month: 10, day: 19))!)
        func pain(_ day: Int, _ context: PainContext, zones: [PainZone]) -> DailyCheckIn {
            let date = santiago.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 13))!
            var c = DailyCheckIn(date: date, workDayKey: "2026-10-\(day)", turnoKey: "2026-10-19", source: .meDueleAhora,
                                 answers: [], zone: zones[0], moment: .colacion, context: context)
            c.setZones(zones)
            return c
        }
        #expect(KineFacts.contextoDominante([pain(20, .enCabina, zones: [.cuello])]) == nil)
        let fact = KineFacts.contextoDominante([pain(20, .enCabina, zones: [.cuello]), pain(21, .enCabina, zones: [.lumbar, .cuello]),
                                                pain(22, .enElBus, zones: [.hombro])])
        #expect(fact?.value == "En cabina · 2 de 3")
        #expect(fact?.detail.contains("Zonas: espalda baja, cuello y hombro.") == true)
        #expect(fact?.detail.contains("Momento más frecuente: colación.") == true)
        #expect(fact?.question == "¿Cómo me acomodo en la cabina para que no me duela?")
        _ = profile
    }

    @Test func ejercicioQueEstaEnTodasLasPausasNoSePuedeComparar() {
        func session(_ kinds: [ActivityKind], post: PostResponse, level: VerificationLevel = .full, simulated: Bool = false) -> PauseSession {
            var s = PauseSession(workDayKey: "2026-10-20", turnoKey: "2026-10-19", recipe: .colacion3, moment: .colacion, startedAt: now)
            s.activities = kinds.map { ActivityResult(kind: $0, target: 1, achieved: 1, durationSeconds: 10, completed: true,
                                                       level: level, metrics: .none, anomalies: []) }
            s.postResponse = post
            s.level = level
            s.simulated = simulated
            return s
        }
        // Cuello en todas: no hay grupo "sin cuello" → no sale.
        let same = [session([.cuello], post: .mejor), session([.cuello], post: .mejor), session([.cuello], post: .igual),
                    session([.cuello], post: .igual)]
        #expect(KineFacts.ejercicioQueAyuda(same) == nil)
        // Caminata: 2 de 2 con, 0 de 2 sin → sale; los reflejos nunca se proponen.
        let mixed = [session([.pasos, .cuello], post: .mejor), session([.pasos, .stroop], post: .mejor),
                     session([.cuello, .stroop], post: .igual), session([.cuello], post: .peor)]
        let fact = KineFacts.ejercicioQueAyuda(mixed)
        #expect(fact?.value == "Caminata · 2 de 2")
        #expect(fact?.detail == "Las pausas con caminata terminaron Mejor 2 de 2 veces; sin caminata, 0 de 2.")
        // Simuladas y sospechosas no entran en los hechos.
        var data = SaveData(profile: PlayerProfile(rosterStart: santiago.date(from: DateComponents(year: 2026, month: 10, day: 19))!))
        data.sessions = mixed.map { var s = $0; s.simulated = true; return s }
        #expect(facts(data).allSatisfy { $0.id != "ejercicio_que_ayuda" && $0.id != "mejora_post" })
    }

    @Test func firmaCambiaConLasCifras() {
        let a = facts(DemoSeed.data(now: now, calendar: santiago))
        var b = a
        b[0].value = "4,0 → 3,6 → 2,0"
        #expect(KineConsultRules.signature(a) == KineConsultRules.signature(a))
        #expect(KineConsultRules.signature(a) != KineConsultRules.signature(b))
    }
}
