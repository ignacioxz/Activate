#if DEBUG
import SwiftUI

// Dueño: agente "design-system". Galería de componentes para revisar el diseño en el simulador
// (`-qa-gallery [1-3]`) y en el canvas. Solo Debug.

/// Todos los componentes del design system con sus estados. `page` muestra una sola página
/// (1 botones y filas · 2 chips y tiles · 3 colores · 4 anillos, insignias y Modo exterior); `nil` = todo.
struct ThemeGallery: View {
    var page: Int? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if shows(1) { buttonsPage }
                    if shows(2) { chipsPage }
                    if shows(3) { colorsPage }
                    if shows(4) { outdoorPage }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .appScreen()
            .navigationTitle(title)
        }
    }

    private var title: String {
        switch page {
        case 1: "Botones y filas"
        case 2: "Chips y tiles"
        case 3: "Colores"
        case 4: "Insignias y exterior"
        default: "Galería"
        }
    }

    private func shows(_ p: Int) -> Bool { page == nil || page == p }

    // MARK: Página 1

    @ViewBuilder
    private var buttonsPage: some View {
        GallerySection("Botón principal") {
            PrimaryButton(title: "Hacer la pausa", systemImage: "play.fill") {}
            PrimaryButton(title: "Seguir", systemImage: "arrow.right", isEnabled: false) {}
            HStack(spacing: 12) {
                PrimaryButton(title: "Empezar", fullWidth: false) {}
                PrimaryButton(title: "Entendido", tint: Theme.danger, fullWidth: false) {}
            }
        }
        GallerySection("Botón secundario") {
            HStack(spacing: 12) {
                SecondaryButton(title: "Otra pausa", systemImage: "arrow.clockwise") {}
                SecondaryButton(title: "Me duele ahora", systemImage: "bolt.heart.fill") {}
            }
            SecondaryButton(title: "Volver a responder", systemImage: "arrow.counterclockwise") {}
        }
        GallerySection("Pregunta Sí / No") {
            GalleryYesNo(text: "1. Me quedo en casa casi todo el tiempo por la espalda.", initial: nil)
            GalleryYesNo(text: "2. Cambio de posición seguido para estar más cómodo.", initial: true)
            GalleryYesNo(text: "3. Camino más lento de lo normal por la espalda.", initial: false)
        }
    }

    // MARK: Página 2

    @ViewBuilder
    private var chipsPage: some View {
        GallerySection("Chips de selección") {
            GalleryChips()
        }
        GallerySection("Racha") {
            HStack(spacing: 8) {
                StreakChip(streak: 0)
                StreakChip(streak: 5)
            }
            StreakChip(streak: 3, safe: true)
        }
        GallerySection("Tiles") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                StatTile(title: "Pausas", value: "5 de 7", caption: "Este turno", systemImage: "checkmark.circle.fill")
                StatTile(title: "Espalda hoy", value: "2/6", caption: "Mejor que ayer", tint: Theme.rdqColor(2), systemImage: "figure.walk")
                StatTile(title: "Pasos", value: "1.240", systemImage: "shoeprints.fill")
                StatTile(title: "Verificadas", value: "100 %", tint: Theme.successText, systemImage: "checkmark.seal.fill")
            }
        }
    }

    // MARK: Página 3

    @ViewBuilder
    private var colorsPage: some View {
        GallerySection("Tarjeta") {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "Colación", subtitle: "Incluye: Cuello · Ojos · Respiración")
                Text("Pausa cumplida hoy").font(.headline).foregroundStyle(Theme.successText)
                Text("Hoy aún sin pausa.").font(.subheadline).foregroundStyle(.secondary)
            }
            .flatCard()
        }
        GallerySection("Texto de estado") {
            VStack(alignment: .leading, spacing: 6) {
                swatch("Logrado", Theme.successText)
                swatch("Aviso", Theme.warningText)
                swatch("Alerta", Theme.dangerText)
                swatch("Acento", Theme.accent)
                swatch("Menta · Cielo · Oro", Theme.mint, Theme.sky, Theme.gold)
                swatch("Llama (solo racha)", Theme.copper)
            }
            .flatCard()
            HStack(spacing: 6) {
                ForEach(0...6, id: \.self) { score in
                    Text("\(score)")
                        .font(.headline)
                        .fontDesign(.rounded)
                        .foregroundStyle(Theme.rdqColor(score))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(Theme.rdqColor(score).opacity(0.14), in: .rect(cornerRadius: 10))
                }
            }
        }
    }

    // MARK: Página 4

    @ViewBuilder
    private var outdoorPage: some View {
        GallerySection("Anillos") {
            HStack(spacing: 24) {
                ProgressRing(progress: 0.35).frame(width: 64, height: 64)
                ProgressRing(progress: 0.7, color: Theme.gold, lineWidth: 8).frame(width: 64, height: 64)
                ProgressRing(progress: 1, color: Theme.successText, lineWidth: 8).frame(width: 64, height: 64)
            }
        }
        GallerySection("Insignias") {
            BadgeGrid(earned: [.primeraPausa, .doblete, .relevoCumplido, .tiroLimpio], size: 52)
                .flatCard()
        }
        GallerySection("Modo exterior") {
            VStack(spacing: 12) {
                PrimaryButton(title: "Hacer la pausa", systemImage: "play.fill") {}
                SecondaryButton(title: "Me duele ahora", systemImage: "bolt.heart.fill") {}
                GalleryYesNo(text: "Me cuesta agacharme.", initial: true)
                StreakChip(streak: 4)
            }
            .environment(\.outdoorMode, true)
        }
    }

    private func swatch(_ label: String, _ colors: Color...) -> some View {
        HStack(spacing: 8) {
            ForEach(colors.indices, id: \.self) { i in
                Circle().fill(colors[i]).frame(width: 14, height: 14)
            }
            Text(label)
                .font(.body.weight(.semibold))
                .foregroundStyle(colors.first ?? .primary)
        }
    }
}

/// Sección con título chico.
private struct GallerySection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct GalleryYesNo: View {
    let text: String
    @State private var answer: Bool?

    init(text: String, initial: Bool?) {
        self.text = text
        _answer = State(initialValue: initial)
    }

    var body: some View {
        YesNoRow(text: text, answer: $answer)
    }
}

private enum GalleryZone: String, CaseIterable, Identifiable, Hashable {
    case cuello = "Cuello", hombros = "Hombros", lumbar = "Espalda baja", rodillas = "Rodillas", munecas = "Muñecas"
    var id: String { rawValue }
}

private struct GalleryChips: View {
    @State private var zones: Set<GalleryZone> = [.lumbar, .cuello]
    @State private var moment: Set<Moment> = [.colacion]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dónde le duele (varias)").font(.subheadline).foregroundStyle(.secondary)
            ChoiceChipGroup(items: GalleryZone.allCases, selection: $zones) { $0.rawValue }
            Text("Momento (una)").font(.subheadline).foregroundStyle(.secondary)
            ChoiceChipGroup(items: Moment.allCases, selection: $moment, allowsMultiple: false) { $0.title }
        }
    }
}

#Preview("Galería") { ThemeGallery() }
#Preview("Galería oscuro") { ThemeGallery().preferredColorScheme(.dark) }
#endif
