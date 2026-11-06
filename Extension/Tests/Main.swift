import Foundation

@main struct CoreTest {
    static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let profile = try await analyze(url: url)
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("x.caf")
        try await extractAudio(from: url, to: wav)
        let phrases = try await transcribe(audio: wav, duration: profile.duration)
        for p in phrases { print(p.id, String(format: "%.2f-%.2f", p.start, p.end), p.text) }
        let ids = Array(0..<phrases.count).filter { $0 != 1 }
        let plan = autoPlan(ids: ids, phrases: phrases, profile: profile, maxPause: 0.5)
        print("plan clips:", plan.segments.count, "kept:", plan.keptSeconds)
    }
}
