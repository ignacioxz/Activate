import Foundation

// Dueño: paquete "kine-ai". Reglas puras de la consulta con el kine (sin FoundationModels):
// ids estables de los hechos, plantilla con la misma forma que la salida del modelo, validación
// en Swift de lo que propone el modelo y saneamiento del resumen de la nota del paciente.

/// Ids estables de los hechos que calcula `KineFacts`. El `@Guide(.anyOf(...))` de `Hallazgo`
/// lleva la misma lista como literal (los tests comparan ambas).
nonisolated enum KineFactID: String, CaseIterable, Sendable {
    case rdqTendencia = "rdq_tendencia"
    case peorFaseTurno = "peor_fase_turno"
    case contextoDominante = "contexto_dominante"
    case mejoraPost = "mejora_post"
    case adherencia = "adherencia"
    case itemFrecuente = "item_frecuente"
    case ejercicioQueAyuda = "ejercicio_que_ayuda"
    case alertas = "alertas"
    /// Nivel de pausas completas (`LevelProgress`, calculado en Swift; el modelo solo lo cita).
    case nivel = "nivel"

    static let all: [String] = allCases.map(\.rawValue)
}

nonisolated enum KineConsultRules {
    // MARK: Límites (nombrados; se calibran con el kine)

    static let findingsCount = 3
    static let questionsCount = 3
    static let maxFindingWords = 20
    static let maxQuestionWords = 18
    static let maxFocusWords = 22
    static let maxSummaryWords = 45

    /// Términos que no van en un texto del coach para el kine: diagnósticos y fármacos.
    static let clinicalBanned: [String] = [
        "hernia", "ciática", "ciatica", "lumbago", "artrosis", "escoliosis", "discopatía", "discopatia",
        "protrusión", "protrusion", "tendinitis", "fractura", "diagnóstico", "diagnostico", "diagnostica",
        "fármaco", "farmaco", "medicamento", "pastilla", "ibuprofeno", "paracetamol", "antiinflamatorio",
        "relajante muscular", "inyección", "inyeccion", "cirugía", "cirugia", "operación", "operacion",
    ]

    /// Lo que propone el modelo, ya en tipos de la app.
    nonisolated struct Proposal: Sendable, Hashable {
        var findings: [KineFinding]
        var questions: [String]
        var focus: String
    }

    nonisolated enum Failure: Error, Equatable, Sendable {
        case noFacts
        case unknownFact(String)
        case duplicateFact(String)
        case wrongCount(Int)
    }

    // MARK: - Plantilla (misma forma que el modelo)

    /// Los 3 primeros hechos (vienen en orden de prioridad), sus preguntas y el foco del primero.
    static func template(_ facts: [KineFact], profile: PlayerProfile) -> KineConsult {
        let chosen = Array(facts.prefix(findingsCount))
        let findings = chosen.map { KineFinding(factID: $0.id, sentence: templateSentence($0)) }
        return KineConsult(findings: findings,
                           questions: templateQuestions(for: chosen, all: facts),
                           focus: chosen.first.map(\.focus).flatMap(nonEmpty) ?? genericFocus,
                           backend: .rules)
    }

    /// Frase de plantilla de un hecho: la versión sin cifras (o el detalle si no hay).
    static func templateSentence(_ fact: KineFact) -> String {
        nonEmpty(fact.gist) ?? fact.detail
    }

    static let genericFocus = "Revisar qué ejercicios le convienen para la espalda durante el turno."

    static let genericQuestions: [String] = [
        "¿Qué ejercicio puedo hacer sentado en la cabina?",
        "¿Cuánto rato puedo estar sentado sin hacer una pausa?",
        "¿Qué señales de dolor me deben hacer consultar antes?",
    ]

    /// Pregunta de cada hecho elegido; si faltan, las del resto de los hechos y luego las genéricas.
    static func templateQuestions(for chosen: [KineFact], all facts: [KineFact]) -> [String] {
        var out: [String] = []
        let pool = chosen.map(\.question) + facts.map(\.question) + genericQuestions
        for q in pool where out.count < questionsCount {
            let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !out.contains(t) { out.append(t) }
        }
        return out
    }

    // MARK: - Validación de lo que propone el modelo

    /// Ids: un id que no está entre los hechos invalida todo (plantilla completa). Un id repetido deja
    /// su lugar al hecho más prioritario que falte (con su frase y pregunta de plantilla), siempre que
    /// el modelo haya elegido bien los demás; si repite más de uno, plantilla completa. Textos: cada frase,
    /// pregunta o foco que no pase la limpieza (vacío, largo, palabras prohibidas, diagnóstico, cifras que
    /// no están en los hechos, preguntas que no están en primera persona) se cambia por el de plantilla.
    static func validate(_ proposal: Proposal, facts: [KineFact], profile: PlayerProfile) -> Result<KineConsult, Failure> {
        guard !facts.isEmpty else { return .failure(.noFacts) }
        let byID = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let expected = min(findingsCount, facts.count)
        let corpus = groundingCorpus(facts, profile: profile)
        let level = computedLevel(in: facts)

        // Lugares del modelo: (hecho, frase, pregunta del modelo en el mismo orden) o nil si repitió.
        var slots: [(fact: KineFact, sentence: String, question: String?)?] = []
        var seen = Set<String>()
        var duplicate: String?
        for (i, f) in proposal.findings.enumerated() {
            let id = f.factID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let fact = byID[id] else { return .failure(.unknownFact(f.factID)) }
            guard seen.insert(id).inserted else {
                duplicate = duplicate ?? id
                slots.append(nil)
                continue
            }
            let question = proposal.questions.indices.contains(i)
                ? cleanQuestion(proposal.questions[i], corpus: corpus, profile: profile, level: level) : nil
            slots.append((fact, cleanFinding(f.sentence, fact: fact) ?? templateSentence(fact), question))
        }
        let picked = slots.compactMap { $0 }.count
        if let duplicate, picked < expected - 1 { return .failure(.duplicateFact(duplicate)) }
        guard picked + slots.filter({ $0 == nil }).count >= expected else { return .failure(.wrongCount(picked)) }

        // Rellena los repetidos con los hechos más prioritarios que falten (frase y pregunta de plantilla).
        var spare = facts.filter { !seen.contains($0.id) }.makeIterator()
        var findings: [KineFinding] = []
        var slotQuestions: [String] = []
        for slot in slots where findings.count < expected {
            if let slot {
                findings.append(KineFinding(factID: slot.fact.id, sentence: slot.sentence))
                slotQuestions.append(slot.question ?? slot.fact.question)
            } else if facts.count >= findingsCount, let fact = spare.next() {
                findings.append(KineFinding(factID: fact.id, sentence: templateSentence(fact)))
                slotQuestions.append(fact.question)
            }
        }
        guard findings.count == expected else { return .failure(.wrongCount(findings.count)) }

        // Un hecho obligatorio (alarma) que el modelo no eligió reemplaza al último no obligatorio.
        for must in facts where must.mustInclude && !findings.contains(where: { $0.factID == must.id }) {
            if let idx = findings.lastIndex(where: { !(byID[$0.factID]?.mustInclude ?? false) }) {
                findings[idx] = KineFinding(factID: must.id, sentence: templateSentence(must))
                slotQuestions[idx] = must.question
            }
        }

        let chosen = findings.compactMap { byID[$0.factID] }
        let fallbackQuestions = templateQuestions(for: chosen, all: facts)
        var questions: [String] = []
        for q in slotQuestions where !q.isEmpty && !questions.contains(q) && questions.count < questionsCount {
            questions.append(q)
        }
        for q in fallbackQuestions where questions.count < questionsCount && !questions.contains(q) {
            questions.append(q)
        }

        let templateFocus = chosen.first.map(\.focus).flatMap(nonEmpty) ?? genericFocus
        let focus = cleanProse(proposal.focus, maxWords: maxFocusWords, corpus: corpus, truncate: false)
            .flatMap { levelMentionsAreGrounded($0, level: level) ? $0 : nil } ?? templateFocus

        return .success(KineConsult(findings: findings, questions: questions, focus: focus, backend: .foundationModels))
    }

    /// Un hallazgo describe; no evalúa. Si trae un juicio que el hecho no dice, va la frase de plantilla.
    static let judgmentTerms: [String] = [
        "requiere", "requieren", "atención especial", "preocupa", "grave", "urgente", "riesgo", "peligro",
        "debería", "deberia", "necesita", "es importante", "alarmante",
    ]

    /// Frase de un hallazgo: limpia, ≤ 20 palabras (sin recortar: una frase cortada no sirve), sin
    /// diagnóstico ni juicios y con cifras (también escritas con letras) que estén en el hecho. Ningún
    /// hallazgo dice un número de nivel ("nivel 6", "nivel uno"): el nivel lo muestra la app.
    static func cleanFinding(_ text: String, fact: KineFact) -> String? {
        let corpus = findingCorpus(fact)
        guard let clean = cleanProse(text, maxWords: maxFindingWords, corpus: corpus, truncate: false) else { return nil }
        let lower = clean.lowercased(), source = corpus.lowercased()
        guard !judgmentTerms.contains(where: { lower.contains($0) && !source.contains($0) }) else { return nil }
        guard levelMentionsAreGrounded(clean, level: nil) else { return nil }
        return clean
    }

    /// Texto contra el que se anclan las cifras de un hallazgo: título, cifra, resumen y detalle del hecho.
    /// El hecho "nivel" se ancla solo a su resumen, que no trae cifras: su detalle tiene otros números
    /// (el nivel siguiente, los días con pausa, el porcentaje) con los que el modelo podría "dar" un
    /// nivel equivocado ("Está en el nivel 6", "nivel ocho") que igual estaría en el corpus. La frase del
    /// nivel va sin cifras; la cifra la pone el chip de la app ("Nivel 7 · 43 %").
    static func findingCorpus(_ fact: KineFact) -> String {
        if fact.id == KineFactID.nivel.rawValue { return fact.gist }
        return [fact.title, fact.value, fact.gist, fact.detail].joined(separator: " ")
    }

    /// `truncate == false`: si pasa del máximo de palabras se descarta (en vez de cortarla).
    static func cleanProse(_ text: String, maxWords: Int, corpus: String, truncate: Bool = true) -> String? {
        if !truncate && CoachText.wordCount(text) > maxWords { return nil }
        guard let clean = CoachText.clean(text, maxWords: maxWords) else { return nil }
        guard !hasClinicalTerm(clean), numbersAreGrounded(clean, in: corpus) else { return nil }
        return clean
    }

    /// Marcas de primera persona: una pregunta que no tiene ninguna está dicha por otro ("¿Qué le conviene?").
    static let firstPersonMarkers: Set<String> = [
        "me", "mi", "mis", "yo", "conmigo", "puedo", "debo", "hago", "tengo", "estoy", "siento", "sigo", "voy",
        "cambio", "llego", "bajo", "subo", "camino", "aguanto", "evito", "necesito", "manejo", "mejoro", "agacho",
        "duermo", "hacerme", "ayudarme", "sirve", "conviene",
    ]

    /// Pregunta en primera persona: entre "¿" y "?", ≤ 18 palabras sin recortar, sin el nombre ni
    /// "el paciente", con alguna marca de primera persona ("me", "mi", "puedo", "hago"…) y, si nombra un
    /// nivel con cifra, el que calculó la app (`level`; ver `levelMentionsAreGrounded`).
    static func cleanQuestion(_ text: String, corpus: String, profile: PlayerProfile,
                              level: ComputedLevel? = nil) -> String? {
        guard var q = cleanProse(text, maxWords: maxQuestionWords, corpus: corpus, truncate: false) else { return nil }
        guard levelMentionsAreGrounded(q, level: level) else { return nil }
        let lower = q.lowercased()
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.contains("el paciente") || lower.contains("la paciente") || (!name.isEmpty && lower.contains(name)) {
            return nil
        }
        let words = Set(lower.split(whereSeparator: { !$0.isLetter }).map(String.init))
        guard !words.isDisjoint(with: firstPersonMarkers) else { return nil }
        // "conviene" solo cuenta con "me" ("¿Me conviene…?"), no con "le" ("¿Qué le conviene…?").
        if words.contains("le") && words.isDisjoint(with: firstPersonMarkers.subtracting(["conviene", "sirve"])) { return nil }
        while let last = q.last, ".!".contains(last) { q.removeLast() }
        if !q.contains("¿") { q = "¿" + q }
        if !q.hasSuffix("?") { q += "?" }
        return q
    }

    static func hasClinicalTerm(_ text: String) -> Bool {
        let lower = text.lowercased()
        return clinicalBanned.contains { lower.contains($0) }
    }

    /// Números del texto ("3", "3,6", "80") que no aparezcan en el corpus → la frase inventa cifras.
    static func numbersAreGrounded(_ text: String, in corpus: String) -> Bool {
        let allowed = Set(numbers(in: corpus))
        return numbers(in: text).allSatisfy { allowed.contains($0) }
    }

    static func numbers(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            if c.isASCII && c.isNumber {
                current.append(c)
            } else if (c == "," || c == "."), !current.isEmpty, i + 1 < chars.count, chars[i + 1].isASCII, chars[i + 1].isNumber {
                current.append(",")
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        // "2.400" (miles) y "2400" son la misma cifra: se comparan sin separadores de miles.
        out = out.map { isThousands($0) ? $0.replacingOccurrences(of: ",", with: "") : $0 }
        // Cifras escritas con letras ("dos de cada seis", "el quinto día") también cuentan.
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            if let n = numberWords[String(word)] { out.append(n) }
        }
        return out
    }

    /// Números escritos con letras (sin "uno/una/primer": son demasiado comunes en el habla).
    static let numberWords: [String: String] = [
        "dos": "2", "tres": "3", "cuatro": "4", "cinco": "5", "seis": "6", "siete": "7", "ocho": "8",
        "nueve": "9", "diez": "10", "once": "11", "doce": "12", "catorce": "14", "quince": "15",
        "segundo": "2", "segunda": "2", "tercer": "3", "tercero": "3", "tercera": "3", "cuarto": "4", "cuarta": "4",
        "quinto": "5", "quinta": "5", "sexto": "6", "sexta": "6", "séptimo": "7", "séptima": "7",
        "octavo": "8", "octava": "8", "noveno": "9", "novena": "9", "décimo": "10", "décima": "10",
    ]

    /// "2,400" o "12,345,678": grupos de 3 dígitos tras el primero (separador de miles, no decimal).
    static func isThousands(_ token: String) -> Bool {
        let groups = token.split(separator: ",", omittingEmptySubsequences: false)
        guard groups.count > 1, let first = groups.first, (1...3).contains(first.count) else { return false }
        return groups.dropFirst().allSatisfy { $0.count == 3 }
    }

    // MARK: - Nivel (LevelProgress): el modelo nunca da la cifra

    /// Nivel que calculó Swift (`LevelProgress`) y el siguiente, leídos de la cifra del hecho "nivel".
    nonisolated struct ComputedLevel: Sendable, Hashable {
        var level: Int
        var next: Int { level + 1 }
    }

    /// El nivel de la cifra del hecho "nivel" ("Nivel 7 · 43 %" → 7; la arma `LevelProgress.shortValue`
    /// con el nivel primero). `nil` si no hay hecho de nivel (sin pausas verificadas).
    static func computedLevel(in facts: [KineFact]) -> ComputedLevel? {
        guard let fact = facts.first(where: { $0.id == KineFactID.nivel.rawValue }),
              let first = numbers(in: fact.value).first, let level = Int(first) else { return nil }
        return ComputedLevel(level: level)
    }

    /// Una cifra pegada a "nivel"/"niveles" ("nivel 6", "nivel ocho", "séptimo nivel", "2 niveles").
    /// `towardNext`: va como "al nivel N" o "hacia el nivel N" (así se nombra el nivel siguiente).
    nonisolated struct LevelMention: Sendable, Hashable {
        var value: Int
        var towardNext: Bool
    }

    static func levelMentions(in text: String) -> [LevelMention] {
        let tokens = text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
        func toward(before start: Int) -> Bool {
            (start >= 1 && tokens[start - 1] == "al")
                || (start >= 2 && tokens[start - 2] == "hacia" && tokens[start - 1] == "el")
        }
        var out: [LevelMention] = []
        for (i, token) in tokens.enumerated() where token == "nivel" || token == "niveles" {
            // Después: "nivel 6", "nivel seis", "nivel treinta y dos".
            if let n = spelledNumber(tokens, at: i + 1) {
                out.append(LevelMention(value: n, towardNext: toward(before: i)))
            }
            // Antes: "séptimo nivel", "2 niveles" ("un nivel" no es cifra: así se dice la regla).
            if i >= 1, let n = leadingDigits(tokens[i - 1]) ?? levelNumberWords[tokens[i - 1]] {
                out.append(LevelMention(value: n, towardNext: toward(before: i - 1)))
            }
        }
        return out
    }

    /// Un nivel con cifra solo puede ser el que calculó la app, y el siguiente solo como "al nivel N" o
    /// "hacia el nivel N". Sin nivel calculado (`nil`, o en un hallazgo), ninguna cifra junto a "nivel".
    /// Así una pregunta como "¿Por qué sigo en el nivel 6?" no pasa con un 6 de otro hecho (los días).
    static func levelMentionsAreGrounded(_ text: String, level: ComputedLevel?) -> Bool {
        levelMentions(in: text).allSatisfy { m in
            guard let level else { return false }
            return m.value == level.level || (m.towardNext && m.value == level.next)
        }
    }

    /// Número que empieza en `tokens[j]`: con dígitos ("7", "7º") o con letras ("siete", "veintiuno",
    /// "treinta y dos", "ciento cinco"). `nil` si ahí no hay un número.
    static func spelledNumber(_ tokens: [String], at j: Int) -> Int? {
        guard tokens.indices.contains(j) else { return nil }
        if let digits = leadingDigits(tokens[j]) { return digits }
        guard var value = levelNumberWords[tokens[j]] else { return nil }
        var k = j + 1
        // "ciento cinco", "doscientos treinta y dos".
        if value >= 100, value % 100 == 0, tokens.indices.contains(k), let rest = levelNumberWords[tokens[k]], rest < 100 {
            value += rest
            k += 1
        }
        // "treinta y dos".
        if value % 10 == 0, value % 100 >= 30, tokens.indices.contains(k + 1), tokens[k] == "y",
           let unit = levelNumberWords[tokens[k + 1]], unit < 10 {
            value += unit
        }
        return value
    }

    /// "7" o "7º" → 7; `nil` si el token no empieza con dígitos.
    static func leadingDigits(_ token: String) -> Int? {
        let digits = token.prefix { $0.isASCII && $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// Números con letras para nombrar un nivel: los de `numberWords` más "uno", "primer" y los mayores
    /// (los niveles pasan de quince). Sin "un"/"una": "sube un nivel" es la regla, no una cifra.
    static let levelNumberWords: [String: Int] = {
        var out: [String: Int] = [:]
        for (word, value) in numberWords { out[word] = Int(value) }
        let more: [String: Int] = [
            "uno": 1, "primer": 1, "primero": 1, "primera": 1, "trece": 13,
            "dieciséis": 16, "dieciseis": 16, "diecisiete": 17, "dieciocho": 18, "diecinueve": 19, "veinte": 20,
            "veintiuno": 21, "veintiún": 21, "veintidós": 22, "veintidos": 22, "veintitrés": 23, "veintitres": 23,
            "veinticuatro": 24, "veinticinco": 25, "veintiséis": 26, "veintiseis": 26, "veintisiete": 27,
            "veintiocho": 28, "veintinueve": 29, "treinta": 30, "cuarenta": 40, "cincuenta": 50, "sesenta": 60,
            "setenta": 70, "ochenta": 80, "noventa": 90, "cien": 100, "ciento": 100, "doscientos": 200,
            "trescientos": 300, "cuatrocientos": 400, "quinientos": 500,
            "undécimo": 11, "undécima": 11, "duodécimo": 12, "duodécima": 12, "vigésimo": 20, "vigésima": 20,
        ]
        out.merge(more) { current, _ in current }
        return out
    }()

    /// Cifras que un texto general (preguntas, foco) puede usar: las de todos los hechos y el contexto
    /// que el prompt le da al modelo (turnos de 12 horas, sistema de turno).
    static func groundingCorpus(_ facts: [KineFact], profile: PlayerProfile) -> String {
        (facts.map { "\($0.title) \($0.value) \($0.gist) \($0.detail)" } + ["12 horas", profile.roster.rawValue]).joined(separator: " ")
    }

    // MARK: - Nota del paciente

    /// Sin IA: el texto tal cual (recortado a 280 caracteres), sin resumen ni chips.
    static func noteTemplate(_ text: String) -> PatientNote {
        PatientNote(original: trimmedNote(text), summary: "", zones: [], moments: [], backend: .rules)
    }

    static func trimmedNote(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(PatientNote.maxCharacters))
    }

    /// Valida la salida del modelo: resumen limpio y sin cifras nuevas; zonas y momentos conocidos y
    /// mencionados de verdad en el texto (palabras clave), sin repetir y en orden fijo.
    static func validateNote(summary: String, zones: [String], moments: [String], original: String) -> PatientNote {
        let text = trimmedNote(original)
        let clean = cleanProse(summary, maxWords: maxSummaryWords, corpus: text) ?? ""
        let lower = text.lowercased()
        let zoneSet = Set(zones.compactMap { PainZone(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) })
            .filter { mentions($0, in: lower) }
        let momentSet = Set(moments.compactMap { Moment(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) })
            .filter { mentions($0, in: lower) }
        return PatientNote(original: text,
                           summary: clean,
                           zones: PainZone.allCases.filter { zoneSet.contains($0) },
                           moments: Moment.allCases.filter { momentSet.contains($0) },
                           backend: clean.isEmpty ? .rules : .foundationModels)
    }

    static let zoneKeywords: [PainZone: [String]] = [
        .lumbar: ["espalda", "lumbar", "cintura", "columna", "riñón", "riñon", "rinon", "parte baja"],
        .cuello: ["cuello", "nuca", "cervical"],
        .hombro: ["hombro"],
        .otra: ["rodilla", "pierna", "brazo", "mano", "muñeca", "codo", "cadera", "pies", "tobillo", "cabeza", "glúteo", "gluteo", "poto"],
    ]

    static let momentKeywords: [Moment: [String]] = [
        .entrada: ["entrada", "empez", "inicio", "comienz", "subir", "subo", "llego", "llegar", "relevo de entrada"],
        .colacion: ["colación", "colacion", "almuerzo", "almorz", "comer"],
        .salida: ["salida", "bajar", "bajo del", "bajarme", "termin", "final del", "al salir", "salgo"],
        .campamento: ["campamento", "noche", "dormir", "duermo", "cama", "pieza", "después del turno", "despues del turno"],
    ]

    static func mentions(_ zone: PainZone, in lower: String) -> Bool {
        (zoneKeywords[zone] ?? []).contains { lower.contains($0) }
    }

    static func mentions(_ moment: Moment, in lower: String) -> Bool {
        (momentKeywords[moment] ?? []).contains { lower.contains($0) }
    }

    // MARK: - Utilidades

    /// Firma de las cifras: cambia cuando cambia algún hecho (aviso "hay datos nuevos").
    static func signature(_ facts: [KineFact]) -> String {
        facts.map { "\($0.id)=\($0.value)" }.joined(separator: "|")
    }

    static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
