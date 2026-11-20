import Foundation

/// One way of writing a speed, shared by the results screen and history so
/// the same measurement never reads differently in two places.
///
/// Precision scales with magnitude, so slow links don't round to "0":
/// 0.42 Mbps, 4.2 Mbps, 42 Mbps, 420 Mbps, 1.23 Gbps, 12.3 Gbps. Thresholds
/// sit at the rounding boundary, so 999.7 Mbps reads "1.00 Gbps", never
/// "1000 Mbps".
///
/// Numbers follow the region's decimal separator ("4,2 Mbps" in Germany)
/// even though the UI is English-only.
public enum SpeedFormat {
    public static func value(_ mbps: Double, locale: Locale = .current) -> String {
        let mbps = mbps.isFinite ? max(mbps, 0) : 0
        if mbps >= 999.5 {
            let gbps = mbps / 1000
            return number(gbps, fractionDigits: gbps < 9.995 ? 2 : 1, locale: locale)
        }
        if mbps < 0.995 { return number(mbps, fractionDigits: 2, locale: locale) }
        if mbps < 9.95 { return number(mbps, fractionDigits: 1, locale: locale) }
        return number(mbps, fractionDigits: 0, locale: locale)
    }

    public static func unit(_ mbps: Double) -> String {
        mbps.isFinite && mbps >= 999.5 ? "Gbps" : "Mbps"
    }

    /// "42 Mbps".
    public static func text(_ mbps: Double, locale: Locale = .current) -> String {
        "\(value(mbps, locale: locale)) \(unit(mbps))"
    }

    /// "12 ms", "1.6 ms": a duration in milliseconds, in the region's format.
    public static func milliseconds(_ ms: Double, fractionDigits: Int = 0, locale: Locale = .current) -> String {
        "\(number(ms.isFinite ? max(ms, 0) : 0, fractionDigits: fractionDigits, locale: locale)) ms"
    }

    /// A fixed number of decimals in `locale`'s format, without grouping:
    /// a speed or latency never reaches the thousands that would need it.
    public static func number(_ value: Double, fractionDigits: Int, locale: Locale = .current) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(fractionDigits))
                .rounded(rule: .toNearestOrAwayFromZero)
                .grouping(.never)
                .locale(locale)
        )
    }

    /// "1.9 GB": a byte count for "data used".
    public static func bytes(_ count: UInt64, locale: Locale = .current) -> String {
        Int64(clamping: count).formatted(.byteCount(style: .file).locale(locale))
    }
}
