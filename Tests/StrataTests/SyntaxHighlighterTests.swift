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

    @Test func cssReadsSelectorsPropertiesAndValues() throws {
        #expect(try tokens(".card > #main:hover { color: #fff !important; margin: -2px 1.5em; --gap: calc(100% - 4px); }", as: "a.css")
            == [".card:type", "#main:type", ":hover:keyword", "color:key", "#fff:number", "!important:keyword", "margin:key",
                "-2px:number", "1.5em:number", "--gap:attribute", "calc:function", "100%:number", "4px:number"])
        #expect(try tokens("@media screen { a { content: 'x\\'y'; } } /* note */", as: "a.css")
            == ["@media:keyword", "screen:tag", "a:tag", "content:key", "'x\\'y':string", "/* note */:comment"])
        // Sass and Less variables, and line comments outside parentheses only.
        #expect(try tokens("$base: 10px; // line\n.x { width: $base * 2; }", as: "a.scss")
            == ["$base:attribute", "10px:number", "// line:comment", ".x:type", "width:key", "$base:attribute", "2:number"])
    }

    @Test func markupReadsTagsAttributesReferencesAndEmbeddedLanguages() throws {
        #expect(try tokens("<!DOCTYPE html><!-- c --><div class=\"a\" data-x='b' hidden><br/>&amp; &nope x &#38;</div>", as: "a.html")
            == ["<!DOCTYPE html>:preprocessor", "<!-- c -->:comment", "<div:tag", "class:attribute", "\"a\":string",
                "data-x:attribute", "'b':string", "hidden:attribute", ">:tag", "<br:tag", "/>:tag", "&amp;:number",
                "&#38;:number", "</div:tag", ">:tag"])
        #expect(try tokens("<?xml v?><![CDATA[ raw ]]>", as: "a.xml") == ["<?xml v?>:preprocessor", "<![CDATA[ raw ]]>:string"])
        // A style or script body is read as CSS or JavaScript, up to its closing tag in any case.
        #expect(try tokens("<style>p { color: red }</style><SCRIPT>let a = 1</script>", as: "a.html")
            == ["<style:tag", ">:tag", "p:tag", "color:key", "</style:tag", ">:tag", "<SCRIPT:tag", ">:tag", "let:keyword",
                "a:declaration", "1:number", "</script:tag", ">:tag"])
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
