// Prints the CGWindowID of the frontmost on-screen window owned by the named
// app, for `screencapture -l`. Used by scripts/take-screenshots.sh.
import CoreGraphics
let owner = CommandLine.arguments.dropFirst().first ?? "Edge Speed"
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
if let w = windows.first(where: { $0[kCGWindowOwnerName as String] as? String == owner && $0[kCGWindowLayer as String] as? Int == 0 }),
   let id = w[kCGWindowNumber as String] as? Int {
    print(id)
}
