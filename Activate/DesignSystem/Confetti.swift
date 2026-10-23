import SwiftUI

// Dueño: agente "design-celebration".
// Confeti sobrio: Canvas + TimelineView(.animation), 100-150 piezas, 2,5 s, cobre / menta / blanco.
// Se desactiva solo con Reduce Motion. No captura toques ni aparece en accesibilidad.

/// Parámetros del confeti (constantes nombradas; se calibran en dispositivo).
nonisolated enum ConfettiTuning {
    static let defaultCount = 130
    static let minCount = 100
    static let maxCount = 150
    static let duration: TimeInterval = 2.5
    /// Gravedad en fracciones de alto por s².
    static let gravity: Double = 1.15
    /// Empuje vertical inicial (negativo = hacia arriba), en fracciones de alto por s.
    static let burstMin: Double = -1.35
    static let burstMax: Double = -0.55
    /// Velocidad horizontal máxima en fracciones de ancho por s.
    static let spreadMax: Double = 0.55
    /// Tamaño de cada pieza en puntos.
    static let pieceMin: CGFloat = 6
    static let pieceMax: CGFloat = 11
    /// Retardo máximo de salida de cada pieza (s), para que no salgan todas juntas.
    static let staggerMax: TimeInterval = 0.35
    /// Segundos finales en que el confeti se desvanece.
    static let fadeTail: TimeInterval = 0.6
    /// Amplitud y frecuencia del vaivén lateral.
    static let swayAmplitude: Double = 0.03
    static let swayFrequency: Double = 5.5
}

/// Generador determinista (SplitMix64) para que cada redibujo del Canvas vea las mismas piezas.
nonisolated struct ConfettiRandom: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Valor uniforme en [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func range(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * unit()
    }
}

/// Una pieza de confeti: posición inicial normalizada, velocidades y aspecto.
nonisolated struct ConfettiPiece: Sendable, Identifiable {
    nonisolated enum Form: Sendable { case rectangle, circle, strip }
    let id: Int
    let x0: Double
    let y0: Double
    let vx: Double
    let vy: Double
    let delay: TimeInterval
    let size: CGFloat
    let spin: Double
    let swayPhase: Double
    let colorIndex: Int
    let form: Form

    /// Pieza `index` para `count` colores con una semilla fija.
    static func make(count: Int, colorCount: Int, seed: UInt64) -> [ConfettiPiece] {
        var rng = ConfettiRandom(seed: seed)
        return (0..<count).map { i in
            let formRoll = rng.unit()
            let form: Form = formRoll < 0.55 ? .rectangle : (formRoll < 0.8 ? .strip : .circle)
            return ConfettiPiece(
                id: i,
                x0: rng.range(0.25, 0.75),
                y0: rng.range(0.30, 0.45),
                vx: rng.range(-ConfettiTuning.spreadMax, ConfettiTuning.spreadMax),
                vy: rng.range(ConfettiTuning.burstMin, ConfettiTuning.burstMax),
                delay: rng.range(0, ConfettiTuning.staggerMax),
                size: CGFloat(rng.range(Double(ConfettiTuning.pieceMin), Double(ConfettiTuning.pieceMax))),
                spin: rng.range(-6, 6),
                swayPhase: rng.range(0, .pi * 2),
                colorIndex: Int(rng.next() % UInt64(max(1, colorCount))),
                form: form
            )
        }
    }

    /// Posición normalizada (0-1) y rotación en el instante `t` (segundos desde que apareció la vista).
    func state(at t: TimeInterval) -> (x: Double, y: Double, angle: Double, alpha: Double)? {
        let local = t - delay
        guard local >= 0 else { return nil }
        let y = y0 + vy * local + 0.5 * ConfettiTuning.gravity * local * local
        let sway = ConfettiTuning.swayAmplitude * sin(local * ConfettiTuning.swayFrequency + swayPhase)
        let x = x0 + vx * local + sway
        let remaining = ConfettiTuning.duration - t
        let alpha = min(1, max(0, remaining / ConfettiTuning.fadeTail))
        return (x, y, spin * local, alpha)
    }
}

/// Lluvia de confeti de 2,5 s. Colocar en un `overlay` a pantalla completa; se dibuja una sola vez por aparición.
struct ConfettiView: View {
    var count: Int = ConfettiTuning.defaultCount
    var colors: [Color] = [Theme.copper, Theme.mint, .white]
    var seed: UInt64 = 2024
    var duration: TimeInterval = ConfettiTuning.duration

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate: Date? = nil
    @State private var finished = false

    private var pieces: [ConfettiPiece] {
        let clamped = min(ConfettiTuning.maxCount, max(ConfettiTuning.minCount, count))
        return ConfettiPiece.make(count: clamped, colorCount: max(1, colors.count), seed: seed)
    }

    var body: some View {
        Group {
            if reduceMotion || finished {
                Color.clear
            } else {
                let pieces = pieces
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: finished)) { context in
                    Canvas(rendersAsynchronously: true) { gc, size in
                        guard let startDate else { return }
                        let t = context.date.timeIntervalSince(startDate)
                        guard t >= 0, t <= duration else { return }
                        for piece in pieces {
                            guard let s = piece.state(at: t), s.alpha > 0, s.y < 1.2 else { continue }
                            var ctx = gc
                            ctx.opacity = s.alpha
                            ctx.translateBy(x: s.x * size.width, y: s.y * size.height)
                            ctx.rotate(by: .radians(s.angle))
                            let color = colors[piece.colorIndex % max(1, colors.count)]
                            let half = piece.size / 2
                            switch piece.form {
                            case .rectangle:
                                ctx.fill(Path(CGRect(x: -half, y: -half * 0.7, width: piece.size, height: piece.size * 0.7)), with: .color(color))
                            case .strip:
                                ctx.fill(Path(CGRect(x: -half * 0.35, y: -half * 1.4, width: piece.size * 0.35, height: piece.size * 1.4)), with: .color(color))
                            case .circle:
                                ctx.fill(Path(ellipseIn: CGRect(x: -half * 0.8, y: -half * 0.8, width: piece.size * 0.8, height: piece.size * 0.8)), with: .color(color))
                            }
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion, startDate == nil else { return }
            startDate = .now
        }
        .task {
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .seconds(duration + 0.2))
            finished = true
        }
    }
}

#Preview("Confeti") {
    ZStack {
        Color(.systemBackground).ignoresSafeArea()
        Text("Doblete").font(.largeTitle.weight(.heavy))
        ConfettiView()
    }
}
