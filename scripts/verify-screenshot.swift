// Exits 0 when Vision recognizes at least 3 lines of text in the image — a
// healthy UI screenshot — and 1 otherwise. Used by
// scripts/take-screenshots.sh to catch the occasional frame the simulator
// captures before the app has drawn anything (those read at most the system
// clock), and to retry with a fresh launch instead of shipping a blank shot.
import Vision
import AppKit

guard CommandLine.arguments.count > 1,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    exit(1)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
try VNImageRequestHandler(cgImage: cg).perform([request])
let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    .filter { !$0.isEmpty }
exit(lines.count >= 3 ? 0 : 1)
