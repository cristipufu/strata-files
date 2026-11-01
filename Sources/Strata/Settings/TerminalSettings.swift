import AppKit
import CoreServices
import SwiftUI
import UniformTypeIdentifiers

struct TerminalSettings: View {
    @State private var selection = Prefs.shared.terminal ?? ""
    @State private var installed: Set<String> = []
    @State private var selectedName: String?
    @State private var choosing = false
    @State private var pendingChoice: URL?
    @State private var invalidChoice = false

    var body: some View {
        Form {
            HStack {
                Picker("Open in Terminal uses", selection: Binding(get: { selection }, set: {
                    pendingChoice = nil
                    selection = $0
                    selectedName = nil
                    Prefs.shared.terminal = $0.isEmpty ? nil : $0
                })) {
                    Text("Automatic").tag("")
                    ForEach(Prefs.shared.terminals.filter { installed.contains($0.bundleID) || $0.bundleID == selection },
                            id: \.bundleID) { terminal in
                        Text(terminal.name).tag(terminal.bundleID)
                    }
                    if !selection.isEmpty, !Prefs.shared.terminals.contains(where: { $0.bundleID == selection }) {
                        Text(verbatim: selectedName ?? selection).tag(selection)
                    }
                }
                Button("Other…") { pendingChoice = nil; choosing = true }
            }
            Text("Automatic picks the first installed of Ghostty, iTerm, Warp and Terminal. ⌃⌘T opens the current folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .modifier(ThemedFormBackground())
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.applicationBundle]) { result in
            switch result {
            case .success(let url): pendingChoice = url
            case .failure: invalidChoice = true
            }
        }
        .alert("This application couldn’t be selected.", isPresented: $invalidChoice) { Button("OK", role: .cancel) {} }
        .task {
            let found = await Prefs.installed(Prefs.shared.terminals.map(\.bundleID))
            guard !Task.isCancelled else { return }
            installed = found
        }
        .task(id: selection) {
            let selected = selection
            let name = await TerminalApplication.installed(selected)?.name
            guard !Task.isCancelled, selection == selected else { return }
            selectedName = name
        }
        .task(id: pendingChoice) {
            guard let url = pendingChoice else { return }
            let choice = await TerminalApplication.choose(url, register: TerminalApplication.register)
            guard !Task.isCancelled, pendingChoice == url else { return }
            guard let choice else { invalidChoice = true; return }
            selectedName = choice.name
            selection = choice.bundleID
            Prefs.shared.terminal = choice.bundleID
        }
    }
}

nonisolated struct TerminalApplication: Sendable {
    let bundleID: String
    let name: String

    static func installed(_ bundleID: String) async -> Self? {
        guard !bundleID.isEmpty, let url = await Prefs.firstInstalled([bundleID]) else { return nil }
        return await read(url)
    }

    @concurrent static func register(_ url: URL) async -> Bool { LSRegisterURL(url as CFURL, true) == noErr }

    @concurrent static func choose(_ url: URL, register: @Sendable (URL) async -> Bool) async -> Self? {
        guard !Task.isCancelled, let choice = await read(url), !Task.isCancelled else { return nil }
        let registered = await register(url)
        return registered && !Task.isCancelled ? choice : nil
    }

    @concurrent static func read(_ url: URL) async -> Self? {
        guard url.isFileURL, url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let names = [bundle.localizedInfoDictionary?["CFBundleDisplayName"], bundle.infoDictionary?["CFBundleDisplayName"],
                     bundle.infoDictionary?["CFBundleName"]]
        let name = names.compactMap { $0 as? String }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? url.deletingPathExtension().lastPathComponent
        return Self(bundleID: id, name: name)
    }
}
