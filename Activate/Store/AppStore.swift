import Foundation
import Observation

/// Única fuente de verdad en memoria + archivo JSON en Application Support.
/// Contrato congelado: `data` solo se muta vía `mutate`. El agente de Store agrega
/// `DemoSeed`, consultas y utilidades en otros archivos mediante extensiones.
@Observable
final class AppStore {
    private(set) var data: SaveData
    @ObservationIgnored private let persists: Bool
    @ObservationIgnored private(set) var fileURL: URL
    @ObservationIgnored private(set) var lastSaveError: String?

    init(inMemory: Bool = false, fileURL: URL? = nil) {
        persists = !inMemory
        let url = fileURL ?? Self.defaultFileURL()
        self.fileURL = url
        if !inMemory, let loaded = Self.load(from: url) {
            data = loaded
        } else {
            data = SaveData(profile: PlayerProfile(rosterStart: Calendar.current.startOfDay(for: .now)))
        }
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Activate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json")
    }

    static func load(from url: URL) -> SaveData? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SaveData.self, from: raw)
    }

    /// Única vía de mutación; guarda en disco al terminar.
    func mutate(_ body: (inout SaveData) -> Void) {
        body(&data)
        save()
    }

    /// Reemplaza todo el estado (semilla de demo, reinicio).
    func replace(with newData: SaveData) {
        data = newData
        save()
    }

    func save() {
        guard persists else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            let raw = try encoder.encode(data)
            try raw.write(to: fileURL, options: .atomic)
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
    }

    var profile: PlayerProfile { data.profile }

    var calendar: WorkCalendar { WorkCalendar(profile: data.profile) }
}
