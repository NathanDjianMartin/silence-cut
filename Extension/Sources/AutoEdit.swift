import AVFoundation
import Speech

// Automatic edit: on-device transcription -> Claude picks/reorders phrases to hit a target duration -> cut plan.

struct Word { var text: String; var start: Double; var end: Double }

struct Phrase {
    var id: Int
    var start: Double
    var end: Double
    var text: String
    var words: [Word] = []
    var hesitations: Set<Int> = []   // indices in `words` to cut out ("euh", stutters…)
    var duration: Double { end - start }
}

struct AutoResult {
    var ids: [Int]          // chosen phrase ids, in final order
    var plan: CutPlan
    var phrases: [Phrase]   // all phrases, with the hesitations marked (lexicon + AI)
    var kept: [Phrase]      // in final order
    var total: Double
    var note: String
}

enum AutoEditError: LocalizedError {
    case noKey, unsupportedLocale, noSpeech, api(String), badAnswer
    var errorDescription: String? {
        switch self {
        case .noKey: return "Ajoutez votre clé API Anthropic."
        case .unsupportedLocale: return "Transcription française indisponible sur ce Mac."
        case .noSpeech: return "Aucune parole détectée dans ce média."
        case .api(let m): return "Erreur API : \(m)"
        case .badAnswer: return "Réponse de l'IA illisible."
        }
    }
}

// MARK: - Audio extraction

/// Decodes the audio track to a 16 kHz mono CAF the speech analyzer can read (works for any container AVFoundation opens).
func extractAudio(from url: URL, to out: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw SilenceError.noAudio }
    let duration = try await asset.load(.duration).seconds
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    reader.startReading()
    try? FileManager.default.removeItem(at: out)
    let file = try AVAudioFile(forWriting: out, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
    ])
    while let sb = output.copyNextSampleBuffer() {
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
        let frames = CMBlockBufferGetDataLength(bb) / 4
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))
        else { continue }
        buf.frameLength = AVAudioFrameCount(frames)
        CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: frames * 4, destination: buf.floatChannelData![0])
        try file.write(from: buf)
        if duration > 0 { progress?(min(CMSampleBufferGetPresentationTimeStamp(sb).seconds / duration, 1)) }
    }
    if let error = reader.error { throw error }
}

// MARK: - Transcription

func transcribe(audio: URL, duration: Double, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [Phrase] {
    let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "fr-FR"))
    guard let locale else { throw AutoEditError.unsupportedLocale }
    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                        attributeOptions: [.audioTimeRange])
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        trace("downloading speech model")
        try await request.downloadAndInstall()
    }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let file = try AVAudioFile(forReading: audio)

    let collector = Task { () -> [Word] in
        var words: [Word] = []
        for try await result in transcriber.results {
            for run in result.text.runs {
                let text = String(result.text[run.range].characters)
                if let range = run.audioTimeRange {
                    let w = text.trimmingCharacters(in: .whitespaces)
                    if !w.isEmpty { words.append(Word(text: w, start: range.start.seconds, end: range.end.seconds)) }
                } else if !words.isEmpty {
                    words[words.count - 1].text += text.trimmingCharacters(in: .whitespaces) // punctuation
                }
            }
            if duration > 0, let last = words.last { progress?(min(last.end / duration, 1)) }
        }
        return words
    }
    if let last = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: last)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    let words = try await collector.value
    trace("transcribed \(words.count) words")
    guard !words.isEmpty else { throw AutoEditError.noSpeech }
    return makePhrases(words)
}

/// Pure hesitation sounds ("euh", "heu", "hum", "hmm", "mmh", "uh"…). Never real words such as "eu".
private func isFillerSound(_ s: String) -> Bool {
    s.range(of: "^(h+e+u+h*|e+u+h+|e+h+m+|h?u+m+|h+m+|m+h+m*|u+h+)$", options: .regularExpression) != nil
}

/// Groups words into short segments the AI can keep or drop whole. A segment ends on a pause of 0.3 s, on
/// sentence-final punctuation, or where the speaker restarts: when the last two words repeat two earlier words of the
/// same segment, everything before the repeat is an abandoned attempt and becomes its own segment.
private func makePhrases(_ words: [Word]) -> [Phrase] {
    var phrases: [Phrase] = []
    var cur: [Word] = []
    func flush() {
        guard let first = cur.first, let last = cur.last else { return }
        phrases.append(Phrase(id: phrases.count, start: first.start, end: last.end,
                              text: cur.map(\.text).joined(separator: " "), words: cur,
                              hesitations: Set(cur.indices.filter { isFillerSound(norm(cur[$0])) })))
        cur = []
    }
    func norm(_ w: Word) -> String { w.text.lowercased().filter { $0.isLetter || $0.isNumber } }
    for w in words {
        if let prev = cur.last, w.start - prev.end >= 0.3 { flush() }
        cur.append(w)
        let n = cur.count
        if n >= 4 {
            let a = norm(cur[n - 2]), b = norm(cur[n - 1])
            if a.count + b.count >= 5,
               (0 ..< n - 3).contains(where: { norm(cur[$0]) == a && norm(cur[$0 + 1]) == b }) {
                let restart = Array(cur[(n - 2)...])
                cur.removeLast(2)
                flush()
                cur = restart
            }
        }
        if let c = cur.last?.text.last, ".?!…".contains(c) || cur.count >= 30 { flush() }
    }
    flush()
    return phrases
}

// MARK: - AI

/// Text with a [n] marker before each word so the AI can point at the hesitations to cut.
private func indexed(_ p: Phrase) -> String {
    p.words.isEmpty ? p.text : p.words.enumerated().map { "[\($0)]\($1.text)" }.joined(separator: " ")
}

private func fmt(_ s: Double) -> String { String(format: "%.1f", s) }

/// Asks Claude which phrases to keep. With a target duration it picks/reorders to approach it (and is nudged if the total
/// misses); without one it only removes duplicates and failed takes, keeping everything else in order.
func chooseKeptPhrases(_ phrases: [Phrase], target: Double?, apiKey: String,
                       totalFor: ([Int]) -> Double) async throws -> (ids: [Int], note: String, hesitations: [(Int, Int)]) {
    let listing = phrases.enumerated().map { i, p in
        let pause = i > 0 ? p.start - phrases[i - 1].end : p.start
        let unfinished = p.text.last.map { !".?!…".contains($0) } ?? true
        return "\(p.id) | \(fmt(p.duration)) s | pause avant \(fmt(pause)) s | \(unfinished ? "[sans ponctuation finale] " : "")\(indexed(p))"
    }.joined(separator: "\n")
    var messages: [[String: String]] = [["role": "user", "content": "Transcription :\n\(listing)"]]

    guard let target else {
        let system = """
        Tu es un monteur vidéo expert. Tu reçois la transcription d'un rush SCRIPTÉ : la personne lit ou récite un texte \
        prévu et se reprend quand elle se rate, parfois plusieurs fois de suite. Le texte est découpé en segments courts \
        numérotés, avec leur durée, la pause qui les précède, et un indice [sans ponctuation finale] quand le segment \
        semble coupé.

        Ton travail : ne garder que la MEILLEURE PRISE de chaque passage du texte, c'est-à-dire reconstituer le texte final \
        propre, tel qu'il doit être dit une seule fois.

        Une PRISE RATÉE n'est pas forcément une copie exacte de la bonne. C'est tout segment qui fait partie d'une tentative \
        abandonnée ou défaillante :
        - une phrase coupée en plein milieu, que la personne recommence juste après (même si ce début n'apparaît qu'en partie \
          dans la reprise, ou avec d'autres mots) : le début coupé est une prise ratée, ne le garde JAMAIS ;
        - un faux départ, un mot ou un groupe de mots répété avant de relancer la phrase ;
        - une phrase terminée mais mal dite (mot buté, hésitation, « euh », mauvaise formulation) qui est redite ensuite ;
        - une phrase inachevée suivie d'une pause puis d'une nouvelle tentative de la même idée ;
        - une réflexion à voix haute ou un commentaire hors texte (« attends », « je la refais »).
        Indices : une pause avant un segment qui recommence le début d'un précédent, un segment sans ponctuation finale \
        suivi d'un segment qui reprend la même idée, plusieurs segments qui commencent par les mêmes mots.

        Quand une même idée apparaît plusieurs fois, garde la dernière prise COMPLÈTE et fluide (en général la dernière, \
        mais si la toute dernière est elle-même coupée ou ratée, garde la précédente complète). Si une prise complète \
        existe, aucun morceau des tentatives précédentes ne doit subsister. Une prise est complète seulement si elle va \
        jusqu'au bout de la phrase ; ses segments consécutifs vont ensemble.
        Garde tout le texte qui n'a pas été redit, dans l'ordre chronologique d'origine. Ne réordonne pas, ne résume pas.


        Hésitations : dans les segments que tu gardes, repère aussi les mots à couper qui ne portent aucun sens : « euh », \
        « heu », « hum », « bah »/« ben » d'hésitation, « genre » ou « du coup » tics sans valeur, et le premier mot d'une \
        répétition bégayée (« le le », « on a on a »). Chaque mot est précédé de son index entre crochets. Donne-les sous \
        "hesitations" : [[id du segment, index du mot], ...]. Ne coupe pas un mot nécessaire au sens.

        Réponds uniquement par un objet JSON, dans cet ordre :
        {"analyse":[{"idee":"résumé court du passage","tentatives":[ids],"gardee":[ids de la prise retenue]}],
         "keep":[tous les ids gardés, dans l'ordre],"hesitations":[[id,index],...],"note":"une phrase résumant ce que tu as retiré"}
        """
        let reply = try await callClaude(system: system, messages: messages, apiKey: apiKey)
        guard let parsed = parseKeep(reply, valid: phrases.count) else { throw AutoEditError.badAnswer }
        return (dropRestarts(parsed.ids.sorted(), phrases), parsed.note, parsed.hesitations)
    }

    let tolerance = max(3.0, target * 0.05)
    let system = """
    Tu es un monteur vidéo expert. On te donne la transcription d'un rush non scripté (le ton est libre, la personne improvise) \
    découpée en phrases numérotées avec leur durée. Construis le montage final d'une durée de \(fmt(target)) secondes (à ±\(fmt(tolerance)) s).
    Règles :
    - Supprime les doublons, prises ratées, faux départs, hésitations et phrases inachevées. Quand une idée est dite plusieurs fois, garde la meilleure prise (souvent la dernière complète).
    - Garde les passages les plus forts, clairs et utiles ; écarte le remplissage et les digressions.
    - Tu peux réordonner les phrases si cela rend le récit meilleur ; sinon garde l'ordre chronologique.
    - Ne coupe jamais une phrase en deux : tu choisis des phrases entières.
    - La somme des durées des phrases gardées doit se rapprocher le plus possible de \(fmt(target)) secondes.
    - Dans les phrases gardées, repère les mots à couper qui ne portent aucun sens (« euh », « heu », « hum », « ben »/« bah » \
      d'hésitation, tics sans valeur, premier mot d'une répétition bégayée). Chaque mot est précédé de son index entre crochets ; \
      donne-les sous "hesitations" : [[id de la phrase, index du mot], ...].
    Réponds uniquement par un objet JSON : {"keep":[ids dans l'ordre final],"hesitations":[[id,index],...],"note":"une phrase expliquant tes choix"}
    """

    var best: (ids: [Int], note: String, hes: [(Int, Int)], error: Double)?
    for attempt in 0 ..< 3 {
        let reply = try await callClaude(system: system, messages: messages, apiKey: apiKey)
        guard let parsed = parseKeep(reply, valid: phrases.count) else { throw AutoEditError.badAnswer }
        let total = totalFor(parsed.ids)
        let error = abs(total - target)
        trace("attempt \(attempt): \(parsed.ids.count) phrases, \(fmt(total)) s for target \(fmt(target)) s")
        if best == nil || error < best!.error { best = (parsed.ids, parsed.note, parsed.hesitations, error) }
        if error <= tolerance { break }
        messages.append(["role": "assistant", "content": reply])
        messages.append(["role": "user", "content": """
            Ce montage dure \(fmt(total)) s au lieu de \(fmt(target)) s (\(total > target ? "trop long" : "trop court") de \(fmt(error)) s). \
            Ajuste la sélection pour viser \(fmt(target)) s et renvoie le JSON complet.
            """])
    }
    return (best!.ids, best!.note, best!.hes)
}

private func parseKeep(_ text: String, valid count: Int) -> (ids: [Int], note: String, hesitations: [(Int, Int)])? {
    guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
          let json = try? JSONSerialization.jsonObject(with: Data(text[a ... b].utf8)) as? [String: Any],
          let keep = json["keep"] as? [Any] else { return nil }
    var seen = Set<Int>()
    let ids = keep.compactMap { ($0 as? Int) ?? Int("\($0)") }.filter { $0 >= 0 && $0 < count && seen.insert($0).inserted }
    let hes: [(Int, Int)] = (json["hesitations"] as? [[Any]] ?? []).compactMap { pair in
        guard pair.count == 2, let p = (pair[0] as? Int) ?? Int("\(pair[0])"), let w = (pair[1] as? Int) ?? Int("\(pair[1])")
        else { return nil }
        return (p, w)
    }
    return ids.isEmpty ? nil : (ids, json["note"] as? String ?? "", hes)
}

private func callClaude(system: String, messages: [[String: String]], apiKey: String,
                        model: String = "claude-sonnet-5-5") async throws -> String {
    do { return try await sendClaude(system: system, messages: messages, apiKey: apiKey, model: model) }
    catch AutoEditError.api(let message) where model != "claude-sonnet-5-5" {
        trace("model \(model) failed (\(message)), falling back to sonnet")
        return try await sendClaude(system: system, messages: messages, apiKey: apiKey, model: "claude-sonnet-5-5")
    }
}

private func sendClaude(system: String, messages: [[String: String]], apiKey: String, model: String) async throws -> String {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    req.httpMethod = "POST"
    req.timeoutInterval = 180
    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.httpBody = try JSONSerialization.data(withJSONObject: [
        "model": model, "max_tokens": 8192, "system": system, "messages": messages,
    ] as [String: Any])
    let (data, response) = try await URLSession.shared.data(for: req)
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    if (response as? HTTPURLResponse)?.statusCode != 200 {
        let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
        throw AutoEditError.api(message)
    }
    guard let content = json?["content"] as? [[String: Any]],
          let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
    else { throw AutoEditError.badAnswer }
    return text
}

/// Safety net: if a kept segment is directly followed by a longer one that starts with the same words,
/// the first one is an abandoned attempt the AI let through.
private func dropRestarts(_ ids: [Int], _ phrases: [Phrase]) -> [Int] {
    func head(_ id: Int) -> [String] {
        phrases[id].text.lowercased().split(separator: " ").prefix(2).map { $0.filter { $0.isLetter || $0.isNumber } }
    }
    var out: [Int] = []
    for (i, id) in ids.enumerated() {
        if i + 1 < ids.count {
            let next = ids[i + 1]
            let h = head(id)
            if h.count == 2, h.joined().count >= 5, h == head(next), phrases[next].duration > phrases[id].duration {
                trace("dropRestarts: dropped \(id) (restarted by \(next))")
                continue
            }
        }
        out.append(id)
    }
    return out
}

// MARK: - Plan

/// Frame-aligned clip ranges for the chosen phrases. Padding never reaches into a neighbouring phrase;
/// consecutive phrases are joined when the natural pause between them is shorter than `maxPause`.
func ranges(for ids: [Int], phrases: [Phrase], duration: Double, maxPause: Double,
            padBefore: Double = 0.1, padAfter: Double = 0.15) -> [(start: Double, end: Double)] {
    var out: [(start: Double, end: Double)] = []
    var lastID: Int?
    for id in ids {
        let p = phrases[id]
        let prevEnd = id > 0 ? phrases[id - 1].end : 0
        let nextStart = id + 1 < phrases.count ? phrases[id + 1].start : duration
        let start = p.start - min(padBefore, max(p.start - prevEnd, 0) / 2)
        let end = p.end + min(padAfter, max(nextStart - p.end, 0) / 2)
        if let last = lastID, id == last + 1, p.start - phrases[last].end < maxPause, !out.isEmpty {
            out[out.count - 1].end = end
        } else {
            out.append((start, end))
        }
        lastID = id
    }
    let cuts = ids.flatMap { hesitationCuts(phrases[$0]) }
    return cuts.isEmpty ? out : out.flatMap { subtract($0, cuts) }.filter { $0.end - $0.start >= 0.05 }
}

/// Time ranges of the words marked as hesitations, with a little of the pause around each.
private func hesitationCuts(_ p: Phrase) -> [(start: Double, end: Double)] {
    p.hesitations.sorted().compactMap { i in
        guard i < p.words.count else { return nil }
        let w = p.words[i]
        let before = i > 0 ? w.start - p.words[i - 1].end : 0.08
        let after = i + 1 < p.words.count ? p.words[i + 1].start - w.end : 0.08
        return (w.start - min(max(before, 0), 0.08), w.end + min(max(after, 0), 0.08))
    }
}

private func subtract(_ r: (start: Double, end: Double), _ cuts: [(start: Double, end: Double)]) -> [(start: Double, end: Double)] {
    cuts.reduce([r]) { pieces, c in
        pieces.flatMap { s -> [(start: Double, end: Double)] in
            guard c.end > s.start, c.start < s.end else { return [s] }
            var parts: [(start: Double, end: Double)] = []
            if c.start > s.start { parts.append((s.start, c.start)) }
            if c.end < s.end { parts.append((c.end, s.end)) }
            return parts
        }
    }
}

func autoPlan(ids: [Int], phrases: [Phrase], profile: AudioProfile, maxPause: Double) -> CutPlan {
    let fps = profile.fps
    var segs: [CutPlan.Segment] = []
    for r in ranges(for: ids, phrases: phrases, duration: profile.duration, maxPause: maxPause) {
        let a = Int64((r.start * fps).rounded()), b = min(Int64((r.end * fps).rounded()), profile.totalFrames)
        if b > a { segs.append(.init(silent: false, start: a, end: b)) }
    }
    let kept = segs.reduce(0) { $0 + ($1.end - $1.start) }
    return CutPlan(segments: segs, cuts: [], removedSeconds: profile.duration - Double(kept) / fps,
                   keptSeconds: Double(kept) / fps)
}

/// Silences-tab plan with IA on: the phrases the AI kept, then the usual silence cutting (threshold, minimum
/// duration, margin) applied inside them. Cheap, so sliders stay live without calling the AI again.
func scriptedPlan(ids: [Int], phrases: [Phrase], profile: AudioProfile, settings: SilenceSettings) -> CutPlan {
    let speech = makePlan(profile, settings).segments.filter { !$0.silent }
    let fps = profile.fps
    var out: [CutPlan.Segment] = []
    for r in ranges(for: ids, phrases: phrases, duration: profile.duration, maxPause: 0,
                    padBefore: settings.padding, padAfter: settings.padding) {
        let a = Int64((r.start * fps).rounded()), b = min(Int64((r.end * fps).rounded()), profile.totalFrames)
        for seg in speech {
            let lo = max(a, seg.start), hi = min(b, seg.end)
            guard hi > lo else { continue }
            if let last = out.last, last.end == lo { out[out.count - 1].end = hi }
            else { out.append(.init(silent: false, start: lo, end: hi)) }
        }
    }
    let kept = out.reduce(0) { $0 + ($1.end - $1.start) }
    return CutPlan(segments: out, cuts: [], removedSeconds: profile.duration - Double(kept) / fps,
                   keptSeconds: Double(kept) / fps)
}

func buildAutoEdit(phrases: [Phrase], profile: AudioProfile, target: Double?, apiKey: String,
                   maxPause: Double) async throws -> AutoResult {
    let (ids, note, hesitations) = try await chooseKeptPhrases(phrases, target: target, apiKey: apiKey) { ids in
        autoPlan(ids: ids, phrases: phrases, profile: profile, maxPause: maxPause).keptSeconds
    }
    var marked = phrases
    for (p, w) in hesitations where p < marked.count && ids.contains(p) && w >= 0 && w < marked[p].words.count {
        marked[p].hesitations.insert(w)
    }
    let plan = autoPlan(ids: ids, phrases: marked, profile: profile, maxPause: maxPause)
    return AutoResult(ids: ids, plan: plan, phrases: marked, kept: ids.map { marked[$0] }, total: plan.keptSeconds, note: note)
}
