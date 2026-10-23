import SwiftUI

// Tarjetas planas de Hoy bajo la meta del día: momentos, camino del turno, nivel, insignias y espalda.

// MARK: - Momentos de hoy

/// Entrada · Colación · Salida · Campamento con su hora de inicio para el turno del perfil.
/// El momento vigente va en azul con "Ahora"; un ✓ marca los momentos con pausa contada hoy.
struct HoyMomentsCard: View {
    let moments: HoyMoments

    @Environment(\.dynamicTypeSize) private var typeSize
    private static let circle: CGFloat = 42

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HoyCardTitle(title: "Momentos de hoy", trailing: moments.trailing)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(moments.stops) { stop in
                        HStack(spacing: 12) {
                            icon(stop)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stop.moment.shortTitle)
                                    .font(.subheadline.weight(stop.phase == .now ? .bold : .medium))
                                    .foregroundStyle(stop.phase == .now ? Theme.accent : .primary)
                                Text(stop.phase == .now ? "Ahora · desde las \(stop.start)" : "Desde las \(stop.start)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Self.spoken(stop))
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(moments.stops) { stop in
                        column(stop)
                    }
                }
                .background(alignment: .top) {
                    ColumnConnectors(colors: Array(repeating: Color.primary.opacity(0.12), count: max(0, moments.stops.count - 1)),
                                     columns: moments.stops.count, nodeSize: Self.circle, gap: 8)
                }
            }
            Text(moments.line)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .flatCard()
        .accessibilityElement(children: .contain)
    }

    private func column(_ stop: MomentStop) -> some View {
        let isNow = stop.phase == .now
        return VStack(spacing: 4) {
            icon(stop)
                .frame(maxWidth: .infinity)
            Text(stop.moment.shortTitle)
                .font(.caption.weight(isNow ? .bold : .medium))
                .foregroundStyle(isNow ? Theme.accent : (stop.phase == .past ? Color.secondary : Color.primary))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(isNow ? "Ahora" : stop.start)
                .font(.caption2.weight(isNow ? .semibold : .regular))
                .foregroundStyle(isNow ? Theme.accent : .secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(stop))
    }

    private func icon(_ stop: MomentStop) -> some View {
        let isNow = stop.phase == .now
        return Image(systemName: stop.moment.symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(isNow ? Color.white : (stop.phase == .past ? Color.secondary : Theme.accent))
            .frame(width: Self.circle, height: Self.circle)
            .background(isNow ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.quietFill), in: .circle)
            .overlay(alignment: .topTrailing) {
                if stop.done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.footnote.weight(.bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.mint)
                        .background(Circle().fill(Color(.secondarySystemBackground)).padding(-1.5))
                        .offset(x: 4, y: -4)
                }
            }
    }

    static func spoken(_ stop: MomentStop) -> String {
        var text = "\(stop.moment.title), desde las \(stop.start)"
        if stop.phase == .now { text += ", ahora" }
        if stop.done { text += ", pausa hecha" }
        return text
    }
}

// MARK: - Camino del turno

/// El turno como un camino de nodos con hitos alcanzables (Partió, Doblete, Tiro limpio),
/// la racha dibujada como línea azul y el comodín como seguro del camino.
struct TurnoPathCard: View {
    let path: TurnoPath
    let cascos: Int

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.outdoorMode) private var outdoor
    @State private var showComodin = false

    private static let node: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HoyCardTitle(title: path.title, trailing: path.trailing)

            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(path.nodes.enumerated()), id: \.element.id) { index, node in
                    column(node, index: index)
                }
            }
            .background(alignment: .top) {
                ColumnConnectors(colors: path.segments.map { $0 ? Theme.accent : Color.primary.opacity(0.12) },
                                 columns: path.nodes.count, nodeSize: Self.node, thickness: outdoor ? 4 : 3)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(path.spoken)

            if typeSize.isAccessibilitySize, let line = milestonesLine {
                Text(line)
                    .font(.footnote.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let line = path.comodinLine {
                    Button {
                        showComodin = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: ComodinInfo.symbol)
                                .foregroundStyle(Theme.accent)
                            Text(line)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Image(systemName: "info.circle")
                                .foregroundStyle(Theme.accent)
                        }
                        .font(.footnote)
                        .frame(minHeight: Theme.rowHeight)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Explica qué es el comodín")
                    .popover(isPresented: $showComodin, arrowEdge: .top) {
                        ComodinInfo(available: cascos)
                            .presentationCompactAdaptation(.popover)
                    }
                }
                Label {
                    Text(path.dateLine)
                } icon: {
                    Image(systemName: "calendar")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .flatCard()
    }

    /// "Hoy: Doblete · Día 7: Tiro limpio" (letra de accesibilidad, en vez de la fila de etiquetas).
    private var milestonesLine: String? {
        let parts = path.nodes.compactMap { node in
            node.milestone.map { node.isToday ? "Hoy: \($0)" : "Día \(node.day): \($0)" }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func column(_ node: TurnoPath.Node, index: Int) -> some View {
        let isFirst = index == 0
        let isLast = index == path.nodes.count - 1
        let alignment: Alignment = isLast ? .trailing : (isFirst ? .leading : .center)
        return VStack(spacing: 4) {
            nodeView(node)
                .frame(maxWidth: .infinity)
            if !typeSize.isAccessibilitySize {
                Text(node.weekday)
                    .font(.caption2.weight(node.isToday ? .bold : .regular))
                    .foregroundStyle(node.isToday ? Theme.accent : .secondary)
                    .lineLimit(1)
                Text(node.milestone ?? " ")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: alignment)
                    .accessibilityHidden(node.milestone == nil)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(node.spoken)
    }

    @ViewBuilder
    private func nodeView(_ node: TurnoPath.Node) -> some View {
        let size = Self.node
        switch node.state {
        case .pausa:
            Image(systemName: node.finale == .achieved ? "checkmark.seal.fill" : "checkmark")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Theme.accent, in: .circle)
        case .comodin:
            Image(systemName: ComodinInfo.symbol)
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(width: size, height: size)
                .background(Theme.accent.opacity(0.15), in: .circle)
                .background(Circle().fill(Color(.secondarySystemBackground)))
        case .todayPending:
            Group {
                if node.showsFlame {
                    Image(systemName: "flame.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.copper)
                } else if node.finale == .possible {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.accent)
                } else {
                    Text("\(node.day)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(width: size, height: size)
            .background(Circle().fill(Color(.secondarySystemBackground)))
            .overlay(Circle().inset(by: 1.25).stroke(Theme.accent, lineWidth: 2.5))
        case .missed:
            Circle()
                .fill(Color(.secondarySystemBackground))
                .overlay(Circle().fill(Color.primary.opacity(0.07)))
                .frame(width: size, height: size)
        case .future:
            Group {
                if node.finale == .possible {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(node.day)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            .background(Theme.quietFill, in: .circle)
            .background(Circle().fill(Color(.secondarySystemBackground)))
        }
    }
}

// MARK: - Segmentos

/// Un segmento entre los centros de columnas vecinas de igual ancho (sin uniones ni costuras):
/// azul donde la racha sigue, gris donde no. Va detrás de la fila de nodos, a la altura del nodo.
struct ColumnConnectors: View {
    /// Color de cada segmento (`columns - 1`).
    let colors: [Color]
    let columns: Int
    let nodeSize: CGFloat
    /// Aire entre el segmento y cada nodo.
    var gap: CGFloat = 0
    var thickness: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width / CGFloat(max(1, columns))
            ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                Rectangle()
                    .fill(color)
                    .frame(width: max(0, width - nodeSize - 2 * gap), height: thickness)
                    .position(x: width * CGFloat(index + 1), y: nodeSize / 2)
            }
        }
        .frame(height: nodeSize)
        .accessibilityHidden(true)
    }
}

// MARK: - Nivel

/// Nivel con barra azul: tramo sólido = XP del nivel; tramo claro = lo que puede sumar la próxima pausa.
struct LevelCard: View {
    let level: LevelSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text("Nivel \(level.level)")
                        .font(.headline)
                        .contentTransition(.numericText())
                } icon: {
                    Image(systemName: "star.circle.fill")
                        .foregroundStyle(Theme.gold)
                }
                Spacer(minLength: 8)
                Text("\(level.xp) XP")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            HStack(spacing: 6) {
                LevelBar(progress: level.progress, ghost: level.ghostProgress)
                if level.nextPauseCrossesLevel {
                    Image(systemName: "arrow.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            Text(level.note)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .flatCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level.spoken)
    }
}

/// Barra de 10 pt en el acento azul (nunca oro: se leía naranjo).
struct LevelBar: View {
    let progress: Double
    let ghost: Double

    @Environment(\.outdoorMode) private var outdoor

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                if ghost > progress {
                    if outdoor {
                        Capsule()
                            .strokeBorder(Theme.accent, lineWidth: 1.5)
                            .frame(width: max(10, width * ghost))
                    } else {
                        Capsule()
                            .fill(Theme.accent.opacity(0.28))
                            .frame(width: max(10, width * ghost))
                    }
                }
                if progress > 0 {
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(10, width * progress))
                }
            }
            .animation(.spring(duration: 0.5), value: progress)
            .animation(.spring(duration: 0.5), value: ghost)
        }
        .frame(height: 10)
    }
}

// MARK: - Insignias

/// Las 6 insignias con su avance, la más cercana primero. Tocar una muestra qué pide.
struct BadgesCard: View {
    let badges: [BadgeStatus]
    let earned: Int

    @Environment(\.dynamicTypeSize) private var typeSize

    private var columns: [GridItem] {
        let count = typeSize.isAccessibilitySize ? 1 : (typeSize >= .xxLarge ? 2 : 3)
        return Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HoyCardTitle(title: "Insignias", trailing: "\(earned) de \(badges.count)")
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(badges) { status in
                    BadgeCell(status: status, horizontal: typeSize.isAccessibilitySize)
                }
            }
        }
        .flatCard()
    }
}

private struct BadgeCell: View {
    let status: BadgeStatus
    /// Lista (letra de accesibilidad): hexágono a la izquierda y textos a la derecha.
    let horizontal: Bool

    @State private var showInfo = false

    var body: some View {
        Button {
            showInfo = true
        } label: {
            Group {
                if horizontal {
                    HStack(alignment: .top, spacing: 12) {
                        hexagon
                        texts
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        hexagon
                        texts
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showInfo, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(status.badge.title)
                    .font(.headline)
                Text(status.badge.detail)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(status.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(width: 280, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.spoken)
        .accessibilityHint("Muestra qué pide la insignia")
    }

    private var hexagon: some View {
        BadgeView(badge: status.badge, style: .flat, size: 44, showsTitle: false, earned: status.earned)
            .accessibilityHidden(true)
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(status.badge.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if status.earned {
                Label(status.status, systemImage: "checkmark.circle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.successText)
            } else {
                Text(status.status)
                    .font(.caption2)
                    .foregroundStyle(status.highlight ? Theme.accent : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let progress = status.progress {
                ProgressView(value: progress)
                    .tint(barColor)
            }
        }
    }

    /// Barras frías (sin oro ni cobre).
    private var barColor: Color {
        switch status.badge {
        case .caminanteDelRajo, .rajoCompleto: Theme.mint
        case .relevoCumplido: Theme.sky
        default: Theme.accent
        }
    }
}

// MARK: - Su espalda hoy

/// Tres datos sin premios: preguntas de hoy, la pausa anterior y lo que más le ayuda.
struct BackCard: View {
    let back: BackSummary
    let help: ActivityKind?

    /// Columna de los símbolos: crece con la letra para no pisar el texto.
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HoyCardTitle(title: "Su espalda hoy")
            row("questionmark.circle") {
                if let score = back.todayScore {
                    Text("Hoy: \(Text("\(score) de \(RDQ6.maxScore)").fontWeight(.semibold))")
                } else {
                    Text("Preguntas de hoy: al inicio de la pausa.")
                }
            }
            if let previous = back.previous {
                row("clock.arrow.circlepath") { Text(previous.line) }
            }
            if let help {
                row("hand.thumbsup") { Text("Le ayuda más: \(HoyProgress.helpName(help))") }
            }
            if let pain = back.painLine {
                row("bolt.heart") { Text(pain) }
            }
        }
        .flatCard()
    }

    private func row<T: View>(_ symbol: String, @ViewBuilder text: () -> T) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            text()
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}
