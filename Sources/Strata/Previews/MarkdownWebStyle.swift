import Foundation

/// Document styling follows GitHub's Markdown spacing and component proportions.
/// These colors belong to the document, independently of the surrounding app theme.
nonisolated enum MarkdownWebStyle {
    static let css = #"""
    :root { color-scheme: light dark; --background:#ffffff; --foreground:#1f2328;
      --muted:#59636e; --border:#d1d9e0; --surface:#f6f8fa; --inline:#818b981f;
      --link:#0969da; --red:#cf222e; --blue:#0550ae; --green:#116329; --purple:#8250df; }
    @media(prefers-color-scheme:dark) {
      :root { --background:#0d1117; --foreground:#f0f6fc; --muted:#9198a1; --border:#3d444d;
        --surface:#151b23; --inline:#656c7633; --link:#4493f8; --red:#ff7b72;
        --blue:#79c0ff; --green:#a5d6ff; --purple:#d2a8ff; }
    }
    * { box-sizing:border-box; }
    html, body { margin:0; background:var(--background); color:var(--foreground); }
    .markdown-body { max-width:864px; margin:0 auto; padding:32px; font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
      overflow-wrap:break-word; -webkit-text-size-adjust:100%; }
    @media(max-width:480px) { .markdown-body { padding:16px; } }
    .markdown-body > :first-child { margin-top:0 !important; }
    .markdown-body > :last-child { margin-bottom:0 !important; }
    p, blockquote, ul, ol, pre, .table-scroll, .diagram, .equation { margin-top:0; margin-bottom:16px; }
    h1,h2,h3,h4,h5,h6 { margin-top:24px; margin-bottom:16px; font-weight:600; line-height:1.25; scroll-margin-top:16px; }
    h1 { font-size:2em; } h2 { font-size:1.5em; } h3 { font-size:1.25em; }
    h4 { font-size:1em; } h5 { font-size:.875em; } h6 { font-size:.85em; color:var(--muted); }
    h1,h2 { padding-bottom:.3em; border-bottom:1px solid var(--border); }
    a { color:var(--link); text-decoration:none; } a:hover { text-decoration:underline; }
    strong { font-weight:600; }
    ul,ol { padding-left:2em; } ul ul,ul ol,ol ul,ol ol { margin-top:0; margin-bottom:0; }
    li+li { margin-top:.25em; } li>p { margin-top:16px; } li>p:first-child { margin-top:0; }
    .task-list-item { list-style:none; } .task-list-item>input { margin:0 .2em .25em -1.4em; vertical-align:middle; }
    blockquote { padding:0 1em; color:var(--muted); border-left:.25em solid var(--border); }
    blockquote>:first-child { margin-top:0; } blockquote>:last-child { margin-bottom:0; }
    hr { height:.25em; padding:0; margin:24px 0; background:var(--border); border:0; }
    code,pre { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
    code { padding:.2em .4em; font-size:85%; background:var(--inline); border-radius:6px;
      box-decoration-break:clone; -webkit-box-decoration-break:clone; }
    pre { padding:16px; overflow:auto; font-size:85%; line-height:1.45; background:var(--surface); border-radius:6px;
      word-break:normal; overflow-wrap:normal; }
    pre code { padding:0; font-size:100%; background:transparent; border:0; border-radius:0; white-space:pre; }
    .source { white-space:pre-wrap; }
    .table-scroll { max-width:100%; overflow-x:auto; }
    table { border-spacing:0; border-collapse:collapse; width:max-content; max-width:100%; }
    th,td { padding:6px 13px; border:1px solid var(--border); vertical-align:top; }
    th { font-weight:600; } tr { background:var(--background); } tbody tr:nth-child(odd) { background:var(--surface); }
    img { max-width:100%; height:auto; vertical-align:middle; }
    .diagram { overflow-x:auto; text-align:center; }
    .diagram svg { display:block; max-width:100%; height:auto; margin:0 auto; }
    .equation,[data-math=block] { display:block; overflow-x:auto; text-align:center; padding:8px 0; }
    math { font-size:1.1em; }
    .syntax-comment { color:var(--muted); } .syntax-keyword,.syntax-declaration,.syntax-deleted { color:var(--red); }
    .syntax-string,.syntax-inserted { color:var(--green); } .syntax-number,.syntax-type,.syntax-attribute,.syntax-key { color:var(--blue); }
    .syntax-function,.syntax-tag { color:var(--purple); } .syntax-preprocessor,.syntax-meta { color:var(--muted); }
    """#
}
