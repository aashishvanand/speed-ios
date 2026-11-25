import SwiftUI
import CFSpeedKit

/// Grade text colours, picked for the glass card they sit on and for the
/// accessibility settings in force.
///
/// The system colours are tuned for dark backgrounds: yellow and orange on
/// light glass fall well under 4.5:1, so light mode uses darker shades that
/// clear it on white. Increase Contrast asks for more, not less: the light
/// shades darken to 7.9–9.5:1 on white, and dark mode moves from the system
/// colours (blue and red are only 3.8:1 and 4.1:1 on the dark card) to paler
/// ones that clear 7:1 on `#2C2C2E`. The grade is always a word as well as a
/// colour, so none of this is the only cue.
extension QualityGrade {
    func textColor(scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        switch (scheme, contrast) {
        case (.light, .standard):
            switch self {
            case .great: return Color(red: 0.11, green: 0.48, blue: 0.20) // 5.4:1 on white
            case .good: return Color(red: 0.00, green: 0.35, blue: 0.72) // 6.7:1
            case .average: return Color(red: 0.55, green: 0.40, blue: 0.00) // 5.2:1
            case .poor: return Color(red: 0.70, green: 0.28, blue: 0.00) // 5.5:1
            case .bad: return Color(red: 0.75, green: 0.10, blue: 0.10) // 6.2:1
            }
        case (.light, .increased):
            switch self {
            case .great: return Color(red: 0.05, green: 0.35, blue: 0.12) // 8.5:1 on white
            case .good: return Color(red: 0.00, green: 0.26, blue: 0.58) // 9.5:1
            case .average: return Color(red: 0.42, green: 0.30, blue: 0.00) // 7.9:1
            case .poor: return Color(red: 0.55, green: 0.20, blue: 0.00) // 8.1:1
            case .bad: return Color(red: 0.60, green: 0.05, blue: 0.05) // 8.7:1
            }
        case (.dark, .standard):
            switch self {
            case .great: return .green
            case .good: return .blue
            case .average: return .yellow
            case .poor: return .orange
            case .bad: return .red
            }
        case (.dark, .increased):
            switch self {
            case .great: return Color(red: 52 / 255, green: 222 / 255, blue: 94 / 255) // 7.8:1 on #2C2C2E
            case .good: return Color(red: 135 / 255, green: 195 / 255, blue: 255 / 255) // 7.5:1
            case .average: return Color(red: 255 / 255, green: 224 / 255, blue: 80 / 255) // 10.6:1
            case .poor: return Color(red: 255 / 255, green: 190 / 255, blue: 100 / 255) // 8.5:1
            case .bad: return Color(red: 255 / 255, green: 160 / 255, blue: 150 / 255) // 7.1:1
            }
        @unknown default:
            return textColor(scheme: scheme, contrast: .standard)
        }
    }
}
