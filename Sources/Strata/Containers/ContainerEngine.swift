import CryptoKit
import Foundation

/// A container engine Strata can read: Docker Desktop, OrbStack, Colima, Podman, Rancher Desktop, Lima or Docker Engine,
/// reached through the Docker API on its socket.
package nonisolated struct ContainerEngine: Sendable, Equatable {
    /// The API socket's path.
    package let socket: String
    /// What to call it ("Docker Desktop", "OrbStack"…).
    package let name: String
    /// The API version requests are made with ("1.41"), the engine's own.
    package let apiVersion: String

    /// `/v1.41/containers/json`: a path in this engine's API.
    package func path(_ endpoint: String) -> String { "/v\(apiVersion)\(endpoint)" }
}

/// Finding the engine to show: the one `docker` itself would use, else the first one running.
package nonisolated enum EngineDiscovery {
    /// Sockets to try, in order: `DOCKER_HOST`, the current docker context, then where each engine keeps its socket.
    /// Only Unix sockets: an engine on another machine isn't Strata's to browse.
    package static func candidates(environment: [String: String] = ProcessInfo.processInfo.environment,
                           home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           temporary: URL = FileManager.default.temporaryDirectory) -> [String] {
        var paths: [String] = []
        if let host = environment["DOCKER_HOST"], let path = socketPath(fromHost: host) { paths.append(path) }
        let config = environment["DOCKER_CONFIG"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appending(path: ".docker", directoryHint: .isDirectory)
        if let context = environment["DOCKER_CONTEXT"] ?? currentContext(config: config), context != "default",
           let host = contextHost(name: context, config: config), let path = socketPath(fromHost: host) {
            paths.append(path)
        }
        let known = [
            ".orbstack/run/docker.sock",
            ".docker/run/docker.sock",
            ".colima/default/docker.sock",
            ".colima/docker.sock",
            ".rd/docker.sock",
            ".local/share/containers/podman/machine/podman.sock",
            ".local/share/containers/podman/machine/applehv/podman.sock",
            ".local/share/containers/podman/machine/qemu/podman.sock",
            ".lima/docker/sock/docker.sock",
            ".lima/default/sock/docker.sock",
        ].map { home.appending(path: $0).path }
        paths += known
        paths.append("/var/run/docker.sock")
        // Podman's machine API socket lives in the per-user temporary folder.
        let podman = temporary.appending(path: "podman", directoryHint: .isDirectory)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: podman.path) {
            paths += names.filter { $0.hasSuffix("-api.sock") }.sorted().map { podman.appending(path: $0).path }
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// `unix:///path/to.sock` → `/path/to.sock`; anything else (tcp, ssh, npipe) → nil.
    package static func socketPath(fromHost host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("unix://") else { return nil }
        let path = String(trimmed.dropFirst("unix://".count))
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return path
    }

    /// The context `docker` uses, from its config file.
    package static func currentContext(config: URL) -> String? {
        guard let object = readJSON(config.appending(path: "config.json")) as? [String: Any] else { return nil }
        return (object["currentContext"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A context's Docker endpoint, from `contexts/meta/<sha256 of its name>/meta.json`.
    package static func contextHost(name: String, config: URL) -> String? {
        let digest = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        let meta = config.appending(path: "contexts/meta/\(digest)/meta.json")
        guard let object = readJSON(meta) as? [String: Any], let endpoints = object["Endpoints"] as? [String: Any],
              let docker = endpoints["docker"] as? [String: Any] else { return nil }
        return docker["Host"] as? String
    }

    /// Small JSON files only (a config file isn't megabytes).
    private static func readJSON(_ url: URL) -> Any? {
        guard let (data, truncated) = try? TextFile.readPrefix(url, limit: 1 << 20), !truncated else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// A socket you (or the system) own. Someone else's socket isn't trusted to be your engine.
    package static func isUsableSocket(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return false }
        return info.st_uid == getuid() || info.st_uid == 0
    }

    /// The first candidate that answers, with its name and API version. Blocking.
    package static func discover(candidates: [String] = candidates()) -> ContainerEngine? {
        for socket in candidates where isUsableSocket(socket) {
            if let engine = probe(socket) { return engine }
        }
        return nil
    }

    /// Asks `socket` who it is; nil when nothing answers like a Docker API.
    package static func probe(_ socket: String) -> ContainerEngine? {
        guard let ping = try? UnixHTTP.send("GET", "/_ping", to: socket, idle: 2, total: 4, limit: 1024), ping.status == 200,
              let version = try? UnixHTTP.send("GET", "/version", to: socket, idle: 3, total: 5, limit: 1 << 20), version.status == 200,
              let object = try? JSONSerialization.jsonObject(with: version.body) as? [String: Any],
              let api = object["ApiVersion"] as? String, isAPIVersion(api) else { return nil }
        var name = engineName(socket: socket, operatingSystem: nil)
        if let info = try? UnixHTTP.send("GET", "/v\(api)/info", to: socket, idle: 3, total: 5, limit: 4 << 20), info.status == 200,
           let object = try? JSONSerialization.jsonObject(with: info.body) as? [String: Any] {
            name = engineName(socket: socket, operatingSystem: object["OperatingSystem"] as? String)
        }
        return ContainerEngine(socket: socket, name: name, apiVersion: api)
    }

    package static func isAPIVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    /// The engine's name, from what it says it runs on, else from where its socket is.
    package static func engineName(socket: String, operatingSystem: String?) -> String {
        if let system = operatingSystem {
            if system.localizedCaseInsensitiveContains("Docker Desktop") { return "Docker Desktop" }
            if system.localizedCaseInsensitiveContains("OrbStack") { return "OrbStack" }
        }
        let path = socket.lowercased()
        if path.contains("/.orbstack/") { return "OrbStack" }
        if path.contains("/.colima/") { return "Colima" }
        if path.contains("/.rd/") { return "Rancher Desktop" }
        if path.contains("podman") { return "Podman" }
        if path.contains("/.lima/") { return "Lima" }
        if path.contains("/.docker/run/") { return "Docker Desktop" }
        return "Docker"
    }
}

/// A container, as the list shows it.
package nonisolated struct ContainerInfo: Sendable, Equatable, Identifiable {
    package enum State: String, Sendable {
        case running, paused, restarting, created, exited, dead, removing, unknown
    }

    /// 64 hex characters.
    package let id: String
    package let name: String
    package let image: String
    package let state: State
    /// The engine's own summary ("Up 3 hours", "Exited (0) 2 days ago").
    package let status: String
    package let created: Date?
    package let mounts: [ContainerMount]
    package let ports: [ContainerPort]
    /// Compose's labels; no other labels are kept.
    package let compose: ComposeLabels?

    package var isRunning: Bool { state == .running }
    /// The first 12 characters, as `docker ps` shows it.
    package var shortID: String { String(id.prefix(12)) }
}

package nonisolated struct ContainerMount: Sendable, Equatable {
    package enum Kind: String, Sendable {
        case bind, volume, tmpfs, other
    }

    package let kind: Kind
    /// A volume's name.
    package let name: String?
    /// Where it comes from: a folder on this Mac (bind) or inside the engine (volume).
    package let source: String
    /// Where it appears inside the container.
    package let destination: String
    package let isWritable: Bool
}

package nonisolated struct ContainerPort: Sendable, Equatable, Hashable {
    package let containerPort: Int
    package let hostPort: Int?
    package let hostIP: String?
    /// "tcp" or "udp".
    package let proto: String
}

package nonisolated struct ComposeLabels: Sendable, Equatable {
    package let project: String
    package let service: String
    /// The folder `docker compose` ran in.
    package let workingDirectory: String?
}

/// What came back from the engine, for messages.
package nonisolated enum ContainerAPIError: Error, Equatable {
    case notRunning
    case notFound
    /// No shell or tools in the container to list a folder with.
    case noShell
    case status(Int, String)
    case transport(UnixHTTP.Failure)
    case malformed
}

/// What you can do to a container (each a single POST to the engine).
package nonisolated enum ContainerAction: String, Sendable, CaseIterable {
    case start, stop, restart, pause, unpause

    /// The engine's endpoint, after `/containers/<id>/`. Stopping waits 10 seconds before it forces.
    package var endpoint: String {
        switch self {
        case .stop, .restart: "\(rawValue)?t=10"
        default: rawValue
        }
    }

    /// Whether it makes sense for a container in `state`.
    package func applies(to state: ContainerInfo.State) -> Bool {
        switch self {
        case .start: [.created, .exited, .dead].contains(state)
        case .stop: [.running, .paused, .restarting].contains(state)
        case .restart: [.running, .paused, .exited, .created].contains(state)
        case .pause: state == .running
        case .unpause: state == .paused
        }
    }
}

/// The engine's API: reading, Strata's own listing command in a container (`exec`), and the actions you choose.
package nonisolated enum ContainerAPI {
    /// Starts, stops, restarts, pauses or resumes a container. Already in that state is fine.
    package static func perform(_ action: ContainerAction, _ engine: ContainerEngine, id: String) throws {
        guard isContainerID(id) else { throw ContainerAPIError.notFound }
        let response: UnixHTTP.Response
        do {
            // Stopping can take the 10 seconds the container gets to quit, and then some.
            response = try UnixHTTP.send("POST", engine.path("/containers/\(id)/\(action.endpoint)"), to: engine.socket,
                                         idle: 40, total: 60, limit: 1 << 20)
        } catch let error as UnixHTTP.Failure {
            throw ContainerAPIError.transport(error)
        }
        guard response.status == 204 || response.status == 304 || response.status == 200 else { throw failure(response, conflicts: true) }
    }

    /// Every container, running or not (at most 1000).
    package static func containers(_ engine: ContainerEngine) throws -> [ContainerInfo] {
        let response = try send(engine, "GET", "/containers/json?all=1", limit: 16 << 20)
        guard response.status == 200 else { throw failure(response) }
        return try parseContainers(response.body)
    }

    package static func parseContainers(_ data: Data) throws -> [ContainerInfo] {
        guard let list = try? JSONDecoder().decode([RawContainer].self, from: data) else { throw ContainerAPIError.malformed }
        return list.prefix(1000).compactMap(\.info)
    }

    /// Waits for container events and calls `changed` for each, until the engine closes the stream or `shouldStop`.
    package static func watchEvents(_ engine: ContainerEngine, shouldStop: @escaping () -> Bool, changed: () -> Void) throws {
        // Lifecycle only: Strata's own listings (exec_*) and reads (copy) would otherwise each set off a refresh.
        let filters = queryEscaped(#"{"type":["container"],"event":["create","destroy","die","kill","oom","pause","rename","restart","start","stop","unpause","update"]}"#)
        var pending = Data()
        let head = try UnixHTTP.stream("GET", engine.path("/events?filters=\(filters)"), to: engine.socket,
                                       idle: 365 * 24 * 3600, shouldStop: shouldStop) { chunk in
            pending.append(chunk)
            // One JSON object per line; the content doesn't matter, only that something happened.
            while let newline = pending.firstIndex(of: 0x0A) {
                pending.removeSubrange(pending.startIndex...newline)
                changed()
            }
            if pending.count > 1 << 20 { pending.removeAll() }
            return true
        }
        guard head.status == 200 else { throw ContainerAPIError.status(head.status, "") }
    }

    package struct ExecResult: Sendable {
        package let exitCode: Int?
        package let output: Data
        package let errors: Data
    }

    /// Runs `command` in a running container, as the container's own user, and collects what it prints (output up to
    /// `limit` bytes). Tools are found on a fixed system PATH, never one the container's processes could have changed.
    package static func exec(_ engine: ContainerEngine, id: String, command: [String], limit: Int = 32 << 20,
                     idle: TimeInterval = 20, total: TimeInterval = 60, shouldStop: @escaping () -> Bool = { false }) throws -> ExecResult {
        guard isContainerID(id) else { throw ContainerAPIError.notFound }
        let request: [String: Any] = [
            "AttachStdin": false, "AttachStdout": true, "AttachStderr": true, "Tty": false,
            "Cmd": command, "Env": ["PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL=C"],
        ]
        let body = try JSONSerialization.data(withJSONObject: request)
        let created = try send(engine, "POST", "/containers/\(id)/exec", json: body, limit: 1 << 20)
        guard created.status == 201 else { throw failure(created) }
        guard let object = try? JSONSerialization.jsonObject(with: created.body) as? [String: Any],
              let execID = object["Id"] as? String, isContainerID(execID) else { throw ContainerAPIError.malformed }
        var demux = StreamDemux(outputLimit: limit, errorLimit: 64 * 1024)
        let start = try JSONSerialization.data(withJSONObject: ["Detach": false, "Tty": false])
        var started = false
        var refusal = Data()
        let head: UnixHTTP.Head
        do {
            head = try UnixHTTP.stream("POST", engine.path("/exec/\(execID)/start"), to: engine.socket, json: start,
                                       idle: idle, total: total, shouldStop: shouldStop, onHead: { started = $0.status == 200 }) { chunk in
                guard started else {
                    refusal.append(chunk.prefix(max(0, 4096 - refusal.count)))
                    return refusal.count < 4096
                }
                return try demux.feed(chunk)
            }
        } catch let error as UnixHTTP.Failure {
            throw ContainerAPIError.transport(error)
        }
        guard head.status == 200 else { throw failure(UnixHTTP.Response(head: head, body: refusal)) }
        var exitCode: Int?
        if let inspected = try? send(engine, "GET", "/exec/\(execID)/json", limit: 1 << 20), inspected.status == 200,
           let object = try? JSONSerialization.jsonObject(with: inspected.body) as? [String: Any] {
            exitCode = object["ExitCode"] as? Int
        }
        return ExecResult(exitCode: exitCode, output: demux.output, errors: demux.errors)
    }

    /// Streams a path in the container as a tar archive (a folder with everything in it, or one file); works on stopped
    /// containers too.
    package static func archive(_ engine: ContainerEngine, id: String, path: String, idle: TimeInterval = 30, total: TimeInterval? = nil,
                        shouldStop: @escaping () -> Bool = { false }, receive: (Data) throws -> Bool) throws {
        guard isContainerID(id) else { throw ContainerAPIError.notFound }
        var errorBody = Data()
        var isArchive = false
        let head: UnixHTTP.Head
        do {
            head = try UnixHTTP.stream("GET", engine.path("/containers/\(id)/archive?path=\(queryEscaped(path))"), to: engine.socket,
                                       idle: idle, total: total, shouldStop: shouldStop, onHead: { isArchive = $0.status == 200 }) { chunk in
                // Only a 200 is an archive; anything else is a short error message.
                guard isArchive else {
                    errorBody.append(chunk.prefix(max(0, 4096 - errorBody.count)))
                    return errorBody.count < 4096
                }
                return try receive(chunk)
            }
        } catch let error as UnixHTTP.Failure {
            throw ContainerAPIError.transport(error)
        }
        guard head.status == 200 else { throw failure(UnixHTTP.Response(head: head, body: errorBody)) }
    }

    /// Docker's IDs: 64 lowercase hex characters. Anything else never goes into a request path.
    package static func isContainerID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    private static func send(_ engine: ContainerEngine, _ method: String, _ endpoint: String, json: Data? = nil,
                             limit: Int) throws -> UnixHTTP.Response {
        do {
            return try UnixHTTP.send(method, engine.path(endpoint), to: engine.socket, json: json, idle: 10, limit: limit)
        } catch let error as UnixHTTP.Failure {
            throw ContainerAPIError.transport(error)
        }
    }

    private static func failure(_ response: UnixHTTP.Response, conflicts: Bool = false) -> ContainerAPIError {
        let message = (try? JSONSerialization.jsonObject(with: response.body.prefix(4096)) as? [String: Any])?["message"] as? String
        switch response.status {
        case 404: return .notFound
        // For an action, a conflict says why (already paused, being removed…).
        case 409 where !conflicts: return .notRunning
        default: return .status(response.status, ContainerText.clean(message ?? "", limit: 300))
        }
    }

    private struct RawContainer: Decodable {
        let Id: String
        let Names: [String]?
        let Image: String?
        let State: String?
        let Status: String?
        let Created: Double?
        let Labels: [String: String]?
        let Mounts: [RawMount]?
        let Ports: [RawPort]?

        var info: ContainerInfo? {
            guard ContainerAPI.isContainerID(Id) else { return nil }
            let rawName = Names?.first.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? String(Id.prefix(12))
            let labels = Labels ?? [:]
            let compose = labels["com.docker.compose.project"].map { project in
                ComposeLabels(project: ContainerText.clean(project, limit: 200),
                              service: ContainerText.clean(labels["com.docker.compose.service"] ?? "", limit: 200),
                              workingDirectory: labels["com.docker.compose.project.working_dir"]
                                  .map { ContainerText.clean($0, limit: 4096) }.flatMap { $0.hasPrefix("/") ? $0 : nil })
            }
            return ContainerInfo(
                id: Id, name: ContainerText.clean(rawName, limit: 200), image: ContainerText.clean(Image ?? "", limit: 300),
                state: ContainerInfo.State(rawValue: (State ?? "").lowercased()) ?? .unknown,
                status: ContainerText.clean(Status ?? "", limit: 120),
                created: Created.map { Date(timeIntervalSince1970: $0) },
                mounts: (Mounts ?? []).prefix(200).compactMap(\.mount),
                ports: Array(Set((Ports ?? []).prefix(500).compactMap(\.port))).sorted { ($0.containerPort, $0.proto) < ($1.containerPort, $1.proto) },
                compose: compose)
        }
    }

    private struct RawMount: Decodable {
        let `Type`: String?
        let Name: String?
        let Source: String?
        let Destination: String?
        let RW: Bool?

        var mount: ContainerMount? {
            let destination = ContainerText.clean(Destination ?? "", limit: 4096)
            guard destination.hasPrefix("/") else { return nil }
            return ContainerMount(kind: ContainerMount.Kind(rawValue: (self.Type ?? "").lowercased()) ?? .other,
                                  name: Name.map { ContainerText.clean($0, limit: 300) },
                                  source: ContainerText.clean(Source ?? "", limit: 4096), destination: destination, isWritable: RW ?? true)
        }
    }

    private struct RawPort: Decodable {
        let IP: String?
        let PrivatePort: Int?
        let PublicPort: Int?
        let `Type`: String?

        /// One odd entry leaves the port out, not the container.
        var port: ContainerPort? {
            guard let PrivatePort, (0...65535).contains(PrivatePort) else { return nil }
            return ContainerPort(containerPort: PrivatePort, hostPort: PublicPort.flatMap { (0...65535).contains($0) ? $0 : nil },
                                 hostIP: IP.map { ContainerText.clean($0, limit: 64) }, proto: ContainerText.clean((self.Type ?? "tcp").lowercased(), limit: 8))
        }
    }
}

/// Splits Docker's multiplexed exec stream (8-byte frame headers: stream, 0, 0, 0, size) into output and errors.
package nonisolated struct StreamDemux {
    package private(set) var output = Data()
    package private(set) var errors = Data()
    private var pending = Data()
    private let outputLimit: Int
    private let errorLimit: Int

    package init(outputLimit: Int, errorLimit: Int) {
        self.outputLimit = outputLimit
        self.errorLimit = errorLimit
    }

    /// Adds bytes from the stream; throws when the output passes its limit.
    package mutating func feed(_ data: Data) throws -> Bool {
        pending.append(data)
        while pending.count >= 8 {
            let header = [UInt8](pending.prefix(8))
            let size = Int(header[4]) << 24 | Int(header[5]) << 16 | Int(header[6]) << 8 | Int(header[7])
            let frameLimit = header[0] == 1 ? outputLimit - output.count : max(outputLimit, errorLimit, 1 << 20)
            guard size >= 0, size <= frameLimit else { throw UnixHTTP.Failure.tooLarge }
            guard pending.count >= 8 + size else { break }
            let payload = pending.subdata(in: pending.startIndex + 8 ..< pending.startIndex + 8 + size)
            pending.removeSubrange(pending.startIndex ..< pending.startIndex + 8 + size)
            switch header[0] {
            case 1:
                guard output.count + payload.count <= outputLimit else { throw UnixHTTP.Failure.tooLarge }
                output.append(payload)
            case 2:
                if errors.count < errorLimit { errors.append(payload.prefix(errorLimit - errors.count)) }
            default:
                break
            }
        }
        return true
    }
}

/// Text from the engine, made safe to show: no control characters, and not endless.
package nonisolated enum ContainerText {
    package static func clean(_ text: String, limit: Int) -> String {
        let scalars = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count > limit ? String(cleaned.prefix(limit)) + "…" : cleaned
    }
}
