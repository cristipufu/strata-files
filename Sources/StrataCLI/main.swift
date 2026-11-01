import AppKit
import StrataSupport

// strata — open folders and searches in Strata from a terminal.
//
//   strata                 open the current folder
//   strata <path>…         open folders, or reveal files
//   strata -s <query>      search everywhere (same syntax as the search field)
//   strata -s <query> -i <folder>   search inside a folder
//   strata -w <name>       open a saved workspace

// Started by ssh as SSH_ASKPASS while Strata connects to a server: a dialog, not the command line.
let environment = ProcessInfo.processInfo.environment
if environment["STRATA_ASKPASS"] == "1" {
    MainActor.assumeIsolated {
        runAskpass(prompt: CommandLine.arguments.dropFirst().joined(separator: " "), environment: environment)
    }
}

let usage = """
usage: strata [path …]
       strata -s <query> [-i <folder>]
       strata -w <workspace>

  path             folders open in a window; files are shown selected in their folder
  -s, --search     search the index (ext:pdf, kind:image, size:>10mb, modified:<7d, in:~/Documents …)
  -i, --in         limit the search to a folder
  -w, --workspace  open a saved workspace (Window ▸ Workspaces), by name
"""

let bundleID = "dev.strata.app"
var arguments = Array(CommandLine.arguments.dropFirst())
var query: String?
var scope: String?
var workspace: String?
var paths: [String] = []

func writeError(_ message: String) {
    _ = fcntl(STDERR_FILENO, F_SETNOSIGPIPE, 1)
    try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
}

while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "-h", "--help":
        print(usage)
        exit(0)
    case "-s", "--search":
        guard !arguments.isEmpty else { writeError(usage); exit(2) }
        query = arguments.removeFirst()
    case "-w", "--workspace":
        guard !arguments.isEmpty else { writeError(usage); exit(2) }
        workspace = arguments.removeFirst()
    case "-i", "--in":
        guard !arguments.isEmpty else { writeError(usage); exit(2) }
        scope = arguments.removeFirst()
    case "--":
        paths.append(contentsOf: arguments)
        arguments.removeAll()
    default:
        paths.append(argument)
    }
}

// A workspace opens on its own: it doesn't mix with a search or paths.
if (workspace != nil && (query != nil || scope != nil || !paths.isEmpty))
    || (scope != nil && query == nil)
    || (query != nil && !paths.isEmpty) {
    writeError(usage)
    exit(2)
}

let currentDirectory = FileManager.default.currentDirectoryPath
let cwd = URL(fileURLWithPath: currentDirectory.isEmpty ? "/" : currentDirectory, isDirectory: true)
func absolute(_ path: String) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    guard !expanded.isEmpty else {
        writeError("strata: : no such file or directory\n")
        exit(1)
    }
    return TypedPath.location(of: URL(fileURLWithPath: expanded, relativeTo: cwd))
}

guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
    writeError("strata: Strata.app isn't installed\n")
    exit(1)
}

var targets: [URL]
if let workspace {
    var components = URLComponents()
    components.scheme = "strata"
    components.host = "workspace"
    components.queryItems = [URLQueryItem(name: "name", value: workspace)]
    guard let url = components.url else { writeError(usage); exit(2) }
    targets = [url]
} else if let query {
    var components = URLComponents()
    components.scheme = "strata"
    components.host = "search"
    components.queryItems = [URLQueryItem(name: "q", value: query)] + (scope.map { [URLQueryItem(name: "in", value: absolute($0).path)] } ?? [])
    guard let url = components.url else { writeError(usage); exit(2) }
    targets = [url]
} else {
    targets = (paths.isEmpty ? ["."] : paths).map(absolute)
    for url in targets where !FileManager.default.fileExists(atPath: url.path) {
        writeError("strata: \(url.path): no such file or directory\n")
        exit(1)
    }
}

let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = true
NSWorkspace.shared.open(targets, withApplicationAt: app, configuration: configuration) { _, error in
    if let error {
        writeError("strata: \(error.localizedDescription)\n")
        exit(1)
    }
    exit(0)
}
dispatchMain()
