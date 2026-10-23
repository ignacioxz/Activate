import Foundation

/// Fechas en español de Chile con nombres fijos (no dependen del idioma del teléfono ni de la
/// abreviatura con punto de `DateFormatter`): "viernes 23", "jue", "jueves 5 de noviembre", "15:20".
nonisolated enum SpanishDate {
    /// Índice = `Calendar.component(.weekday)` - 1 (domingo = 1 en el calendario gregoriano).
    static let weekdays = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"]
    static let weekdaysShort = ["dom", "lun", "mar", "mié", "jue", "vie", "sáb"]
    static let months = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio",
                         "agosto", "septiembre", "octubre", "noviembre", "diciembre"]

    /// "viernes"
    static func weekday(_ date: Date, calendar: Calendar) -> String {
        weekdays[(calendar.component(.weekday, from: date) - 1 + 7) % 7]
    }

    /// "vie"
    static func weekdayShort(_ date: Date, calendar: Calendar) -> String {
        weekdaysShort[(calendar.component(.weekday, from: date) - 1 + 7) % 7]
    }

    /// "viernes 23"
    static func weekdayDay(_ date: Date, calendar: Calendar) -> String {
        "\(weekday(date, calendar: calendar)) \(calendar.component(.day, from: date))"
    }

    /// "jueves 5 de noviembre"
    static func weekdayDayMonth(_ date: Date, calendar: Calendar) -> String {
        let month = months[(calendar.component(.month, from: date) - 1 + 12) % 12]
        return "\(weekdayDay(date, calendar: calendar)) de \(month)"
    }

    /// "15:20"
    static func clock(_ date: Date, calendar: Calendar) -> String {
        String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
    }

    /// Primera letra en mayúscula (sentence case): "viernes 23" → "Viernes 23".
    static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// Miles con punto, como en Chile: 2500 → "2.500".
    static func thousands(_ value: Int) -> String {
        let digits = String(abs(value))
        var groups: [Substring] = []
        var end = digits.endIndex
        while end > digits.startIndex {
            let start = digits.index(end, offsetBy: -3, limitedBy: digits.startIndex) ?? digits.startIndex
            groups.insert(digits[start..<end], at: 0)
            end = start
        }
        return (value < 0 ? "-" : "") + groups.joined(separator: ".")
    }
}
