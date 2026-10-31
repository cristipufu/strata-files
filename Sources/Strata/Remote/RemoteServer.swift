import Foundation

/// A server you browse in Strata: an SFTP host (through your Mac's own `ssh`) or an S3 bucket. Saved without secrets:
/// SSH logs in with your keys, agent or a password typed when asked; an S3 secret key lives in your keychain.
package nonisolated struct RemoteServer: Codable, Equatable, Hashable, Sendable, Identifiable {
    package enum Kind: String, Codable, Sendable { case sftp, s3 }

    /// Stable: names the server's folder in Strata's caches and its keychain item.
    package var id: String
    package var kind: Kind
    /// What the sidebar calls it.
    package var name: String
    /// SFTP: a host name, an address or a Host from ~/.ssh/config. S3: the endpoint's host ("s3.eu-west-1.amazonaws.com",
    /// "<account>.r2.cloudflarestorage.com").
    package var host: String
    package var user: String?
    package var port: Int?
    /// SFTP: the folder to start in (nil: where the login starts). S3: unused.
    package var path: String?
    /// S3: the bucket, its region and the access key's ID (the secret is in the keychain).
    package var bucket: String?
    package var region: String?
    package var accessKeyID: String?
    /// S3: addresses the bucket as endpoint/bucket rather than bucket.endpoint (MinIO and most S3-compatible services).
    package var pathStyle: Bool?

    package init(id: String, kind: Kind, name: String, host: String, user: String? = nil, port: Int? = nil,
                 path: String? = nil, bucket: String? = nil, region: String? = nil, accessKeyID: String? = nil,
                 pathStyle: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.path = path
        self.bucket = bucket
        self.region = region
        self.accessKeyID = accessKeyID
        self.pathStyle = pathStyle
    }

    /// "sftp://deploy@web-1:2222/srv/app" or "s3://bucket", for display and recents (never with a secret).
    package var address: String {
        switch kind {
        case .sftp:
            var text = "sftp://"
            if let user, !user.isEmpty { text += user + "@" }
            text += host.contains(":") ? "[\(host)]" : host
            if let port { text += ":\(port)" }
            if let path, !path.isEmpty { text += path.hasPrefix("/") ? path : "/" + path }
            return text
        case .s3:
            return "s3://" + (bucket ?? "") + (host.isEmpty ? "" : " (\(host))")
        }
    }

    // MARK: - Checking what's typed

    package enum Problem: Error, Equatable {
        case host, user, port, path, bucket, region, accessKey

        package var message: String {
            switch self {
            case .host: String(localized: "That isn’t a server name or address.")
            case .user: String(localized: "That user name has characters a login can’t.")
            case .port: String(localized: "The port has to be a number from 1 to 65535.")
            case .path: String(localized: "That folder path has characters a path can’t.")
            case .bucket: String(localized: "That isn’t a bucket name (3–63 lowercase letters, numbers, dots and hyphens).")
            case .region: String(localized: "That isn’t a region (like us-east-1).")
            case .accessKey: String(localized: "That isn’t an access key ID.")
            }
        }
    }

    /// Host names, addresses (IPv6 too) and ~/.ssh/config aliases; never anything ssh could take for an option.
    package static func isValidID(_ id: String) -> Bool {
        UUID(uuidString: id)?.uuidString == id
    }

    package static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("-") else { return false }
        return host.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || ".-_:%".unicodeScalars.contains($0) }
            && host.unicodeScalars.allSatisfy(\.isASCII)
    }

    package static func isValidUser(_ user: String) -> Bool {
        guard !user.isEmpty, user.count <= 128, !user.hasPrefix("-") else { return false }
        return !user.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            || "@:/\\'\"`$;|&<>(){}[]*?!#~".unicodeScalars.contains($0) }
    }

    package static func isValidPath(_ path: String) -> Bool {
        path.count <= 4096 && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Bucket names as S3 allows them (the strict, DNS-safe rules).
    package static func isValidBucket(_ bucket: String) -> Bool {
        guard (3...63).contains(bucket.count), let first = bucket.first, let last = bucket.last,
              first.isLetter || first.isNumber, last.isLetter || last.isNumber, !bucket.contains("..") else { return false }
        return bucket.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-" }
    }

    package static func isValidRegion(_ region: String) -> Bool {
        (1...40).contains(region.count) && region.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    package static func isValidAccessKey(_ key: String) -> Bool {
        (8...128).contains(key.count) && key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
    }

    /// Everything that has to be right before the server is saved or connected to.
    package func validate() -> Problem? {
        guard Self.isValidHost(host) else { return .host }
        if let user, !Self.isValidUser(user) { return .user }
        if let port, !(1...65535).contains(port) { return .port }
        if let path, !Self.isValidPath(path) { return .path }
        if kind == .s3 {
            guard let bucket, Self.isValidBucket(bucket) else { return .bucket }
            guard let region, Self.isValidRegion(region) else { return .region }
            guard let accessKeyID, Self.isValidAccessKey(accessKeyID) else { return .accessKey }
        }
        return nil
    }

    /// An `sftp://user@host:port/path` address, or `user@host` / a config alias as ssh takes it.
    package static func sftp(from text: String) -> Result<RemoteServer, Problem> {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.lowercased().hasPrefix("sftp://") { rest = String(rest.dropFirst(7)) } else if rest.lowercased().hasPrefix("ssh://") { rest = String(rest.dropFirst(6)) }
        var path: String?
        if let slash = rest.firstIndex(of: "/") {
            path = String(rest[slash...]).removingPercentEncoding ?? String(rest[slash...])
            rest = String(rest[..<slash])
        }
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at]).removingPercentEncoding
            rest = String(rest[rest.index(after: at)...])
        }
        var host = rest
        var port: Int?
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            let after = host[host.index(after: close)...]
            if after.hasPrefix(":") { port = Int(after.dropFirst()) ?? -1 }
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if let colon = host.lastIndex(of: ":"), host.filter({ $0 == ":" }).count == 1 {
            port = Int(host[host.index(after: colon)...]) ?? -1
            host = String(host[..<colon])
        }
        if path == "/" { path = nil }
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: host, host: host, user: user?.isEmpty == true ? nil : user,
                                  port: port, path: path)
        if let problem = server.validate() { return .failure(problem) }
        return .success(server)
    }

    /// Whether `other` (the same server, edited) reaches a different place: another host, login, port, bucket or region.
    package func reachesSomewhereElse(than other: RemoteServer) -> Bool {
        host.lowercased() != other.host.lowercased() || user != other.user || port != other.port || bucket != other.bucket
            || region != other.region || (pathStyle ?? false) != (other.pathStyle ?? false)
    }

    // MARK: - SSH

    /// `ssh` running the SFTP subsystem on this server. Your ~/.ssh/config applies (keys, ProxyJump, aliases), but
    /// nothing gets forwarded to the server: no agent, no X11, no ports.
    package var sshArguments: [String] {
        var arguments = [
            "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes", "-o", "RequestTTY=no",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "ConnectTimeout=20",
        ]
        if let port { arguments += ["-p", String(port)] }
        if let user, !user.isEmpty { arguments += ["-l", user] }
        // After "--", the host can't be read as an option, whatever it says (it's checked too).
        arguments += ["-s", "--", host, "sftp"]
        return arguments
    }

    /// Open in Terminal: a `.command` script for `/bin/sh` that deletes itself and runs ssh with the same login as
    /// browsing. Every argument is quoted for this Mac's shell. On the server, `path` becomes a `cd` before the login
    /// shell, single-quoted, which reads the same in sh, bash, zsh, fish and csh only without `'`, `\`, `!` or
    /// control characters: a folder with any of those opens at the login's folder instead.
    package func terminalScript(path: String) -> String {
        var arguments = ["/usr/bin/ssh", "-t", "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes"]
        if let port { arguments += ["-p", String(port)] }
        if let user, !user.isEmpty { arguments += ["-l", user] }
        let quotable = !path.unicodeScalars.contains { "'\\!".unicodeScalars.contains($0) || CharacterSet.controlCharacters.contains($0) }
        arguments += ["--", host, quotable ? "cd '\(path)' 2>/dev/null; exec $SHELL -l" : "exec $SHELL -l"]
        return """
        #!/bin/sh
        # Written by Strata to open a shell on a server. Deletes itself; safe to remove.
        rm -f -- "$0"
        exec \(arguments.map(ShellQuote.quote).joined(separator: " "))

        """
    }
}
