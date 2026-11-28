import AppKit
import SwiftUI

// MARK: - Release notes renderer

/// A GitHub release body (Markdown) rendered natively: headings, nested bullets and paragraphs,
/// with inline bold, code and links. The install section and the checksum line are left out,
/// since they only matter for a manual download.
struct ReleaseNotesView: View {
    let markdown: String
    var compact = false

    enum Block: Hashable {
        case heading(String)
        case bullet(level: Int, text: String)
        case paragraph(String)
        case code(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            ForEach(Array(Self.blocks(from: markdown).enumerated()), id: \.offset) { index, block in
                row(block, isFirst: index == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func row(_ block: Block, isFirst: Bool) -> some View {
        switch block {
        case .heading(let text):
            Text(Self.inline(text))
                .font(compact ? .callout.weight(.semibold) : .headline)
                .padding(.top, isFirst ? 0 : (compact ? 4 : 8))
        case .bullet(let level, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(level == 0 ? "•" : "◦").foregroundStyle(.secondary)
                Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
            }
            .font(compact ? .callout : .body)
            .padding(.leading, CGFloat(level) * 16)
        case .paragraph(let text):
            Text(Self.inline(text))
                .font(compact ? .callout : .body)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let text):
            Text(text).font(.system(compact ? .caption : .callout, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    static func blocks(from markdown: String) -> [Block] {
        var blocks: [Block] = []
        var inFence = false
        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); continue }
            if inFence {
                if !trimmed.isEmpty { blocks.append(.code(trimmed)) }
                continue
            }
            if trimmed.isEmpty { continue }
            // The checksum line is for manual downloads only.
            if trimmed.range(of: #"(?i)sha-?256"#, options: .regularExpression) != nil { continue }
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                // "## Install" and everything after it is download instructions.
                if title.lowercased().hasPrefix("install") { break }
                if !title.isEmpty { blocks.append(.heading(title)) }
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                let indent = rawLine.prefix { $0 == " " || $0 == "\t" }
                let width = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                let text = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                blocks.append(.bullet(level: min(width / 2, 3), text: text))
                continue
            }
            if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) { continue } // horizontal rule
            blocks.append(.paragraph(trimmed))
        }
        return blocks
    }
}

// MARK: - What's New window

@MainActor
final class WhatsNewModel: ObservableObject {
    enum Phase: Equatable { case loading, loaded(String), failed }

    let version: String
    @Published private(set) var phase: Phase = .loading

    init(version: String) {
        self.version = version
    }

    var releaseURL: URL {
        URL(string: "https://github.com/\(Updater.repo)/releases/tag/v\(version)")
            ?? URL(string: "https://github.com/\(Updater.repo)/releases")!
    }

    func load() {
        phase = .loading
        let version = version, repo = Updater.repo
        Task {
            let body = await Self.fetchNotes(for: version, repo: repo)
            if let body, !ReleaseNotesView.blocks(from: body).isEmpty {
                self.phase = .loaded(body)
            } else {
                self.phase = .failed
            }
        }
    }

    /// The release body for `version`, trying tag "v<version>" then "<version>".
    nonisolated static func fetchNotes(for version: String, repo: String) async -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard !version.isEmpty, version.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        for tag in ["v\(version)", version] {
            guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/tags/\(tag)") else { continue }
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Notch-Updater", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = json["body"] as? String else { continue }
            return body
        }
        return nil
    }
}

struct WhatsNewView: View {
    @ObservedObject var model: WhatsNewModel
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable().frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    Text("What's New in Notch \(model.version)")
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    content
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                Spacer()
                Button("Continue", action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(16)
        }
        .frame(minWidth: 380, minHeight: 300)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().controlSize(.small).padding(.top, 24)
        case .loaded(let notes):
            ReleaseNotesView(markdown: notes)
        case .failed:
            VStack(spacing: 10) {
                Text("Notch was updated to \(model.version).")
                    .foregroundStyle(.secondary)
                Button("View release notes on GitHub") { NSWorkspace.shared.open(model.releaseURL) }
                    .buttonStyle(.link)
            }
            .padding(.top, 8)
        }
    }
}

/// Shows the notes for the installed version: once after an update, and from the menu or Settings.
@MainActor
final class WhatsNewController: NSObject, NSWindowDelegate {
    static let shared = WhatsNewController()
    static let lastSeenKey = "whatsNewLastSeenVersion"

    private var window: NSWindow?
    private var model: WhatsNewModel?

    private var installedVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Called at launch. Fresh install (welcome still pending, so `suppress`): remember the version
    /// silently. Version changed: show once. No stored version on a set-up copy means it was updated
    /// from a release before What's New existed, which is an update too.
    func showIfUpdated(suppress: Bool = false) {
        guard let current = installedVersion else { return }
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: Self.lastSeenKey)
        defaults.set(current, forKey: Self.lastSeenKey)
        guard stored != current, !suppress else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.show() }
    }

    func show() {
        let version = installedVersion ?? Updater.shared.currentVersion
        if let window, let model, model.version == version, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = WhatsNewModel(version: version)
        self.model = model
        let host = NSHostingController(rootView: WhatsNewView(model: model) { [weak self] in self?.window?.close() })
        host.sizingOptions = []
        let w = window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.contentViewController = host
        w.title = "What's New"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(NSSize(width: 460, height: 520))
        w.contentMinSize = NSSize(width: 460, height: 320)
        w.contentMaxSize = NSSize(width: 460, height: 2000)
        w.center()
        window = w
        model.load()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model = nil
    }
}
