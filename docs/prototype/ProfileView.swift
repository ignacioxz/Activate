import SwiftUI

/// Nivel, insignias, turno y recordatorios.
struct ProfileView: View {
    @Environment(GameStore.self) private var store
    @State private var roster: Roster = .sieteXSiete
    @State private var rosterStart = Date.now
    @State private var confirmReset = false
    @State private var permissionDenied = false

    private let stopNames = ["Inicio de turno", "Colación", "Fin de turno"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        ZStack {
                            ProgressRing(progress: store.levelProgress,
                                         colors: [Theme.gold, Theme.copper, Theme.gold], lineWidth: 8)
                            Text("\(store.level)").font(.title2.weight(.heavy))
                        }
                        .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.rankName).font(.title2.weight(.bold))
                            Text("\(store.data.xp) XP · \(store.data.totalPauses) pausas · \(store.data.nuggets) pepitas")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section("Insignias") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88))], spacing: 16) {
                        ForEach(Badge.allCases) { badge in
                            let earned = store.data.badges.contains(badge)
                            VStack(spacing: 6) {
                                Image(systemName: badge.symbol)
                                    .font(.title2)
                                    .foregroundStyle(earned ? .white : .secondary)
                                    .frame(width: 58, height: 58)
                                    .background(earned ? AnyShapeStyle(LinearGradient(colors: [.purple, .pink], startPoint: .top, endPoint: .bottom))
                                                       : AnyShapeStyle(.quaternary),
                                                in: .circle)
                                    .shadow(color: earned ? .purple.opacity(0.6) : .clear, radius: 8)
                                Text(badge.title)
                                    .font(.caption2.weight(.bold))
                                    .multilineTextAlignment(.center)
                            }
                            .opacity(earned ? 1 : 0.6)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(badge.title): \(badge.detail). \(earned ? "Obtenida" : "Pendiente")")
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section {
                    Toggle("Recordatorios de la ruta", isOn: Binding(
                        get: { store.data.notificationsEnabled },
                        set: { enable in toggleNotifications(enable) }
                    ))
                    ForEach(stopNames.indices, id: \.self) { index in
                        DatePicker(stopNames[index], selection: stopTimeBinding(index), displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("Ruta diaria")
                } footer: {
                    Text(permissionDenied
                         ? "Las notificaciones están desactivadas en Ajustes del iPhone."
                         : "Avisos a la hora de cada parada en días de turno, y un rescate si no hiciste ninguna. Funcionan sin señal.")
                }

                Section {
                    Picker("Sistema de turno", selection: $roster) {
                        ForEach(Roster.allCases) { Text($0.rawValue).tag($0) }
                    }
                    DatePicker("Primer día del turno actual", selection: $rosterStart, displayedComponents: .date)
                } header: {
                    Text("Mi turno")
                } footer: {
                    Text("Los días de descanso no cortan tu racha ni envían recordatorios.")
                }

                Section("Demo") {
                    Button("Cargar semana de ejemplo (dolor lumbar)") {
                        store.loadDemoWeek()
                        syncRoster()
                    }
                    Button("Reiniciar progreso", role: .destructive) { confirmReset = true }
                }
            }
            .appScreen()
            .navigationTitle("Perfil")
            .onAppear(perform: syncRoster)
            .onChange(of: roster) { store.setRoster(roster, start: rosterStart) }
            .onChange(of: rosterStart) { store.setRoster(roster, start: rosterStart) }
            .confirmationDialog("¿Borrar todo el progreso?", isPresented: $confirmReset) {
                Button("Borrar", role: .destructive) {
                    store.reset()
                    syncRoster()
                }
            }
        }
    }

    private func toggleNotifications(_ enable: Bool) {
        guard enable else {
            store.setNotifications(false)
            return
        }
        Task {
            let granted = await NotificationScheduler.requestAuthorization()
            permissionDenied = !granted
            store.setNotifications(granted)
        }
    }

    /// Convierte los minutos guardados en una fecha para el selector de hora.
    private func stopTimeBinding(_ index: Int) -> Binding<Date> {
        Binding(
            get: {
                let minutes = store.data.stopTimes.indices.contains(index) ? store.data.stopTimes[index] : DailyRoute.defaultTimes[index]
                return Calendar.current.date(byAdding: .minute, value: minutes, to: Calendar.current.startOfDay(for: .now)) ?? .now
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                store.setStopTime(index: index, minutes: (c.hour ?? 0) * 60 + (c.minute ?? 0))
            }
        )
    }

    private func syncRoster() {
        roster = store.data.roster
        rosterStart = store.data.rosterStart
    }
}

#Preview {
    ProfileView()
        .environment(GameStore(inMemory: true))
        .preferredColorScheme(.dark)
}
