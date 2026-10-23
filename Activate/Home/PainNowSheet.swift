import SwiftUI

/// Registro rápido "Me duele ahora": zona (prellenada desde el perfil) y contexto en un toque.
/// Guarda un `DailyCheckIn` con `source: .meDueleAhora` y cierra.
struct PainNowSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var chosenZone: PainZone?

    private static let chipHeight: CGFloat = 56
    private static let zoneColumns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var zone: PainZone { chosenZone ?? store.profile.usualZone }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("¿Dónde le duele?")
                            .font(.title3.weight(.semibold))
                        LazyVGrid(columns: Self.zoneColumns, spacing: 12) {
                            ForEach(PainZone.allCases) { candidate in
                                zoneChip(candidate)
                            }
                        }
                    }
                    .flatCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Text("¿Dónde estaba? Toque uno.")
                            .font(.title3.weight(.semibold))
                        ForEach(PainContext.allCases) { context in
                            contextButton(context)
                        }
                    }
                    .flatCard()

                    Text("Se guarda al toque y vuelve a Hoy.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
    }

    private func zoneChip(_ candidate: PainZone) -> some View {
        Button {
            chosenZone = candidate
        } label: {
            Text(candidate.title)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: Self.chipHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.bordered)
        .tint(zone == candidate ? Theme.copper : .gray)
        .accessibilityAddTraits(zone == candidate ? .isSelected : [])
    }

    private func contextButton(_ context: PainContext) -> some View {
        Button {
            save(context)
        } label: {
            Label(context.title, systemImage: Self.symbol(for: context))
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: Theme.rowHeight, alignment: .leading)
                .padding(.horizontal, 6)
                .contentShape(.rect)
        }
        .buttonStyle(.bordered)
        .tint(Theme.copper)
        .accessibilityHint("Guarda el registro: \(zone.title), \(context.title)")
    }

    private func save(_ context: PainContext) {
        let entry = Self.entry(now: .now, profile: store.profile, zone: zone, context: context, calendar: store.calendar)
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

    /// Registro "Me duele ahora" con la clave del día laboral y el momento inferido.
    nonisolated static func entry(now: Date, profile: PlayerProfile, zone: PainZone, context: PainContext, calendar: WorkCalendar) -> DailyCheckIn {
        DailyCheckIn(date: now,
                     workDayKey: calendar.key(for: now),
                     turnoKey: calendar.turnoKey(for: now),
                     source: .meDueleAhora,
                     answers: [],
                     zone: zone,
                     moment: Moment.infer(date: now, shift: profile.shiftType, calendar: calendar.calendar),
                     context: context)
    }
}
