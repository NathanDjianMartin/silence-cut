import Cocoa
import SwiftUI
import ProExtensionHost
import UniformTypeIdentifiers

enum EditMode: String, CaseIterable, Identifiable {
    case silences = "Silences"
    case auto = "Montage auto"
    var id: String { rawValue }
}

@MainActor
final class PanelModel: ObservableObject {
    @Published var file: URL?
    @Published var profile: AudioProfile?
    @Published var settings = SilenceSettings()
    @Published var status = ""
    @Published var busy = false
    @Published var progress = 0.0
    @Published var mode = EditMode.silences
    @Published var targetSeconds = 60.0
    @Published var apiKey = UserDefaults.standard.string(forKey: "anthropicKey") ?? "" {
        didSet { UserDefaults.standard.set(apiKey, forKey: "anthropicKey") }
    }
    @Published var phrases: [Phrase]?
    @Published var auto: AutoResult?          // "Montage auto" tab
    @Published var useTarget = true
    @Published var scriptedAI = false         // "IA" option of the Silences tab
    @Published var scripted: AutoResult?
    @Published var showSettings = false

    /// Recomputed from the cached audio levels, so sliders react instantly.
    var plan: CutPlan? { profile.map { makePlan($0, settings) } }

    /// AI-chosen phrases + the silence settings, recomputed live (the AI is not called again).
    var scriptedPlan: CutPlan? {
        guard let scripted, let profile else { return nil }
        return silenceCutScripted(scripted.ids, scripted.phrases, profile, settings)
    }

    /// What gets dragged / imported: the silence cut, or the AI edit.
    var activePlan: CutPlan? {
        switch mode {
        case .auto: return auto?.plan
        case .silences: return scriptedAI ? scriptedPlan : plan
        }
    }

    var hostInfo: String {
        guard let host = ProExtensionHostSingleton() as? FCPXHost else { return "" }
        var s = "\(host.name) \(host.versionString)"
        if let seq = host.timeline?.activeSequence { s += " · \(seq.name)" }
        return s
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audiovisualContent]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    // MARK: Folder access (sandbox)

    private static let bookmarksKey = "accessBookmarks"
    private var accessed: [URL] = []

    init() { restoreAccess() }

    /// Re-opens the folders the user already authorised (security-scoped bookmarks survive relaunches).
    private func restoreAccess() {
        for data in UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [Data] ?? [] {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() {
                accessed.append(url)
            }
        }
    }

    /// The sandboxed extension can't read arbitrary paths (e.g. an external drive). Ask once for the folder or disk.
    private func grantAccess(near url: URL) -> Bool {
        let parts = url.pathComponents
        let suggested = parts.count > 2 && parts[1] == "Volumes"
            ? URL(fileURLWithPath: "/Volumes/" + parts[2]) : url.deletingLastPathComponent()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = suggested
        panel.prompt = "Autoriser"
        panel.message = "SilenceCut doit être autorisé à lire ce média. Choisissez le disque ou le dossier qui contient vos rushes (une seule fois)."
        guard panel.runModal() == .OK, let dir = panel.url else { return false }
        if let data = try? dir.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            var all = UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [Data] ?? []
            all.append(data)
            UserDefaults.standard.set(all, forKey: Self.bookmarksKey)
        }
        if dir.startAccessingSecurityScopedResource() { accessed.append(dir) }
        return true
    }

    func load(_ url: URL) {
        if !FileManager.default.isReadableFile(atPath: url.path) {
            trace("not readable, asking access for \(url.path)")
            guard grantAccess(near: url), FileManager.default.isReadableFile(atPath: url.path) else {
                status = "Accès refusé à \(url.lastPathComponent). Réessayez et autorisez le disque ou le dossier."
                return
            }
        }
        file = url
        profile = nil
        phrases = nil
        auto = nil
        scripted = nil
        busy = true
        progress = 0
        status = "Analyse de l'audio…"
        Task {
            do {
                let p = try await analyze(url: url) { p in Task { @MainActor in self.progress = p } }
                profile = p
                targetSeconds = max(10, min(60, (p.duration / 2 / 5).rounded() * 5))
                status = ""
            } catch {
                trace("error \(error)")
                status = "Erreur : \(error.localizedDescription)"
            }
            busy = false
        }
    }

    /// Media path from an FCPXML snippet dragged out of Final Cut Pro.
    static func mediaURL(fromFCPXML data: Data) -> URL? {
        final class Finder: NSObject, XMLParserDelegate {
            var found: URL?
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes a: [String: String] = [:]) {
                guard found == nil, name == "media-rep" || name == "asset", let src = a["src"] else { return }
                if name == "media-rep", let kind = a["kind"], kind != "original-media" { return }
                found = URL(string: src) ?? URL(fileURLWithPath: src)
            }
        }
        let finder = Finder()
        let parser = XMLParser(data: data)
        parser.delegate = finder
        parser.parse()
        return finder.found
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let types = provider.registeredTypeIdentifiers
        trace("drop types: \(types)")
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                var url: URL?
                if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                else if let u = item as? URL { url = u }
                DispatchQueue.main.async {
                    if let url { self.load(url) } else { self.status = "Dépôt illisible." }
                }
            }
            return true
        }
        // Final Cut drags FCPXML: try every type, keep the first that yields media.
        Task { @MainActor in
            for type in types {
                let data: Data? = await withCheckedContinuation { cont in
                    provider.loadDataRepresentation(forTypeIdentifier: type) { d, _ in cont.resume(returning: d) }
                }
                if let data { try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("last-drop.txt")) }
                if let data, let url = Self.mediaURL(fromFCPXML: data) { self.load(url); return }
            }
            self.status = "Dépôt non reconnu. Types reçus : " + types.joined(separator: ", ")
        }
        return true
    }

    /// `scripted`: Silences tab with IA on -> only duplicates / failed takes removed. Otherwise the "Montage auto" tab.
    func generate(scripted isScripted: Bool) {
        guard let profile, let file else { return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            status = AutoEditError.noKey.localizedDescription
            showSettings = true
            return
        }
        busy = true
        progress = 0
        if isScripted { scripted = nil } else { auto = nil }
        let target: Double? = (isScripted || !useTarget) ? nil : targetSeconds
        let maxPause = settings.minDuration
        Task {
            do {
                var phrases = self.phrases
                if phrases == nil {
                    status = "Extraction de l'audio…"
                    let caf = FileManager.default.temporaryDirectory.appendingPathComponent("rush.caf")
                    try await extractAudio(from: file, to: caf) { p in Task { @MainActor in self.progress = p * 0.15 } }
                    status = "Transcription (sur ce Mac)…"
                    phrases = try await transcribe(audio: caf, duration: profile.duration) { p in
                        Task { @MainActor in self.progress = 0.15 + p * 0.7 }
                    }
                    self.phrases = phrases
                }
                status = "L'IA construit le montage…"
                progress = 0.9
                let result = try await buildAutoEdit(phrases: phrases!, profile: profile, target: target,
                                                     apiKey: key, maxPause: maxPause)
                if isScripted { scripted = result } else { auto = result }
                progress = 1
                status = ""
            } catch {
                trace("auto error \(error)")
                status = "Erreur : \(error.localizedDescription)"
            }
            busy = false
        }
    }

    func importIntoFinalCut() {
        guard let profile, let plan = activePlan else { return }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(profile.name + " - SilenceCut.fcpxml")
        do {
            try projectXML(profile, plan).write(to: out, atomically: true, encoding: .utf8)
            guard let fcp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FinalCut") else { return }
            NSWorkspace.shared.open([out], withApplicationAt: fcp, configuration: NSWorkspace.OpenConfiguration())
            status = "Import lancé dans Final Cut Pro."
        } catch {
            status = "Erreur : \(error.localizedDescription)"
        }
    }
}

private func silenceCutScripted(_ ids: [Int], _ phrases: [Phrase], _ profile: AudioProfile, _ s: SilenceSettings) -> CutPlan {
    scriptedPlan(ids: ids, phrases: phrases, profile: profile, settings: s)
}

func clock(_ seconds: Double) -> String {
    let s = Int(seconds)
    return String(format: "%d:%02d.%d", s / 60, s % 60, Int((seconds - Double(s)) * 10))
}

/// Whole clip as a bar: blue = kept, red = removed.
struct CutStrip: View {
    let profile: AudioProfile
    let plan: CutPlan

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.accentColor.opacity(0.55)))
            let total = Double(profile.totalFrames)
            for seg in plan.segments where seg.silent {
                let x = Double(seg.start) / total * size.width
                let w = max(Double(seg.end - seg.start) / total * size.width, 1)
                ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(.red))
            }
        }
        .frame(height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

/// Source of the drag into Final Cut's timeline: puts FCPXML on the pasteboard under Final Cut's own types.
struct DragSource: NSViewRepresentable {
    let title: String
    let xml: () -> String

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) { view.title = title; view.xml = xml }

    final class DragView: NSView, NSDraggingSource {
        var title = ""
        var xml: () -> String = { "" }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

        override func mouseDragged(with event: NSEvent) {
            let text = xml()
            let data = Data(text.utf8)
            let item = NSPasteboardItem()
            for v in ["com.apple.finalcutpro.xml.v1-14", "com.apple.finalcutpro.xml.v1-13", "com.apple.finalcutpro.xml.v1-12",
                      "com.apple.finalcutpro.xml.v1-11", "com.apple.finalcutpro.xml.v1-10", "com.apple.finalcutpro.xml"] {
                item.setData(data, forType: NSPasteboard.PasteboardType(v))
            }
            item.setString(text, forType: .string)
            trace("drag out \(data.count) bytes")

            let label = NSAttributedString(string: "  \(title)  ", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white])
            let size = NSSize(width: label.size().width + 8, height: 24)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                label.draw(at: NSPoint(x: 4, y: 4))
                return true
            }
            let dragItem = NSDraggingItem(pasteboardWriter: item)
            let origin = convert(event.locationInWindow, from: nil)
            dragItem.setDraggingFrame(NSRect(x: origin.x - size.width / 2, y: origin.y - size.height / 2,
                                             width: size.width, height: size.height), contents: image)
            beginDraggingSession(with: [dragItem], event: event, source: self)
        }
    }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @State private var targeted = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(systemName: "waveform.badge.plus").font(.title)
                    Text(model.file?.lastPathComponent ?? "Glissez un clip depuis Final Cut Pro")
                        .lineLimit(1).truncationMode(.middle)
                    Button("ou choisir un fichier…") { model.choose() }.buttonStyle(.link)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
                .background(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                    .foregroundStyle(targeted ? Color.accentColor : .secondary.opacity(0.5)))
                .onDrop(of: [.item], isTargeted: $targeted) { model.handleDrop($0) }
                if model.busy { ProgressView(value: model.progress) }
                if !model.status.isEmpty { Text(model.status).font(.callout).foregroundStyle(.secondary) }
            }

            if let profile = model.profile, let plan = model.plan {
                Section {
                    Picker("", selection: $model.mode) {
                        ForEach(EditMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if model.mode == .auto {
                    autoSections(profile)
                } else {
                    silenceSections(profile, plan)
                }

                if let active = model.activePlan {
                    Section {
                        Label("Glisser les clips vers la timeline", systemImage: "arrow.down.to.line")
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.2)))
                            .overlay(DragSource(title: "\(profile.name) · \(active.segments.filter { !$0.silent }.count) clips") {
                                model.activePlan.map { clipsXML(profile, $0) } ?? ""
                            })
                        Label("Glisser en un seul bloc (compound clip)", systemImage: "square.stack.3d.up")
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.2)))
                            .overlay(DragSource(title: "\(profile.name) · compound") {
                                model.activePlan.map { compoundXML(profile, $0) } ?? ""
                            })
                        Button("Importer comme nouveau projet") { model.importIntoFinalCut() }
                    }
                }
            }
            Text(model.hostInfo).font(.caption).foregroundStyle(.tertiary)
        }
        .formStyle(.grouped)
        .frame(minWidth: 320, minHeight: 460)
        .overlay(alignment: .topTrailing) {
            Button { model.showSettings.toggle() } label: {
                Image(systemName: model.apiKey.isEmpty ? "gearshape.trianglebadge.exclamationmark" : "gearshape")
            }
            .buttonStyle(.borderless)
            .padding(10)
            .help("Réglages")
            .popover(isPresented: $model.showSettings, arrowEdge: .bottom) { SettingsView(model: model) }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Réglages").font(.headline)
            SecureField("Clé API Anthropic (sk-ant-…)", text: $model.apiKey)
                .textFieldStyle(.roundedBorder)
            if model.apiKey.isEmpty {
                Text("Collez votre clé une seule fois : elle est enregistrée sur ce Mac et réutilisée à chaque lancement.")
            } else {
                Label("Clé enregistrée", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Supprimer la clé", role: .destructive) { model.apiKey = "" }
            }
            Text("La transcription reste sur ce Mac. Seul le texte du rush est envoyé à l'API Anthropic.")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(14)
        .frame(width: 290)
    }
}

extension PanelView {
    @ViewBuilder
    func silenceSections(_ profile: AudioProfile, _ plan: CutPlan) -> some View {
        Section {
            Toggle("IA : retirer doublons et prises ratées", isOn: $model.scriptedAI)
            if model.scriptedAI {
                Text("Pour un contenu scripté où vous vous êtes repris. Garde l'ordre et tout le reste ; les silences sont aussi coupés.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(model.scripted == nil ? "Analyser avec l'IA" : "Relancer l'IA") { model.generate(scripted: true) }
                    .disabled(model.busy)
                    .keyboardShortcut(.defaultAction)
            }
        }

        Section("Réglages des silences") { silenceSliders() }

        if model.scriptedAI {
            if let scripted = model.scripted { aiPreview(scripted, profile, target: nil, plan: model.scriptedPlan) }
        } else {
            plainSilenceSections(profile, plan)
        }
    }

    @ViewBuilder
    func silenceSliders() -> some View {
        LabeledContent("Seuil : \(Int(model.settings.thresholdDB)) dB") {
            Slider(value: $model.settings.thresholdDB, in: -70 ... -10, step: 1)
        }
        LabeledContent(String(format: "Silence min. : %.2f s", model.settings.minDuration)) {
            Slider(value: $model.settings.minDuration, in: 0.1 ... 3, step: 0.05)
        }
        LabeledContent(String(format: "Marge : %.2f s", model.settings.padding)) {
            Slider(value: $model.settings.padding, in: 0 ... 0.5, step: 0.01)
        }
    }

    @ViewBuilder
    func plainSilenceSections(_ profile: AudioProfile, _ plan: CutPlan) -> some View {
        Section("Aperçu des coupes") {
            CutStrip(profile: profile, plan: plan)
            Text(String(format: "%d coupes · %.1f s retirées · %@ → %@ (−%d %%)",
                        plan.cuts.count, plan.removedSeconds, clock(profile.duration),
                        clock(plan.keptSeconds), Int((plan.removedSeconds / max(profile.duration, 1) * 100).rounded())))
                .font(.callout)
            ForEach(Array(plan.cuts.prefix(6).enumerated()), id: \.offset) { _, cut in
                HStack {
                    Text("\(clock(cut.start)) → \(clock(cut.end))").monospacedDigit()
                    Spacer()
                    Text(String(format: "−%.1f s", cut.end - cut.start)).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            if plan.cuts.count > 6 {
                Text("+ \(plan.cuts.count - 6) autres coupes").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    func autoSections(_ profile: AudioProfile) -> some View {
        Section("Montage auto") {
            Toggle("Durée cible", isOn: $model.useTarget)
            if model.useTarget {
                LabeledContent(clock(model.targetSeconds)) {
                    Slider(value: $model.targetSeconds, in: 10 ... max(30, profile.duration), step: 5)
                }
            } else {
                Text("Sans durée cible, l'IA retire seulement les doublons et les prises ratées.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(model.auto == nil ? "Générer le montage" : "Régénérer") { model.generate(scripted: false) }
                .disabled(model.busy)
                .keyboardShortcut(.defaultAction)
        }

        if let auto = model.auto {
            aiPreview(auto, profile, target: model.useTarget ? model.targetSeconds : nil)
        }
    }

    @ViewBuilder
    func aiPreview(_ auto: AutoResult, _ profile: AudioProfile, target: Double?, plan: CutPlan? = nil) -> some View {
        let shown = plan ?? auto.plan
        Section("Aperçu du montage") {
                Text(target.map { String(format: "%@ obtenus pour %@ demandés · %d clips", clock(shown.keptSeconds), clock($0), shown.segments.count) }
                     ?? String(format: "%@ → %@ · %d clips", clock(profile.duration), clock(shown.keptSeconds), shown.segments.count))
                    .font(.callout)
                if !auto.note.isEmpty { Text(auto.note).font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(auto.kept.prefix(8).enumerated()), id: \.offset) { i, p in
                    HStack(alignment: .top) {
                        Text("\(i + 1)").foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                        Text(p.text).lineLimit(2)
                        Spacer(minLength: 4)
                        Text(clock(p.start)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                if auto.kept.count > 8 {
                    Text("+ \(auto.kept.count - 8) autres phrases").font(.caption).foregroundStyle(.secondary)
                }
        }
    }
}

@objc(SilenceCutViewController)
final class SilenceCutViewController: NSViewController {
    override func loadView() {
        view = NSHostingView(rootView: PanelView(model: MainActor.assumeIsolated { PanelModel() }))
    }
}
