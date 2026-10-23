import SwiftUI

/// Pantalla principal: ruta diaria de 3 paradas + entrenamiento extra.
struct PathView: View {
    @Environment(GameStore.self) private var store
    @State private var activeLesson: Lesson?
    @State private var shieldMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    StatsBar()
                    HeroCard()
                    DailyRouteCard { activeLesson = $0.lesson }
                    if store.dayKind(for: .now) == .turno && !store.pausedToday {
                        QuickActions(
                            onRescue: { activeLesson = Catalog.rescue },
                            onNoTime: useShield
                        )
                    }
                    SectionTitle(title: "Entrenamiento extra", subtitle: "Lecciones para subir de nivel")
                    ForEach(Catalog.units) { unit in
                        UnitCarousel(unit: unit) { activeLesson = $0 }
                    }
                }
                .padding()
            }
            .appScreen()
            .navigationTitle("Pausa Minera")
            #if os(iOS)
            .fullScreenCover(item: $activeLesson) { lesson in
                SessionView(lesson: lesson)
            }
            #else
            .sheet(item: $activeLesson) { lesson in
                SessionView(lesson: lesson)
            }
            #endif
            .alert("Hoy no alcancé", isPresented: Binding(
                get: { shieldMessage != nil },
                set: { if !$0 { shieldMessage = nil } }
            )) {
                Button("Hacer rescate de 60 s") { activeLesson = Catalog.rescue }
                Button("OK", role: .cancel) {}
            } message: {
                Text(shieldMessage ?? "")
            }
        }
    }

    private func useShield() {
        if store.useShield() {
            shieldMessage = "Usaste un casco protector 🪖. Tu racha está a salvo. Si al final del turno tienes un minuto, el rescate de 60 s igual suma XP."
        } else {
            shieldMessage = "No te quedan cascos. Prueba el rescate de 60 s: se puede hacer en el camarín o en la habitación."
        }
    }
}

/// Saludo, estado del turno y nivel.
private struct HeroCard: View {
    @Environment(GameStore.self) private var store

    var body: some View {
        let kind = store.dayKind(for: .now)
        let day = store.blockDayNumber(for: .now)

        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label(kind == .turno ? "Turno · día \(day)/\(store.data.roster.workDays)" : "Descanso · día \(day)",
                      systemImage: kind == .turno ? "helmet.fill" : "beach.umbrella.fill")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(kind == .turno ? Theme.copper : .teal)
                Text(kind == .turno ? "¡Buen turno!" : "Disfruta la bajada")
                    .font(.largeTitle.weight(.heavy))
                if store.dobleteAvailable {
                    Label("Hoy ganas Doblete: XP x2", systemImage: "flame.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                } else if kind == .descanso {
                    Text("Tu racha está congelada. Caminar suma XP igual.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("3 paradas cortas cuidan tu espalda.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            ZStack {
                ProgressRing(progress: store.levelProgress,
                             colors: [Theme.gold, Theme.copper, Theme.gold], lineWidth: 10)
                VStack(spacing: 0) {
                    Text("\(store.level)").font(.title.weight(.heavy))
                    Text("nivel").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 82, height: 82)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Nivel \(store.level), \(store.rankName)")
        }
        .glassCard()
    }
}

/// Ruta del día: paradas conectadas, estilo Duolingo.
private struct DailyRouteCard: View {
    @Environment(GameStore.self) private var store
    let onStart: (RouteStop) -> Void

    var body: some View {
        let stops = store.todayRoute
        let done = stops.filter { store.isDone($0) }.count
        let next = store.nextStop

        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ruta de hoy").font(.title2.weight(.bold))
                    Text(done == stops.count ? "¡Completada! +30 XP de bonus" : "\(done) de \(stops.count) paradas")
                        .font(.subheadline)
                        .foregroundStyle(done == stops.count ? Theme.lime : .secondary)
                }
                Spacer()
                Image(systemName: done == stops.count ? "flag.checkered.circle.fill" : "map.circle.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(done == stops.count ? Theme.lime.gradient : Theme.copper.gradient)
                    .symbolEffect(.bounce, value: done)
            }

            VStack(spacing: 0) {
                ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                    StopRow(stop: stop, isDone: store.isDone(stop), isNext: stop.id == next?.id,
                            isLast: index == stops.count - 1) {
                        onStart(stop)
                    }
                }
            }
        }
        .glassCard()
    }
}

private struct StopRow: View {
    let stop: RouteStop
    let isDone: Bool
    let isNext: Bool
    let isLast: Bool
    let action: () -> Void

    private var color: Color { isDone ? Theme.lime : (isNext ? Theme.copper : .gray) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(color.gradient)
                        .frame(width: 58, height: 58)
                        .shadow(color: color.opacity(isNext ? 0.7 : 0), radius: 12)
                    Image(systemName: isDone ? "checkmark" : stop.symbol)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                }
                // Pulso suave en la próxima parada.
                .phaseAnimator([false, true]) { view, phase in
                    view.scaleEffect(isNext && phase ? 1.07 : 1)
                } animation: { _ in
                    .easeInOut(duration: 0.9)
                }
                if !isLast {
                    Capsule()
                        .fill(isDone ? Theme.lime.opacity(0.7) : .white.opacity(0.15))
                        .frame(width: 5, height: 34)
                        .padding(.vertical, 4)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(stop.title).font(.headline)
                    Spacer()
                    Text(stop.timeText)
                        .font(.caption.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .glassEffect()
                }
                Text(stop.lesson.exercises.map(\.name).joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !isDone {
                    Button(isNext ? "EMPEZAR" : "Hacer ahora", action: action)
                        .font(.subheadline.weight(.heavy))
                        .buttonStyle(.glassProminent)
                        .tint(isNext ? Theme.copper : .gray)
                        .padding(.top, 4)
                }
            }
            .padding(.top, 6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(stop.title), \(stop.timeText), \(isDone ? "completada" : "pendiente")")
    }
}

private struct QuickActions: View {
    let onRescue: () -> Void
    let onNoTime: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button(action: onRescue) {
                    Label("Rescate 60 s", systemImage: "bolt.heart.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.lime)

                Button(action: onNoTime) {
                    Label("Hoy no alcancé", systemImage: "clock.badge.xmark")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glass)
            }
            .font(.subheadline.weight(.bold))
        }
    }
}

/// Lecciones de una unidad en carrusel horizontal.
private struct UnitCarousel: View {
    @Environment(GameStore.self) private var store
    let unit: LessonUnit
    let onSelect: (Lesson) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(unit.color.gradient).frame(width: 10, height: 10)
                Text(unit.title).font(.headline)
                Text("· \(unit.subtitle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(unit.lessons) { lesson in
                        LessonCard(lesson: lesson, color: unit.color,
                                   unlocked: store.isUnlocked(lesson),
                                   completed: store.isCompleted(lesson)) {
                            onSelect(lesson)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct LessonCard: View {
    let lesson: Lesson
    let color: Color
    let unlocked: Bool
    let completed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(unlocked ? (completed ? Theme.gold.gradient : color.gradient) : Color.gray.gradient)
                        .frame(width: 50, height: 50)
                    Image(systemName: unlocked ? (completed ? "crown.fill" : lesson.symbol) : "lock.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                }
                Text(lesson.title)
                    .font(.subheadline.weight(.bold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2, reservesSpace: true)
                Text("\(lesson.exercises.count) ejercicios · +\(lesson.exercises.map(\.xp).reduce(0, +)) XP")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 140, alignment: .leading)
            .padding(14)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
            .opacity(unlocked ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!unlocked)
        .accessibilityLabel("\(lesson.title), \(completed ? "completada" : unlocked ? "disponible" : "bloqueada")")
    }
}

#Preview {
    PathView()
        .environment(GameStore(inMemory: true))
        .preferredColorScheme(.dark)
}
