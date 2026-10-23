import SwiftUI

/// Registro rápido "Me duele ahora": zonas (selección múltiple, prellenadas desde el perfil) y contexto
/// en un toque. Guarda un `DailyCheckIn` con `source: .meDueleAhora` y cierra.
struct PainNowSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var chosenZones: [PainZone]?

    private static let contextColumns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    private var zones: [PainZone] { chosenZones ?? store.profile.allUsualZones }

    private var zonesBinding: Binding<[PainZone]> {
        Binding(get: { zones }, set: { chosenZones = PainZone.normalized($0, fallback: zones.first ?? .lumbar) })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("¿Dónde le duele?")
                                .font(.headline)
                            Text("Marque una o más zonas.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        MultiSelectChips(items: PainZone.allCases, selection: zonesBinding, title: { $0.title })
                    }
                    .flatCard()

                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("¿Dónde estaba?")
                                .font(.headline)
                            Text("Toque uno y se guarda.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: Self.contextColumns, spacing: 10) {
                            ForEach(PainContext.allCases) { context in
                                contextButton(context)
                            }
                        }
                    }
                    .flatCard()

                    Text("Queda en sus registros y vuelve a Hoy.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding()
            }
            .appScreen()
            .navigationTitle("Me duele ahora")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
        // Acento azul en los controles (el cobre queda solo para la llama de la racha).
        .tint(Theme.accent)
    }

    private func contextButton(_ context: PainContext) -> some View {
        SecondaryButton(title: context.title, systemImage: Self.symbol(for: context)) {
            save(context)
        }
        .accessibilityHint("Guarda el registro: \(PainZone.listTitle(zones)), \(context.title)")
    }

    private func save(_ context: PainContext) {
        let entry = Self.entry(now: .now, profile: store.profile, zones: zones, context: context, calendar: store.calendar)
        store.mutate { $0.checkIns.append(entry) }
        dismiss()
    }

    // MARK: - Lógica pura

    nonisolated static func symbol(for context: PainContext) -> String {
        switch context {
        case .enCabina: "truck.box.fill"
        case .alBajar: "figure.walk"
        case .enElBus: "bus.fill"
        case .enCasa: "house.fill"
        }
    }

    /// Registro "Me duele ahora" con la clave del día laboral, el momento inferido y todas las zonas marcadas.
    nonisolated static func entry(now: Date, profile: PlayerProfile, zones: [PainZone], context: PainContext, calendar: WorkCalendar) -> DailyCheckIn {
        let picked = PainZone.normalized(zones.isEmpty ? (profile.usualZones ?? [profile.usualZone]) : zones,
                                         fallback: profile.usualZone)
        return DailyCheckIn(date: now,
                            workDayKey: calendar.key(for: now),
                            turnoKey: calendar.turnoKey(for: now),
                            source: .meDueleAhora,
                            answers: [],
                            zone: picked[0],
                            zones: picked,
                            moment: Moment.infer(date: now, shift: profile.shiftType, calendar: calendar.calendar),
                            context: context)
    }

    /// Variante de una sola zona (compatibilidad).
    nonisolated static func entry(now: Date, profile: PlayerProfile, zone: PainZone, context: PainContext, calendar: WorkCalendar) -> DailyCheckIn {
        entry(now: now, profile: profile, zones: [zone], context: context, calendar: calendar)
    }
}

#Preview {
    PainNowSheet()
        .environment(AppStore(inMemory: true))
}
