import Testing
@testable import Activate

struct ProfileRankTests {
    @Test func nivelDesdeXP() {
        #expect(ProfileRank.level(xp: 0) == 1)
        #expect(ProfileRank.level(xp: 149) == 1)
        #expect(ProfileRank.level(xp: 150) == 2)
        #expect(ProfileRank.level(xp: -10) == 1)
    }

    @Test func rangoComoEtiqueta() {
        #expect(ProfileRank.title(xp: 0) == "Aprendiz")
        #expect(ProfileRank.title(xp: 300) == "Operador")
        #expect(ProfileRank.title(xp: 900) == "Capataz")
        #expect(ProfileRank.title(xp: 100_000) == "Superintendente")
    }

    @Test func progresoDentroDelNivel() {
        #expect(ProfileRank.progress(xp: 0) == 0)
        #expect(ProfileRank.progress(xp: 75) == 0.5)
        #expect(ProfileRank.progress(xp: 150) == 0)
    }
}
