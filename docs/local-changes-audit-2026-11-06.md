# Local changes audit — 6 November 2026

## Scope and outcome

Reviewed the nine local commits after `4066b70`, through `a212bae`: 3MF previews, offline Markdown equations,
ODS workbooks and the shared XLSX reader, browser measurements, Icons/Gallery results, per-folder view choices,
settings search, cached tag paths and bounded native row animations. The review also covers the correction below.

One functional regression was reproduced and fixed. No additional security vulnerability, crash or unhandled native
exception has been confirmed in these changes. This is a source and regression-test audit, not a guarantee that every
possible input or system-framework failure has been exercised.

## Fixed finding

**Global View Options reset a folder's or results' icon size — medium severity, functional regression.**

Introduced by `66bccff`. Changing an unrelated option such as “Show item info” dispatched `viewOptionsChanged`.
Its choice of icon size depended on whether the folder was fully loaded and eligible for saving. During a read, and
in results, that selected the global default instead of the saved or current size. The reset was visible immediately;
a pending folder choice could repair it only when its read completed.

Fixed in `9837e9f`. Icon-size resolution now respects the transient results size, a pending folder presentation and
the current folder's saved settings before falling back to global defaults. The policy reuses the existing check for
local folders; archive/server copies remain outside remembered local settings.

The new tests exercise a held directory read with a saved size, a size chosen while that read is pending, results in
Icons and Gallery, and return to the original folder. They failed on the previous implementation with six failed
expectations. All 39 focused tests across folder preferences, native browser preferences, results, View Options,
settings search and row movement pass with the correction.

## Boundaries reviewed

| Area | Checks and relevant regression coverage |
|---|---|
| 3MF/STL | Descriptor-based regular-file reads; sandboxed archive workers; bounded package parts and decoded XML; external/path-escaping references refused; invalid coordinates, indices, transforms, cycles and unsupported required extensions rejected; triangle/instance limits before GPU buffers; WebKit shutdown and GPU failure fallback. `ThreeMFPreviewTests`, `STLPreviewTests`. |
| Markdown equations and diagrams | Bundled offline scripts with no Node runtime; untrusted source passed as JavaScript arguments; nonpersistent WebKit, content rules and navigation restrictions; TeX trust disabled; input, expansion, image and document limits; cancellation, timeout and process-failure ownership; source-copy ranges, attachment baselines, Find and batched replacement. `MathPreviewTests`, `MarkdownDrawingTests`, `MarkdownPreviewTests`. |
| Native text operations | Replacement batches validate the entire ordered range set before editing; native editing exceptions retire the affected renderer; failed renderers reject later work. Existing layout, resize, drawing and Find boundaries remain in place. `PreviewTextBoundaryTests`, `MathPreviewTests.nativeReplacementBatchesRefuseBadRangesBeforeChangingAnythingAndCatchEditingExceptions`. |
| ODS/XLSX | Shared bounded XML reader; DTD/entity refusal and external entities disabled; namespace handling; duplicate archive parts; saved values rather than formula execution; repeated rows/cells intersected with the loaded page before expansion; cell/page/row/column limits; sheet/page changes and Find on materialized native rows. `ODSPreviewTests`, `XLSXPreviewTests`. |
| Results and file commands | Rank and selection across List/Icons/Gallery; duplicate groups and location labels; no background paste/drop destination in results; original folder settings preserved; late item metadata cannot overwrite a newer result's location. `ResultPresentationTests`, `SearchViewModeTests`. |
| Folder settings | Owner-scoped notifications, independent preference environments, validated saved records, resolved-folder ownership, cancelled reads and temporary workspace choices; the new icon-size regressions above. `FolderViewSettingsTests`, `BrowserPreferencesTests`, `ViewOptionsTests`. |
| Settings search | Stable identifiers rather than translated titles; originating pane and navigation revision retained for folder actions; native tabs/controls revealed without changing settings; replaced requests, teardown and weak captures. `SettingsSearchTests`. |
| Performance fixes | Cached immutable path keys retain previous normalization semantics; bounded row-move plans validate identities before native updates; large resorts reload once and preserve expansion and exact selection; descendant ordering still refreshes when roots stay put. `TagColumnTests`, `PathSpellingTests`, `BrowserRowMovesTests`, `BrowserOrderingTests`. |

The implementation keeps format parsing, offline rendering, presentation state and native row-move policy in separate
owners. The audit fix adds no dependency, background service, global exception handler or file-writing path.

Bundled dependency versions and notice hashes are checked by `Tests/test_third_party_notices.py`. The primary project
advisories consulted did not identify an applicable issue in the pinned KaTeX 0.19.1 or Mermaid 12.2.0 versions;
see [KaTeX's advisory](https://github.com/KaTeX/KaTeX/security/advisories/GHSA-238p-pmpm-9mq7) and
[Mermaid's advisories](https://github.com/mermaid-js/mermaid/security/advisories).

## Validation

- The new negative regression run and passing focused run are saved locally in
  `/private/tmp/strata-audit-icon-negative` and `/private/tmp/strata-audit-icon-focused`.
- English extraction is current: 1,542 strings, no new or removed strings. Every supported language is complete.
- Theme, main-thread, application ownership and destructive-action audits pass. The 106 Python tests pass.
- Final full normal suite: **1,858 tests in 254 suites passed**, 481.604 seconds. The check recorded zero crash reports
  and no unhandled native-exception diagnostics. Local artifacts: `/private/tmp/strata-audit-full`.
- Final full Address Sanitizer suite, run after the normal suite: **1,858 tests in 254 suites passed**, 777.501 seconds.
  No sanitizer diagnostics, crash reports or unhandled native exceptions were recorded. Local artifacts:
  `/private/tmp/strata-audit-asan`.

## Practical limits

- Oversized or unsupported previews deliberately show a message or retain readable source; the app does not attempt
  unlimited expansion. ODS/XLSX sorting and Find cover the loaded page. Spreadsheet formulas are not executed.
- Exception guards contain the native operations they wrap. They cannot contain a memory fault in an in-process
  system framework, and Address Sanitizer does not instrument Apple's prebuilt frameworks. Archive parsing and
  WebKit rendering already have process boundaries; native AppKit text/table views still run in Strata.
- Browser timings in [the performance report](browser-performance.md) use synthetic, warm-cache fixtures. They are
  not measurements of every user's disk, network location or installed application.
- Changes are local. This audit does not publish a build, push commits or release the app.
