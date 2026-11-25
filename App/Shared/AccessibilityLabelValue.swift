import SwiftUI

extension View {
    /// Gives a composite accessibility element its label and value.
    ///
    /// iOS and tvOS read the two attributes separately. macOS's SwiftUI bridge
    /// keeps the label on an `AXGroup` but drops `accessibilityValue`, so a
    /// combined element reads "Download" with no number — and a history row
    /// reads its metrics without values. Folding the value into the label
    /// there keeps every number in the tree VoiceOver reads.
    func accessibilityLabelAndValue(_ label: String, _ value: String) -> some View {
        #if os(macOS)
        // `Text(verbatim:)` keeps the interpolated label out of the String
        // Catalog: the pieces are runtime values, not a localizable format.
        accessibilityLabel(Text(verbatim: "\(label), \(value)"))
        #else
        accessibilityLabel(label)
            .accessibilityValue(value)
        #endif
    }
}
