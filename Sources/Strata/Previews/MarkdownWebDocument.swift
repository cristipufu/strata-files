import Foundation
import CPreviewText

/// The captured source, guarded local resources and bundled renderers for one Markdown preview.
nonisolated struct MarkdownWebDocument: Sendable {
    let resources: HTMLPreviewDocument
    let script: String
    let wordCount: Int

    @concurrent static func open(_ url: URL) async throws -> MarkdownWebDocument {
        let resources = try await HTMLPreviewDocument.open(url, transform: {
            try MarkdownHTMLRenderer(baseURL: url.deletingLastPathComponent()).render($0)
        })
        let markup = try await resources.read(resources.url)
        let html = String(decoding: markup.data, as: UTF8.self)
        var libraries: [String] = []
        if html.contains("data-diagram>") { libraries.append(try await MermaidRenderer.script()) }
        if html.contains("data-math=") { libraries.append(try await MathRenderer.script()) }
        try Task.checkCancellation()
        let script = libraries.joined(separator: ";\n") + ";\n" + MarkdownWebAssets.script
        let words = try STPreviewTextBuilder.wordCount(in: resources.sourceText).intValue
        return MarkdownWebDocument(resources: resources, script: script, wordCount: words)
    }

    func page() -> PreviewWebPage.Document {
        PreviewWebPage.Document(url: resources.url, read: { try await resources.read($0) },
            limits: .init(bytes: 8 * 1024 * 1024 + HTMLPreviewDocument.assetLimit), trustedScript: script, links: .webMailAndFiles, waitsForLoad: true)
    }
}

/// Runs only in WebKit's isolated client world. Text in the document is data, never JavaScript.
nonisolated enum MarkdownWebAssets {
    static let script = #"""
    (() => {
      const darkMode = matchMedia('(prefers-color-scheme:dark)');
      const diagrams = Array.from(document.querySelectorAll('[data-diagram]')).slice(0, 12)
        .map(element => ({element, source:element.textContent, fallback:element.cloneNode(true)}));
      const equations = Array.from(document.querySelectorAll('[data-math]')).slice(0, 64);
      let revision = 0;
      async function render() {
        const current = ++revision;
        if (diagrams.length && typeof mermaid !== 'undefined') {
          const config = {startOnLoad:false, securityLevel:'strict', maxTextSize:50000, maxEdges:500,
            suppressErrorRendering:true, theme:darkMode.matches ? 'dark' : 'default',
            htmlLabels:false, flowchart:{htmlLabels:false}, fontFamily:'-apple-system, sans-serif'};
          config.secure = [...new Set(['secure', ...Object.keys(config)])];
          mermaid.initialize(config);
          for (let index=0; index<diagrams.length; index++) {
            if (current !== revision) return;
            const {element,source,fallback} = diagrams[index];
            try {
              const result = await mermaid.render('strata-diagram-' + current + '-' + index, source);
              if (current !== revision) return;
              if (result.svg.length > 2000000) throw new Error('Diagram too large');
              const holder = document.createElement('div'); holder.innerHTML = result.svg;
              const svg = holder.querySelector('svg');
              if (!svg) throw new Error('Invalid diagram');
              const box = svg.viewBox.baseVal;
              if (!(box.width > 0 && box.height > 0 && Number.isFinite(box.width+box.height))) throw new Error('Invalid size');
              // No active elements or external references survive even generated SVG.
              svg.querySelectorAll('script,foreignObject,image,iframe,object,embed').forEach(node => node.remove());
              for (const node of [svg,...svg.querySelectorAll('*')]) {
                for (const attribute of Array.from(node.attributes)) {
                  if (/^on/i.test(attribute.name) || /href$/i.test(attribute.name)) node.removeAttribute(attribute.name);
                }
              }
              svg.setAttribute('width', String(box.width)); svg.removeAttribute('height');
              svg.style.maxWidth = '100%'; svg.setAttribute('role','img');
              svg.setAttribute('aria-label',source); element.replaceChildren(svg);
            } catch (_) {
              if (current === revision) element.replaceChildren(...Array.from(fallback.cloneNode(true).childNodes));
            }
          }
        }
      }
      for (const element of equations) {
        if (typeof katex === 'undefined') break;
        const source = element.textContent;
        try {
          const markup = katex.renderToString(source,{output:'mathml',displayMode:element.dataset.math==='block',
            trust:()=>{throw new Error('Unsupported TeX command');},throwOnError:true,
            maxSize:20,maxExpand:1000,strict:'error',macros:Object.create(null)});
          if (markup.length > 500000) throw new Error('Equation too large');
          element.innerHTML = markup;
        } catch (_) { element.textContent = source; }
      }
      globalThis.strataMarkdownReady = render();
      globalThis.strataRenderMarkdown = render;
    })();
    """#
}
