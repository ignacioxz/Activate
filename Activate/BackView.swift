import SwiftUI
import Charts

/// Bitácora de dolor lumbar y semana de turno.
struct BackView: View {
    @Environment(GameStore.self) private var store
    @State private var showLog = false

    private var lastSevenDays: [Date] {
        let today = Calendar.current.startOfDay(for: .now)
        return (0..<7).reversed().compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: today) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SectionTitle(title: "Últimos 7 días")
                    weekStrip
                    weekList

                    SectionTitle(title: "Dolor reportado", subtitle: "Últimas 2 semanas")
                    painChart

                    insights

                    PrimaryButton(title: "Registrar dolor ahora", systemImage: "plus.circle.fill", tint: Theme.copper) {
                        showLog = true
                    }
                }
                .padding()
            }
            .appScreen()
            .navigationTitle("Mi espalda")
            .sheet(isPresented: $showLog) {
                PainLogSheet()
                    .presentationDetents([.medium])
            }
        }
    }

    /// Resumen visual: un punto por día, coloreado según la pausa.
    private var weekStrip: some View {
        HStack(spacing: 6) {
            ForEach(Array(lastSevenDays.enumerated()), id: \.element) { index, date in
                let record = store.record(for: date)
                let kind = store.dayKind(for: date)
                let color: Color = kind == .descanso ? .teal
                    : record.pausesDone > 0 ? Theme.lime
                    : record.usedShield ? Theme.sky : .white.opacity(0.15)
                VStack(spacing: 6) {
                    Text("D\(index + 1)").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    Circle()
                        .fill(color.gradient)
                        .frame(width: 34, height: 34)
                        .overlay {
                            Image(systemName: kind == .descanso ? "beach.umbrella.fill"
                                  : record.pausesDone > 0 ? "checkmark"
                                  : record.usedShield ? "shield.fill" : "minus")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .glassCard(cornerRadius: 22)
    }

    private var weekList: some View {
        VStack(spacing: 0) {
            ForEach(Array(lastSevenDays.enumerated()), id: \.element) { index, date in
                let record = store.record(for: date)
                let kind = store.dayKind(for: date)
                HStack {
                    Text("D\(index + 1)").font(.headline).frame(width: 36, alignment: .leading)
                    Text(date, format: .dateTime.weekday(.abbreviated).day())
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                    Spacer()
                    if kind == .descanso {
                        Label("Descanso", systemImage: "beach.umbrella.fill").foregroundStyle(.teal)
                    } else if record.pausesDone > 0 {
                        Label("Pausa sí", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.lime)
                    } else if record.usedShield {
                        Label("No alcancé", systemImage: "shield.fill").foregroundStyle(Theme.sky)
                    } else {
                        Label("Sin pausa", systemImage: "circle.dashed").foregroundStyle(.secondary)
                    }
                    if let pain = store.maxPain(on: date) {
                        Text("\(pain)/5")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.painColor(pain).opacity(0.3), in: .capsule)
                    }
                }
                .font(.subheadline)
                .padding(.vertical, 10)
                if index < 6 { Divider().opacity(0.4) }
            }
        }
        .glassCard(cornerRadius: 22)
    }

    private var painChart: some View {
        let start = Calendar.current.date(byAdding: .day, value: -13, to: Calendar.current.startOfDay(for: .now)) ?? .now
        let entries = store.data.pain.filter { $0.date >= start }
        return Group {
            if entries.isEmpty {
                Text("Aún no hay registros. Cada pausa parte preguntando por tu dolor.")
                    .foregroundStyle(.secondary)
            } else {
                Chart(entries) { entry in
                    BarMark(x: .value("Día", entry.date, unit: .day), y: .value("Dolor", entry.level))
                        .foregroundStyle(Theme.painColor(entry.level).gradient)
                        .cornerRadius(6)
                }
                .chartYScale(domain: 0...5)
                .frame(height: 180)
            }
        }
        .glassCard(cornerRadius: 22)
    }

    /// Recomendaciones simples a partir de los datos registrados.
    @ViewBuilder
    private var insights: some View {
        let recent = store.data.pain.filter { $0.date > Date.now.addingTimeInterval(-7 * 86_400) }
        let highDays = Set(recent.filter { $0.level >= 4 }.map { GameStore.dayKey($0.date) }).count
        let liftingPain = recent.contains { $0.context == .levantarCarga && $0.level >= 4 }
        let peakFive = recent.contains { $0.level == 5 }

        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Para ti")
            if highDays >= 3 {
                insight("Dolor alto \(highDays) días esta semana. Conversa con el paramédico o policlínico de faena; la app complementa, no reemplaza la evaluación.",
                        "stethoscope", .red)
            }
            if peakFive {
                insight("Tuviste un peak 5/5. Esos días haz solo caminata suave y avisa a tu supervisor si no puedes seguir la tarea.",
                        "exclamationmark.triangle.fill", .red)
            }
            if liftingPain {
                insight("El dolor aparece al levantar carga: la unidad «Carga segura» entrena la fuerza de piernas para levantar.",
                        "shippingbox.fill", Theme.copper)
            }
            if !store.dobleteAvailable && !store.pausedToday {
                insight("Meta de la semana: lograr un Doblete (pausa dos días seguidos) para ganar XP x2.",
                        "flame.fill", .orange)
            }
            insight("En la bajada la racha se congela. Caminar en tus días libres alivia la espalda y suma XP.",
                    "beach.umbrella.fill", .teal)
        }
    }

    private func insight(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.subheadline)
        .glassCard(cornerRadius: 18, tint: color)
    }
}

private struct PainLogSheet: View {
    @Environment(GameStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var level = 3
    @State private var context: PainContext = .general

    var body: some View {
        NavigationStack {
            Form {
                Section("Nivel de dolor lumbar") {
                    Picker("Nivel", selection: $level) {
                        ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("¿Cuándo?") {
                    Picker("Momento", selection: $context) {
                        ForEach(PainContext.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            }
            .navigationTitle("Registrar dolor")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        store.logPain(level: level, context: context)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    let store = GameStore(inMemory: true)
    store.loadDemoWeek()
    return BackView()
        .environment(store)
        .preferredColorScheme(.dark)
}
