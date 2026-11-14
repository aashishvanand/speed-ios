import Foundation

/// One way of writing a speed, shared by the results screen and history so
/// the same measurement never reads differently in two places.
///
/// Precision scales with magnitude, so slow links don't round to "0":
/// 0.42 Mbps, 4.2 Mbps, 42 Mbps, 420 Mbps, 1.23 Gbps, 12.3 Gbps. Thresholds
/// sit at the rounding boundary, so 999.7 Mbps reads "1.00 Gbps", never
/// "1000 Mbps".
public enum SpeedFormat {
    public static func value(_ mbps: Double) -> String {
        let mbps = mbps.isFinite ? max(mbps, 0) : 0
        if mbps >= 999.5 {
            let gbps = mbps / 1000
            return String(format: gbps < 9.995 ? "%.2f" : "%.1f", gbps)
        }
        if mbps < 0.995 { return String(format: "%.2f", mbps) }
        if mbps < 9.95 { return String(format: "%.1f", mbps) }
        return String(format: "%.0f", mbps)
    }

    public static func unit(_ mbps: Double) -> String {
        mbps.isFinite && mbps >= 999.5 ? "Gbps" : "Mbps"
    }

    /// "42 Mbps".
    public static func text(_ mbps: Double) -> String {
        "\(value(mbps)) \(unit(mbps))"
    }
}
