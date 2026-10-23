import Testing
import Foundation
@testable import Activate

/// Reglas de copy de la celebración: pool fijo, ≤ 6 palabras, sin "¡Excelente!", sin "trampa", sin "apto".
struct CelebrationCopyTests {
    private func reward(counted: Bool = true, day: Int = 3, doblete: Bool = false, tiro: Bool = false, xp: Int = 20) -> SessionReward {
        SessionReward(lines: xp > 0 ? [RewardLine(label: "Actividad", xp: xp)] : [], totalXP: xp, counted: counted,
                      streak: day, dayInBlock: day, isDoblete: doblete, isTiroLimpio: tiro, newBadges: [])
    }

    @Test func todasLasFrasesTienenSeisPalabrasOMenos() {
        for phrase in CelebrationCopy.allFixedPhrases {
            #expect(CelebrationCopy.wordCount(phrase) <= CelebrationCopy.maxWordsPerPhrase, "Frase larga: \(phrase)")
            #expect(!phrase.isEmpty)
        }
    }

    @Test func ningunaFraseUsaPalabrasProhibidas() {
        for phrase in CelebrationCopy.allFixedPhrases {
            #expect(!CelebrationCopy.containsBannedFragment(phrase), "Frase prohibida: \(phrase)")
        }
        // El filtro detecta la partícula "po" y las exclamaciones, pero no "por" ni "pausa".
        #expect(CelebrationCopy.containsBannedFragment("Ya po."))
        #expect(CelebrationCopy.containsBannedFragment("¡Excelente!"))
        #expect(CelebrationCopy.containsBannedFragment("No es trampa"))
        #expect(!CelebrationCopy.containsBannedFragment("Pausa verificada por sensores."))
    }

    @Test func frasesCanonicasDelPlan() {
        #expect(CelebrationCopy.phrases(for: .activityDone).first == "Listo.")
        #expect(CelebrationCopy.phrases(for: .day1).first == "Partió.")
        #expect(CelebrationCopy.title(for: .doblete) == "Doblete")
        #expect(CelebrationCopy.title(for: .tiroLimpio) == "Tiro limpio")
        #expect(CelebrationCopy.title(for: .pauseDone) == "Pausa cumplida")
        #expect(CelebrationCopy.notVerifiedLine(treatment: .usted) == "No pude verificarla. Repita cuando pueda.")
        #expect(CelebrationCopy.closeAction == "LISTO")
    }

    @Test func laEleccionDelPoolEsDeterminista() {
        for milestone in CelebrationMilestone.allCases {
            let pool = CelebrationCopy.phrases(for: milestone)
            #expect(!pool.isEmpty)
            for seed in [-5, 0, 1, 7, 42, 1_000_003] {
                let a = CelebrationCopy.phrase(for: milestone, seed: seed)
                let b = CelebrationCopy.phrase(for: milestone, seed: seed)
                #expect(a == b)
                #expect(pool.contains(a))
            }
        }
    }

    @Test func escaleraDeHitos() {
        #expect(CelebrationMilestone.forReward(reward(counted: false, day: 2, doblete: true)) == .notVerified)
        #expect(CelebrationMilestone.forReward(reward(day: 1)) == .day1)
        #expect(CelebrationMilestone.forReward(reward(day: 2, doblete: true)) == .doblete)
        #expect(CelebrationMilestone.forReward(reward(day: 7, doblete: false, tiro: true)) == .tiroLimpio)
        #expect(CelebrationMilestone.forReward(reward(day: 7, doblete: true, tiro: true)) == .tiroLimpio)
        #expect(CelebrationMilestone.forReward(reward(day: 4)) == .pauseDone)
        #expect(CelebrationMilestone.doblete.usesConfetti)
        #expect(CelebrationMilestone.tiroLimpio.usesConfetti)
        #expect(!CelebrationMilestone.pauseDone.usesConfetti)
        #expect(!CelebrationMilestone.notVerified.usesConfetti)
    }

    @Test func laRespuestaPostEsUnDatoNoUnPremio() {
        #expect(CelebrationCopy.postLine(.mejor) == "Hoy: mejor después de la pausa")
        #expect(CelebrationCopy.postLine(.igual) == "Hoy: igual después de la pausa")
        #expect(CelebrationCopy.postLine(.peor) == "Hoy: peor después de la pausa")
        #expect(CelebrationCopy.postLine(nil) == nil)
        #expect(CelebrationCopy.postNote(.mejor) == nil)
    }

    @Test func verificacionSinCastigo() {
        let noVerificada = CelebrationCopy.verificationLine(counted: false, totalXP: 0, treatment: .usted)
        #expect(noVerificada == "No pude verificarla. Repita cuando pueda.")
        #expect(CelebrationCopy.verificationLine(counted: false, totalXP: 0, treatment: .tu) == "No pude verificarla. Repite cuando puedas.")
        #expect(CelebrationCopy.verificationLine(counted: true, totalXP: 30, treatment: .usted) == "Pausa verificada por sensores.")
        #expect(CelebrationCopy.verificationLine(counted: false, totalXP: 10, treatment: .usted) == "Verificación parcial. Suma XP.")
        #expect(CelebrationCopy.xpLine(total: 0) == "Sin XP esta vez")
        #expect(CelebrationCopy.xpLine(total: 35) == "+35 XP")
    }

    @Test func lineasDeDiaYRacha() {
        #expect(CelebrationCopy.dayLine(dayInBlock: 2) == "Día 2 de 7")
        #expect(CelebrationCopy.dayLine(dayInBlock: 0) == "Día 1 de 7")
        #expect(CelebrationCopy.dayLine(dayInBlock: 3, workDays: 4) == "Día 3 de 4")
        #expect(CelebrationCopy.streakLine(streak: 0) == "Racha: parte hoy")
        #expect(CelebrationCopy.streakLine(streak: 1) == "Racha: 1 día")
        #expect(CelebrationCopy.streakLine(streak: 5) == "Racha: 5 días")
    }

    @Test func laSemillaEsEstablePorRecompensa() {
        let r = reward(day: 2, doblete: true, xp: 40)
        #expect(CelebrationCopy.seed(for: r) == CelebrationCopy.seed(for: r))
    }

    @Test func elConfetiEsDeterministaYDentroDelRango() {
        let a = ConfettiPiece.make(count: 120, colorCount: 3, seed: 9)
        let b = ConfettiPiece.make(count: 120, colorCount: 3, seed: 9)
        #expect(a.count == 120)
        #expect(a.map(\.x0) == b.map(\.x0))
        #expect(a.allSatisfy { (0..<3).contains($0.colorIndex) })
        #expect(a.allSatisfy { $0.size >= ConfettiTuning.pieceMin && $0.size <= ConfettiTuning.pieceMax })
        // Antes de su retardo la pieza no existe; al final se desvanece.
        let piece = a[0]
        #expect(piece.state(at: -1) == nil)
        let end = piece.state(at: ConfettiTuning.duration)
        #expect(end == nil || end!.alpha == 0)
    }
}
