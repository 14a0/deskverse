import Foundation

/// Meta's Llama 3.2 3B (open weights), running on this Mac through Ollama at localhost.
/// EOU's only HTTP call goes to localhost; nothing leaves the Mac.
/// Tested 2026-11-05: with each desk described by what was on it and the answer limited to real desk
/// names, it matched 4 of 4 sentences in about 0.4 s. Asked for a bare number, it got 1 of 4, so never do that.
enum MetaModel {
    /// Meta's Llama 3.1 8B when installed (it links a vague sentence to the right desk; 3.2 3B could not, tested
    /// 2026-11-05), otherwise Llama 3.2 3B.
    nonisolated(unsafe) static var model = "llama3.2:3b"
    nonisolated(unsafe) static var label = "Llama 3.2"
    /// Set by the --ask test to print what Llama sees and answers.
    nonisolated(unsafe) static var trace: ((String) -> Void)?
    private static let base = URL(string: "http://127.0.0.1:11434")!
    private static var checkedAt = Date.distantPast
    private static var lastAvailable = false

    /// True when Ollama is running and has the model. Checked at most once a minute.
    static func available() async -> Bool {
        if Date().timeIntervalSince(checkedAt) < 60 { return lastAvailable }
        checkedAt = Date()
        var request = URLRequest(url: base.appendingPathComponent("api/tags"))
        request.timeoutInterval = 1.5
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            lastAvailable = false
            return false
        }
        let names = models.compactMap { $0["name"] as? String }
        if names.contains("llama3.1:8b") { model = "llama3.1:8b"; label = "Llama 3.1" } else { model = "llama3.2:3b"; label = "Llama 3.2" }
        lastAvailable = names.contains(model)
        return lastAvailable
    }

    /// One structured answer, constrained by a JSON schema.
    static func generate(_ prompt: String, schema: [String: Any]) async -> [String: Any]? {
        guard await available() else { return nil }
        var request = URLRequest(url: base.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": model, "prompt": prompt, "stream": false, "format": schema,
                                   "options": ["temperature": 0], "keep_alive": "30m"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String,
              let answer = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return answer
    }

    /// Names what a window of tabs is about, in 2 to 4 words.
    static func nameGroup(titles: [String]) async -> String? {
        let list = titles.prefix(12).map { "- \($0)" }.joined(separator: "\n")
        let prompt = "These are the titles of browser tabs open together in one window:\n\(list)\nName the one subject the person is working on in 2 to 4 words, Title Case. Name the subject, never the app or website. Reply as JSON."
        let schema: [String: Any] = ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]]
        guard let name = (await generate(prompt, schema: schema))?["name"] as? String else { return nil }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean.count > 40 ? nil : clean
    }

    enum Pick { case desk(String), noMatch, unavailable }

    /// Picks which saved desk a sentence means. `desks` maps each desk name to a short description of what was on it.
    /// "No match" is a real answer: a wrong desk costs more trust than none. A small model reaches for the
    /// nearest desk when none fits, so the question is asked twice with the list reversed; only an answer
    /// that survives the reordering counts (tested 2026-11-05).
    static func pickDesk(for query: String, desks: [(name: String, about: String)]) async -> Pick {
        guard !desks.isEmpty else { return .noMatch }
        guard await available() else { return .unavailable }
        let names = desks.map(\.name)
        let schema: [String: Any] = ["type": "object",
                                     "properties": ["topic": ["type": "string", "enum": names + ["none"]]],
                                     "required": ["topic"]]
        func ask(_ ordered: [(name: String, about: String)]) async -> String?? {
            let listing = ordered.map { "- \($0.name): \($0.about)" }.joined(separator: "\n")
            let prompt = "Saved desks, each with what was on it:\n\(listing)\nThe person says: \"\(query)\"\nWhich desk do they want back? A desk fits only if what was on it is clearly about what they describe. Reply as JSON with its exact name, or none if no desk fits."
            guard let answer = await generate(prompt, schema: schema) else { return .none }
            let topic = answer["topic"] as? String
            return .some(topic.flatMap { names.contains($0) ? $0 : nil })
        }
        trace?("desks as Llama sees them:\n" + desks.map { "  - \($0.name): \($0.about)" }.joined(separator: "\n"))
        var t = Date()
        guard let first = await ask(desks) else { return .unavailable }
        trace?("pass 1 (list in order): \(first ?? "none") in \(Int(Date().timeIntervalSince(t) * 1000)) ms")
        t = Date()
        guard let topic = first else { return .noMatch }
        guard let second = await ask(desks.reversed()) else { return .unavailable }
        trace?("pass 2 (list reversed): \(second ?? "none") in \(Int(Date().timeIntervalSince(t) * 1000)) ms; \(second == topic ? "agree, accepted" : "disagree, no match")")
        return second == topic ? .desk(topic) : .noMatch
    }

    /// One plain line: where the person left off on this desk. Reads tab and note titles and, for agents,
    /// the last thing each agent said. Everything stays on this Mac.
    static func receipt(topic: String, items: [DeskItem]) async -> String? {
        var lines: [String] = []
        for item in items.prefix(14) {
            switch item.kind {
            case .tab: lines.append("- browser tab: \(item.title)")
            case .note: lines.append("- note: \(item.title)")
            case .agent:
                var line = "- coding agent \(item.title), \(item.state ?? "running")"
                if let said = Capture.lastAgentMessage(sessionId: item.ref) { line += ", its last message: \"\(said.prefix(260))\"" }
                lines.append(line)
            case .music: lines.append("- music playing: \(item.title) by \(item.detail)")
            case .folder: lines.append("- folder: \(item.title)")
            case .app: lines.append("- app: \(item.title)")
            }
        }
        guard !lines.isEmpty else { return nil }
        let prompt = "A person's desk for \"\(topic)\" had this open:\n\(lines.joined(separator: "\n"))\nIn one plain sentence of at most 14 words, say where they left off, so they can pick it up again. Do not start with \"You\". No quotes. Reply as JSON."
        let schema: [String: Any] = ["type": "object", "properties": ["receipt": ["type": "string"]], "required": ["receipt"]]
        guard var text = (await generate(prompt, schema: schema))?["receipt"] as? String else { return nil }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"."))
        text = text.replacingOccurrences(of: "\u{2014}", with: ",").replacingOccurrences(of: "--", with: ",")
        text = tidy(text)
        guard text.count >= 8, text.count <= 140 else { return nil }
        return text
    }

    /// The panel already says "Left off:", and kcalm is always lowercase. Also applied to receipts saved earlier.
    static func tidy(_ receipt: String) -> String {
        var text = receipt.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Left off on ", "Left off at ", "Left off ", "Left open ", "Left "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        text = text.replacingOccurrences(of: "kcalm", with: "kcalm", options: .caseInsensitive)
        if let first = text.first { text = first.uppercased() + text.dropFirst() }
        return text
    }
}
