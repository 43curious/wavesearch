import Foundation
import WaveSearchKit

@main
struct LocalizationCheck {
    static func main() async throws {
        let spanish = CommandLine.arguments.contains("--spanish")
        precondition(Bundle.main.preferredLocalizations.first == (spanish ? "es" : "en"))
        precondition(RefinementMode.fastOnly.title == (spanish ? "Solo rápido" : "Fast only"))
        precondition(AppAppearanceMode.dark.title == (spanish ? "Oscuro" : "Dark"))
        precondition(AudioImportBehavior.keepInPlace.title == (spanish ? "Mantener los archivos en su ubicación" : "Keep the files in place"))
        precondition(SearchShortcut.controlOptionSpace.title == (spanish ? "⌃⌥Espacio" : "⌃⌥Space"))
        precondition(RefinementBlocker.playback.message == (spanish ? "En pausa durante la reproducción" : "Paused for playback"))
        precondition(ExampleAudio.DecodeError.truncated.localizedDescription == (spanish ? "El audio ha terminado antes de su duración declarada." : "The audio ended before its declared length."))
        precondition(PortableSelects.ImportError.notRegularFile.localizedDescription == (spanish ? "Elige un documento JSON guardado como archivo normal." : "Choose a JSON document stored as a regular file."))
        let invalid = LibraryBackupManifest(version: 0, folders: [], favourites: [])
        do {
            try invalid.validate()
            preconditionFailure("Invalid manifest accepted")
        } catch {
            precondition(error.localizedDescription == (spanish ? "Esta copia tiene un manifiesto de bibliotecas no válido o de una versión no compatible." : "This backup has an unsupported or invalid library manifest."))
        }
        let forms: [(LocalizedText.CountUnit, String, String)] = [
            (.files, spanish ? "1 archivo" : "1 file", spanish ? "2 archivos" : "2 files"),
            (.filesDiscovered, spanish ? "1 archivo encontrado" : "1 file discovered", spanish ? "2 archivos encontrados" : "2 files discovered"),
            (.sounds, spanish ? "1 sonido" : "1 sound", spanish ? "2 sonidos" : "2 sounds"),
            (.soundsLoaded, spanish ? "Se ha cargado 1 sonido" : "1 sound loaded", spanish ? "Se han cargado 2 sonidos" : "2 sounds loaded"),
            (.matches, spanish ? "1 coincidencia" : "1 match", spanish ? "2 coincidencias" : "2 matches"),
            (.channels, spanish ? "1 canal" : "1 channel", spanish ? "2 canales" : "2 channels"),
        ]
        for (unit, singular, plural) in forms {
            precondition(LocalizedText.count(1, unit) == singular)
            precondition(LocalizedText.count(2, unit) == plural)
        }
        precondition(LocalizedText.count(0, .files) == (spanish ? "0 archivos" : "0 files"))
        precondition(LocalizedText.count(1_234_567, .files) == (spanish ? "1.234.567 archivos" : "1,234,567 files"))
        precondition(LocalizedText.position(65.25) == (spanish ? "1:05,25" : "1:05.25"))
        precondition(LocalizedText.position(0) == (spanish ? "0:00,00" : "0:00.00"))
        precondition(LocalizedText.position(59.999) == (spanish ? "1:00,00" : "1:00.00"))
        precondition(LocalizedText.audioDuration(0.043) == (spanish ? "0,04 segundos" : "0.04 seconds"))
        // Domain and persisted keys remain independent of presentation language.
        precondition(RefinementMode.fastOnly.rawValue == "fastOnly")
        precondition(AudioImportBehavior.keepInPlace.rawValue == "keepInPlace")
        let name = "Lluvia_雨.wav"
        precondition(String(localized: "Filter \(name)…") == (spanish ? "Filtrar Lluvia_雨.wav…" : "Filter Lluvia_雨.wav…"))
        let search = Bundle.main.localizedString(forKey: "Search filenames and metadata, or enter a duration filter", value: nil, table: nil)
        precondition(search == (spanish ? "Busca en nombres y metadatos o introduce un filtro de duración" : "Search filenames and metadata, or enter a duration filter"))
        let help = Bundle.main.localizedString(forKey: "Preview keys work while results have focus. Press Esc in search to focus results; press Esc again or ⌘K to return to search. Tab and Shift–Tab move between controls; arrows adjust the focused control.", value: nil, table: nil)
        precondition(help.contains("⌘K") && help.contains(spanish ? "Mayús–Tab" : "Shift–Tab"))
        try await Task.detached { try selectsErrors(spanish: spanish) }.value
        print("PASS: \(spanish ? "Spanish" : "English") native resources, plurals, large counts, timing, errors and stable domain keys; duration=\(LocalizedText.duration(125))")
    }

    nonisolated private static func selectsErrors(spanish: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wavesearch-localized-selects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        precondition(root.appendingPathComponent("catalog.sqlite").path.withCString { ws_init($0) } == 0)
        defer { ws_deinit() }
        _ = try PortableSelects.importData(Data(#"{"version":1,"sources":[{"path":"/synthetic/café.wav","favourite":true,"tags":["Before"]}]}"#.utf8))
        let before = try PortableSelects.exportData()
        let invalidDocument = spanish ? "Este no es un documento de selecciones de WaveSearch válido." : "This is not a valid WaveSearch selects document."
        let invalidIdentity = spanish ? "Este documento de selecciones contiene una identidad de origen no válida." : "This selects document contains an invalid source identity."
        func document(_ source: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["version": 1, "sources": [source]])
        }
        let cases: [(Data, String, String)] = [
            (Data(#"{"version":1,"sources":["#.utf8), "UnexpectedEndOfInput", invalidDocument),
            (Data(#"{"version":1,"version":1,"sources":[]}"#.utf8), "DuplicateField", invalidDocument),
            (Data(#"{"version":1,"sources":[{"path":"\q"}]}"#.utf8), "SyntaxError", invalidDocument),
            (Data(#"{"version":1.5,"sources":[]}"#.utf8), "InvalidNumber", invalidDocument),
            (try document(["path": ""]), "InvalidSelectsPath", spanish ? "Este documento de selecciones contiene una ruta de origen no válida." : "This selects document contains an invalid source path."),
            (try document(["path": "/synthetic.wav", "id": "bad"]), "InvalidSelectsID", invalidIdentity),
            (try document(["path": "/synthetic.wav", "file_size": -2]), "InvalidSelectsIdentity", invalidIdentity),
            (try document(["path": String(repeating: "x", count: 4097)]), "ValueTooLong", spanish ? "Se supera el límite admitido para el documento o las anotaciones." : "This exceeds the supported document or annotation limit."),
        ]
        for (data, diagnostic, message) in cases {
            do {
                _ = try PortableSelects.importData(data)
                preconditionFailure("Invalid selects document was accepted")
            } catch {
                let error = error as NSError
                precondition(error.localizedDescription == message, "Unexpected localized selects error: \(error.localizedDescription)")
                let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
                precondition(underlying?.localizedDescription == diagnostic, "The core diagnostic must remain available")
            }
            let after = try PortableSelects.exportData()
            precondition(after == before, "A rejected import changed saved annotations")
        }
        do {
            try PortableSelects.edit(file: -1, kind: UInt32(WS_SELECTS_TAG), name: "bad\0name", range: nil, enabled: true)
            preconditionFailure("NUL in a tag name was accepted")
        } catch {
            precondition(error.localizedDescription == (spanish ? "Usa un nombre de etiqueta o colección más corto y no vacío." : "Use a shorter, non-empty tag or collection name."))
        }
        print("PASS: localized selects JSON failures, retained core diagnostics and unchanged annotations")
    }
}
