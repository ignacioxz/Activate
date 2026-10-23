import Foundation

/// Caché de un solo valor por clave (por ejemplo el día laboral + la cantidad de sesiones).
/// No es observable a propósito: se consulta durante el `body` sin invalidar la vista, y el
/// `TimelineView` de Hoy (cada minuto) no vuelve a recorrer el historial si la clave no cambió.
final class PerDayCache<Value> {
    private var key: String?
    private var stored: Value?
    /// Veces que se calculó el valor (tests).
    private(set) var computations = 0

    init() {}

    func value(for key: String, compute: () -> Value) -> Value {
        if self.key == key, let stored { return stored }
        let value = compute()
        self.key = key
        stored = value
        computations += 1
        return value
    }
}
