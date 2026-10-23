import Foundation

/// Registro local de diagnóstico, solo en builds DEBUG: eventos de la pausa (etapas, cierres, escena,
/// memoria) y muestras crudas de cada sensor en vivo, en `Documents/diagnostics` del teléfono.
/// Sirve para encontrar cierres inesperados y calibrar umbrales con datos reales; se descarga con
/// `xcrun devicectl device copy from --domain-type appDataContainer`. Nada sale del teléfono.
nonisolated enum Diagnostics {
    static var isEnabled: Bool {
        #if DEBUG
        return !isRunningTests
        #else
        return false
        #endif
    }

    private static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    /// Una línea con fecha en `pause-log.txt`.
    static func log(_ text: String) {
        guard isEnabled else { return }
        DiagnosticsLog.shared.append(text)
    }
}

/// Archivo de eventos (`pause-log.txt`, rota a `pause-log.old.txt` al pasar ~1 MB). Escribe en una cola propia.
nonisolated final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()
    static let maxLogBytes = 1_000_000

    let directory: URL
    let queue = DispatchQueue(label: "cl.activate.diagnostics", qos: .utility)
    private var handle: FileHandle?
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docs.appending(path: "diagnostics", directoryHint: .isDirectory)
    }

    func append(_ text: String) {
        let now = Date()
        queue.async { [self] in
            let line = "\(formatter.string(from: now)) \(text)\n"
            guard let data = line.data(using: .utf8), let handle = openLog() else { return }
            try? handle.write(contentsOf: data)
        }
    }

    /// Solo en `queue`.
    private func openLog() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "pause-log.txt")
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.maxLogBytes {
            let old = directory.appending(path: "pause-log.old.txt")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? h.seekToEnd()
        handle = h
        return h
    }
}

/// Grabación de una actividad con fuente en vivo: `samples/<fecha>-<id>.jsonl`, una línea por muestra
/// (`{"t":…,"s":{…}}`) o evento del verificador (`{"t":…,"e":"…"}`). Se conservan las últimas 20.
nonisolated final class SampleRecording: @unchecked Sendable {
    static let keptRecordings = 20

    private let queue: DispatchQueue
    private var handle: FileHandle?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }()

    private struct SampleLine<S: Encodable>: Encodable { let t: Double; let s: S }
    private struct EventLine: Encodable { let t: Double; let e: String }
    private struct Header: Encodable { let kind: String; let target: Int; let started: String; let build: String }

    init?(kindID: String, target: Int) {
        guard Diagnostics.isEnabled else { return nil }
        let log = DiagnosticsLog.shared
        queue = log.queue
        let dir = log.directory.appending(path: "samples", directoryHint: .isDirectory)
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            return f.string(from: Date())
        }()
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        let header = Header(kind: kindID, target: target, started: stamp, build: build)
        queue.async { [self] in
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appending(path: "\(stamp)-\(kindID).jsonl")
            fm.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
            writeLine(header)
            Self.prune(dir)
        }
    }

    func sample<S: Encodable & Sendable>(_ sample: S, t: Double) {
        queue.async { [self] in writeLine(SampleLine(t: t, s: sample)) }
    }

    func event(_ text: String, t: Double) {
        queue.async { [self] in writeLine(EventLine(t: t, e: text)) }
    }

    func close(_ summary: String, t: Double) {
        queue.async { [self] in
            writeLine(EventLine(t: t, e: summary))
            try? handle?.close()
            handle = nil
        }
    }

    /// Solo en `queue`.
    private func writeLine<T: Encodable>(_ value: T) {
        guard let handle, var data = try? encoder.encode(value) else { return }
        data.append(0x0A)
        try? handle.write(contentsOf: data)
    }

    private static func prune(_ dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path).filter({ $0.hasSuffix(".jsonl") }).sorted(),
              files.count > keptRecordings else { return }
        for name in files.prefix(files.count - keptRecordings) {
            try? fm.removeItem(at: dir.appending(path: name))
        }
    }
}
