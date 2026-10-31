import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

/// Server addresses as they're typed, what's refused, and what reaches ssh and the shell.
struct RemoteServerTests {
    private func parsed(_ text: String) -> RemoteServer? {
        if case .success(let server) = RemoteServer.sftp(from: text) { return server }
        return nil
    }

    @Test func readsTheUsualForms() throws {
        let full = try #require(parsed("sftp://deploy@web-1.example.com:2222/srv/app"))
        #expect(full.host == "web-1.example.com" && full.user == "deploy" && full.port == 2222 && full.path == "/srv/app")
        let short = try #require(parsed("deploy@web-1"))
        #expect(short.host == "web-1" && short.user == "deploy" && short.port == nil && short.path == nil)
        let alias = try #require(parsed("prod"))
        #expect(alias.host == "prod" && alias.user == nil)
        let ipv6 = try #require(parsed("sftp://[fe80::1]:22/"))
        #expect(ipv6.host == "fe80::1" && ipv6.port == 22 && ipv6.path == nil)
        let escaped = try #require(parsed("sftp://me@host/My%20Files"))
        #expect(escaped.path == "/My Files")
    }

    @Test func refusesWhatSSHCouldTakeForAnOption() {
        #expect(parsed("-oProxyCommand=touch /tmp/x") == nil)
        #expect(parsed("host;rm -rf ~") == nil)
        #expect(parsed("me@-p22") == nil)
        #expect(parsed("-l@host") == nil)
        #expect(parsed("sftp://host:99999") == nil)
        #expect(parsed("sftp://host:abc") == nil)
        #expect(parsed("") == nil)
        #expect(parsed("ho st") == nil)
    }

    @Test func theHostComesAfterTheEndOfOptions() throws {
        let server = try #require(parsed("sftp://deploy@web-1:2222/srv"))
        let arguments = server.sshArguments
        let end = try #require(arguments.firstIndex(of: "--"))
        #expect(Array(arguments[end...]) == ["--", "web-1", "sftp"])
        #expect(arguments.contains("ForwardAgent=no") && arguments.contains("ClearAllForwardings=yes"))
        #expect(arguments.contains("-p") && arguments.contains("2222") && arguments.contains("-l") && arguments.contains("deploy"))
    }

    @Test func theTerminalScriptQuotesEverything() throws {
        let server = try #require(parsed("deploy@web-1"))
        let script = server.terminalScript(path: "/srv/my app $(rm -rf ~) `id`")
        // The remote command is one argument for this Mac's shell, with the path single-quoted inside it for the server's.
        #expect(script.contains("exec '/usr/bin/ssh' '-t' '-o' 'ForwardAgent=no' '-o' 'ForwardX11=no' '-o' 'ClearAllForwardings=yes' '-l' 'deploy' '--' 'web-1' "))
        #expect(script.contains("'cd '\\''/srv/my app $(rm -rf ~) `id`'\\'' 2>/dev/null; exec $SHELL -l'"))
        // A path that single quotes can't keep the same in every login shell (a quote, a backslash, a !) isn't gone to.
        for path in ["/srv/it's", "/srv/a\\'; id; #", "/srv/hi!", "/srv/new\nline"] {
            #expect(server.terminalScript(path: path).contains("'web-1' 'exec $SHELL -l'"))
        }
    }

    @Test func s3NeedsItsParts() {
        let base = RemoteServer(id: UUID().uuidString, kind: .s3, name: "b", host: "s3.us-east-1.amazonaws.com",
                                bucket: "my-bucket", region: "us-east-1", accessKeyID: "AKIAIOSFODNN7EXAMPLE")
        #expect(base.validate() == nil)
        var bad = base
        bad.bucket = "My_Bucket"
        #expect(bad.validate() == .bucket)
        bad = base
        bad.region = "US East"
        #expect(bad.validate() == .region)
        bad = base
        bad.host = "-evil"
        #expect(bad.validate() == .host)
        #expect(RemoteServer.isValidBucket("logs.example.com"))
        #expect(!RemoteServer.isValidBucket("a..b"))
        #expect(!RemoteServer.isValidBucket("ab"))
    }

    @Test func addressesNeverCarryASecret() {
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "w", host: "web-1", user: "deploy", port: 2222, path: "/srv")
        #expect(server.address == "sftp://deploy@web-1:2222/srv")
    }
}
