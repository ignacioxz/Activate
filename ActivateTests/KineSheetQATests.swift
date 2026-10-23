import Testing
import SwiftUI
import UIKit
@testable import Activate

/// Capturas de QA de la hoja del kine en la ventana real de la app anfitriona (incluye TextField,
/// ScrollView y vidrio, que ImageRenderer no dibuja). Solo corre si se pasa la carpeta de salida:
///     TEST_RUNNER_QA_KINE_OUT=/ruta xcodebuild … test -only-testing:ActivateTests/KineSheetQATests
@MainActor
struct KineSheetQATests {
    nonisolated static var outDir: String? { ProcessInfo.processInfo.environment["QA_KINE_OUT"] }

    @Test(.enabled(if: KineSheetQATests.outDir != nil), .timeLimit(.minutes(5)))
    func capturas() async throws {
        let dir = try #require(Self.outDir)
        let window = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first)

        // 1) Sin Apple Intelligence (plantilla): arriba y más abajo.
        try await show(KineSheetQARoot(override: .rules), in: window)
        try await shoot(window, dir, "kine-ai-1-plantilla", offsets: [0, 650, 1300, 2200])

        // 2) Con Apple Intelligence: el modelo escribe (streaming) y queda listo.
        try await show(KineSheetQARoot(override: .auto, autoPrepare: true, note: KineSheetQA.sampleNote), in: window, settle: 3.0)
        try await shoot(window, dir, "kine-ai-2-escribiendo", offsets: [0, 500])
        try await Task.sleep(for: .seconds(16))
        try await shoot(window, dir, "kine-ai-3-listo", offsets: [0, 650, 1300, 2000])

        // 3) Modo oscuro (mismo estado listo).
        window.overrideUserInterfaceStyle = .dark
        try await Task.sleep(for: .seconds(0.6))
        try await shoot(window, dir, "kine-ai-4-oscuro", offsets: [0, 900])
        window.overrideUserInterfaceStyle = .unspecified

        // 4) Vista previa del Reporte de Salud (papel, con el nivel) y fila de Estadísticas.
        let data = DemoSeed.data(now: .now)
        let work = WorkCalendar(profile: data.profile)
        let summary = StatsEngine.summary(data: data, calendar: work, now: .now)
        let facts = KineFacts.build(data: data, summary: summary)
        var sheet = KineSheet(consult: KineConsultRules.template(facts, profile: data.profile), note: nil,
                              factsSignature: KineConsultRules.signature(facts), preparedAt: .now)
        sheet.note = KineConsultRules.noteTemplate(KineSheetQA.sampleNote)
        let content = KineSheetContent(sheet: sheet, facts: facts, summary: summary, profile: data.profile,
                                       level: LevelProgress.compute(sessions: data.sessions, calendar: work))
        try await show(NavigationStack { KineSheetPreviewScreen(content: content) }.fontDesign(.rounded), in: window)
        try await shoot(window, dir, "kine-ai-5-vista-previa", offsets: [0, 700, 1400, 2100])

        let store = AppStore(inMemory: true)
        DemoSeed.load(into: store)
        let coach = CoachService()
        coach.refreshAvailability()
        try await show(StatsView().environment(store).environment(coach).fontDesign(.rounded).tint(Theme.accent), in: window)
        try await shoot(window, dir, "kine-ai-6-estadisticas", offsets: [1100, 1500])

        if let png = KineSheetExport.pngData(content) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("kine-ai-7-export.png"))
        }
    }

    private func show<V: View>(_ view: V, in window: UIWindow, settle: Double = 2.5) async throws {
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(settle))
    }

    private func shoot(_ window: UIWindow, _ dir: String, _ name: String, offsets: [CGFloat]) async throws {
        for (i, y) in offsets.enumerated() {
            if let scroll = Self.mainScrollView(in: window) {
                let maxY = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                scroll.setContentOffset(CGPoint(x: 0, y: min(y - scroll.adjustedContentInset.top, maxY)), animated: false)
            }
            try await Task.sleep(for: .seconds(0.5))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(i).png")
            try image.pngData()?.write(to: url)
        }
    }

    /// El UIScrollView más alto de la jerarquía (el ScrollView de la pantalla).
    private static func mainScrollView(in view: UIView) -> UIScrollView? {
        var best: UIScrollView?
        func visit(_ v: UIView) {
            if let s = v as? UIScrollView, !(s is UITextView), s.contentSize.height > (best?.contentSize.height ?? 0) { best = s }
            v.subviews.forEach(visit)
        }
        visit(view)
        return best
    }
}
