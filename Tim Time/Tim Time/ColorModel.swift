import SwiftUI

/// A user-managed color "category" — a named color labels can be assigned to.
/// Stored as sRGB components (0…1) so it's plainly Codable and theme-independent;
/// the SwiftUI `Color` is derived. Persisted in `palette.json`. Identity is a
/// stable `UUID` so a category survives being renamed or recolored, and so the
/// label→color map (`labelColors.json`) can key on it.
struct ColorCategory: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var red: Double
    var green: Double
    var blue: Double

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }

    init(id: UUID = UUID(), name: String, red: Double, green: Double, blue: Double) {
        self.id = id
        self.name = name
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(id: UUID = UUID(), name: String, swatch: ColorSwatch) {
        self.init(id: id, name: name, red: swatch.red, green: swatch.green, blue: swatch.blue)
    }
}

extension Color {
    /// Shared dark track drawn behind chart bars / timeline strips so the
    /// colored segments read with good contrast in both light and dark mode.
    static let chartTrack = Color.black.opacity(0.25)
}

/// A raw sRGB triple used for the preset palette shown in the color pickers and
/// the "Manage Colors" screen. No identity — just a pickable color value.
struct ColorSwatch: Identifiable, Hashable {
    let red: Double
    let green: Double
    let blue: Double
    var id: String { "\(red)-\(green)-\(blue)" }
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
}

/// One row in a by-color rollup (weekly / monthly). Groups every label sharing a
/// category into a single total.
struct ColorTotal: Identifiable {
    let category: ColorCategory
    let total: TimeInterval
    var id: UUID { category.id }
}

enum ColorPalette {
    /// Legible-on-menu-material colors, medium saturation so they read in both
    /// light and dark mode. The first 8 seed the fixed palette; the palette is
    /// static (users rename colors, they don't recolor/add them).
    static let presets: [ColorSwatch] = [
        ColorSwatch(red: 0.20, green: 0.48, blue: 0.92),  // blue
        ColorSwatch(red: 0.30, green: 0.72, blue: 0.42),  // green
        ColorSwatch(red: 0.95, green: 0.58, blue: 0.18),  // orange
        ColorSwatch(red: 0.60, green: 0.40, blue: 0.90),  // purple
        ColorSwatch(red: 0.90, green: 0.33, blue: 0.33),  // red
        ColorSwatch(red: 0.20, green: 0.70, blue: 0.72),  // teal
        ColorSwatch(red: 0.94, green: 0.44, blue: 0.68),  // pink
        ColorSwatch(red: 0.85, green: 0.72, blue: 0.20),  // yellow
        ColorSwatch(red: 0.45, green: 0.55, blue: 0.62),  // slate
        ColorSwatch(red: 0.55, green: 0.45, blue: 0.35),  // brown
        ColorSwatch(red: 0.40, green: 0.62, blue: 0.95),  // sky
        ColorSwatch(red: 0.72, green: 0.30, blue: 0.55),  // magenta
    ]

    /// The fixed 8-color palette seeded on first launch. Names start EMPTY — the
    /// user names only the colors they care about (in the "Name Colors" screen).
    /// The FIRST entry is the default color for any unassigned label.
    static func seedCategories() -> [ColorCategory] {
        (0..<8).map { ColorCategory(name: "", swatch: presets[$0]) }
    }
}
