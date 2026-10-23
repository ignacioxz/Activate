import CoreHaptics
import Testing
@testable import Activate

struct HapticsGoalTests {
    /// Meta de pasos: tres pulsos largos e intensos, lo bastante largos para sentirse en el bolsillo.
    @Test func patronDeMetaDePasosEsFuerteYLargo() throws {
        let pattern = try Haptics.goalPattern()
        #expect(Haptics.Pattern.goalPulses == 3)
        #expect(pattern.duration >= 1.6)
        #expect(Haptics.Pattern.goalPulseSeconds >= 0.4)
    }
}
