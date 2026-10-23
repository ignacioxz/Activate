import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Dueño: paquete "kine-ai" (antes agente "kine-sheet").
// Exportación de la hoja: ImageRenderer (MainActor, no es Sendable) → PNG a escala 3 para WhatsApp
// desde el campamento, y PDF de una página con render { size, draw in … } sobre un CGContext.
// Todo ocurre en el teléfono; nada sale sin que la persona toque Compartir.

@MainActor
enum KineSheetExport {
    /// Ancho fijo de la hoja exportada (puntos).
    static let exportWidth: CGFloat = 390
    /// Escala del PNG (3x: legible al hacer zoom en el chat).
    static let pngScale: CGFloat = 3

    /// La hoja con el entorno fijo que ImageRenderer no hereda de la jerarquía.
    static func exportView(_ content: KineSheetContent) -> some View {
        KineSheetView(content: content, width: exportWidth)
            .environment(\.colorScheme, .light)
            .environment(\.locale, KineSheetFormat.locale)
            .dynamicTypeSize(.large)
    }

    static func pngData(_ content: KineSheetContent) -> Data? {
        let renderer = ImageRenderer(content: exportView(content))
        renderer.scale = pngScale
        renderer.isOpaque = true
        return renderer.uiImage?.pngData()
    }

    static func pdfData(_ content: KineSheetContent) -> Data? {
        let renderer = ImageRenderer(content: exportView(content))
        var result: Data?
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            let buffer = NSMutableData()
            guard let consumer = CGDataConsumer(data: buffer as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
            result = buffer as Data
        }
        return result
    }

    nonisolated static func fileStem(for profile: PlayerProfile) -> String {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Hoja kine" : "Hoja kine \(name)"
    }
}

nonisolated enum KineSheetExportError: Error {
    case renderFailed
}

/// Hoja como PNG para `ShareLink`. Guarda solo valores Sendable; rasteriza en MainActor al compartir.
nonisolated struct KineSheetPNG: Transferable, Sendable {
    var content: KineSheetContent

    nonisolated static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            try await item.render()
        }
        .suggestedFileName { "\(KineSheetExport.fileStem(for: $0.content.profile)).png" }
    }

    func render() async throws -> Data {
        let content = self.content
        let data = await MainActor.run { KineSheetExport.pngData(content) }
        guard let data else { throw KineSheetExportError.renderFailed }
        return data
    }
}

/// Hoja como PDF de una página (para imprimir o adjuntar a una ficha).
nonisolated struct KineSheetPDF: Transferable, Sendable {
    var content: KineSheetContent

    nonisolated static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { item in
            try await item.render()
        }
        .suggestedFileName { "\(KineSheetExport.fileStem(for: $0.content.profile)).pdf" }
    }

    func render() async throws -> Data {
        let content = self.content
        let data = await MainActor.run { KineSheetExport.pdfData(content) }
        guard let data else { throw KineSheetExportError.renderFailed }
        return data
    }
}
