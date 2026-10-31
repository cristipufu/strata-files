import Foundation
import Testing
@testable import StrataPreviews

/// The code previews' highlighting: each rule of the lexer, and what a token does to how the rest of its line reads.
struct SyntaxHighlighterTests {
    /// Each token as its text and kind, for `text` read as the language of a file called `fileName`.
    private func tokens(_ text: String, as fileName: String) throws -> [String] {
        let language = try #require(Languages.detect(fileName: fileName))
        let units = Array(text.utf16)
        return SyntaxHighlighter.tokens(in: text, lexer: language.lexer).map { token in
            String(decoding: units[token.location..<token.location + token.length], as: UTF16.self) + ":\(token.kind)"
        }
    }

    @Test func commentsNestWhereTheLanguageAllowsAndNeedASpaceWhereItSays() throws {
        #expect(try tokens("let a = 1 // note\n/* a /* nested */ b */ x", as: "a.swift")
            == ["let:keyword", "a:declaration", "1:number", "// note:comment", "/* a /* nested */ b */:comment"])
        #expect(try tokens("{- a {- b -} c -} x' = 1 -- end", as: "a.hs") == ["{- a {- b -} c -}:comment", "1:number", "-- end:comment"])
        // A shell `#` inside a word isn't a comment.
        #expect(try tokens("echo a#b # note", as: "a.sh") == ["echo:keyword", "# note:comment"])
    }

    @Test func stringsTakeTheirPrefixesAndEscapes() throws {
        #expect(try tokens(#"x = f"hi {y}" + r'raw' + "a\"b""#, as: "a.py")
            == [#"f"hi {y}":string"#, "r'raw':string", #""a\"b":string"#])
        #expect(try tokens(#"let s = r"raw""#, as: "a.rs") == ["let:keyword", "s:declaration", #"r"raw":string"#])
    }

    @Test func aDeclaringKeywordNamesTheNextIdentifierEvenOnTheNextLine() throws {
        #expect(try tokens("struct Point { let x = 0.5 }", as: "a.swift")
            == ["struct:keyword", "Point:declaration", "let:keyword", "x:declaration", "0.5:number"])
        #expect(try tokens("func\nname()", as: "a.swift") == ["func:keyword", "name:declaration"])
        // Anything else between them ends it.
        #expect(try tokens("func (name)", as: "a.swift") == ["func:keyword"])
    }

    @Test func aLeadingDotStartsANumberOnlyAfterSomethingThatIsntAName() throws {
        #expect(try tokens("let v = .5 + t.5", as: "a.swift") == ["let:keyword", "v:declaration", ".5:number", "5:number"])
    }

    @Test func attributesAndDirectivesFollowTheirPrefixes() throws {
        #expect(try tokens("@MainActor final class A { #if DEBUG }", as: "a.swift")
            == ["@MainActor:attribute", "final:keyword", "class:keyword", "A:declaration", "#if:preprocessor", "DEBUG:type"])
        // In C a directive starts its line, spaces before it allowed; a capital name is a macro.
        #expect(try tokens("#define LIMIT 10\nx = LIMIT; y # z\n  # define X 1", as: "a.c")
            == ["#define:preprocessor", "LIMIT:preprocessor", "10:number", "LIMIT:preprocessor", "# define:preprocessor",
                "1:number"])
    }

    @Test func rustTellsLifetimesFromCharactersAndReadsAttributesAndMacros() throws {
        #expect(try tokens("#[derive(Debug)]\nfn f<'a>(x: &'a str) -> char { println!(\"{}\", 'c'); }", as: "a.rs")
            == ["#[derive(Debug)]:attribute", "fn:keyword", "f:declaration", "'a:attribute", "'a:attribute", "str:type",
                "char:type", "println!:preprocessor", "\"{}\":string"])
        #expect(try tokens("#![allow(dead_code)] x", as: "a.rs") == ["#![allow(dead_code)]:attribute"])
    }

    @Test func shellVariablesTakeTheirBraces() throws {
        #expect(try tokens(#"echo "$HOME" ${PATH} $1 $(pwd)"#, as: "a.sh")
            == ["echo:keyword", #""$HOME":string"#, "${PATH}:attribute", "$1:attribute"])
        // Make reads `$(…)` as one too.
        #expect(try tokens("CC = $(TOOL) ${CFLAGS}", as: "Makefile").contains("$(TOOL):attribute"))
    }

    @Test func rubyReadsSymbolsInstanceAndGlobalVariables() throws {
        #expect(try tokens("def run(x) = @count + $total + :sym + a::Bee", as: "a.rb")
            == ["def:keyword", "run:declaration", "@count:attribute", "$total:attribute", ":sym:number", "Bee:type"])
    }

    @Test func aConfigLinesLeadingNameIsItsKeyAndSectionsStartTheirLine() throws {
        #expect(try tokens("[server]\nhost = \"x\"\nx = y = 1\na = [1, 2]", as: "a.toml")
            == ["[server]:type", "host:key", "\"x\":string", "x:key", "1:number", "a:key", "1:number", "2:number"])
    }
}
