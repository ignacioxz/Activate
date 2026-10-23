import Foundation
import Observation

// Dueño: agente "steps". Stub con firma congelada: único dueño de CMMotionManager/CMPedometer/CMMotionActivityManager.

@Observable
final class SensorHub {
    private(set) var isPedometerAvailable = false
    private(set) var isMotionAuthorized = false
    init() {}
    func refreshAvailability() {}
    func requestAuthorization() async {}
}
