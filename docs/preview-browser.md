# Folder and archive previews

Space opens a native, temporary preview of the selection. Folders and archives expose their contents without
changing the originating browser's folder, selection, scroll position or view mode. Selecting a child previews it
alongside the tree. Text editing keeps its normal keys; Escape closes the preview and restores the source view.

The feature uses the originating BrowserServices environment. Preview navigation is read-only. Open, Show in Strata,
Copy and extraction are explicit actions on captured items. Closing, replacing the selection, navigating the source
pane and closing that pane cancel its work and reject late completions. No preview starts a recursive index scan.

Theme consistency is part of the foundation: use ThemeStyle for owned backgrounds, existing file cells and injected
typography, native AppKit window chrome and split views, and native control styling. Check light, dark, every palette,
high contrast and selected/unselected text before the first feature commit. Appearance changes must recolor the
existing preview without replacing its content or losing selection. A preview never changes browser view settings.

## Implementation stages

Each completed stage is a separate feature commit. Review its diff, ownership, security boundaries and applicable
coding rules, fix findings, run its regression tests and required mutations, extract localization, check every
catalog, and run the source audits before moving to the next stage.

1. Native Space preview: folders, lazy child loading, embedded file previews and non-extracting archive listings.
2. Filtering, sorting and explicit actions: Copy, Copy Path, Open and Show in Strata; stable source pane and item ownership.
3. Photo browsing: native icon collection, visible thumbnails, size control and an independent list/icons choice.
4. Selective archives: bounded single-entry previews and copy-out, password requests, owned temporary files and
   cancellation. Listing an archive must never invoke full-archive extraction.
5. Size reporting: distinguish logical size from allocated disk space, including sparse files; recursive measurement
   is explicit, cancellable and does not follow links.
6. Provider support: remote and container listings and individual content fetches use the owning environment,
   respect cancellation and never download an entire folder for a preview.

## Verification

Cover native keyboard dispatch in List, Icons, Columns (including deeper columns), Gallery, Disk Usage, results and
both panes. Tests keep preferences, clipboard, History, caches, credentials and providers isolated. Hold reads and
deliver their completions out of order to prove stale work cannot change a replacement preview or another pane.

Destructive operations and scratch cleanup belong in the destructive-action map with tests and mutation evidence.
Exercise malicious archive paths, links, duplicate members, replacement identities, passwords, oversized streams,
incomplete output and failed cleanup. Keep parsing, cancellation and callback-lifetime coverage under Address
Sanitizer, and verify the full suite in Debug and optimized Release at the end.

Native headless layout checks establish view structure and rendering. They do not establish the live compositor's
appearance. GUI checks must not manipulate the installed Strata or change the user's preferences.

## Progress

- Branch created from the current remote main at c7a2822.
- Foundation implemented and reviewed.
- Review fixes: bound local enumeration before allocating rows; reject malformed provider batches; preserve physical
  Applications paths; avoid duplicate archive listing in the detail pane; close and cancel on pane navigation,
  teardown and refused presentation. Preview work keeps its source pane weak. Partial archive listings retain their
  limit notice in the footer.
- Focused verification: 19 tests pass, including native Space dispatch across all five views, both panes and deeper
  Columns; cancellation/replacement, read limits, real archive listing, Quick Look lifetime and 36 palette/appearance
  combinations. Font and palette changes preserve the selected row and existing text renderer.
- All 22 translation catalogs are complete (1,422 strings); 44 localization/resource regression tests and both
  source audits pass. Native headless windows remain unshown throughout these checks.
- The complete Debug suite passes under Address Sanitizer: 914 tests in 111 suites, without sanitizer diagnostics.
  All four foundation/provider-preparation mutations are caught in a temporary checkout, removed afterward.
- Foundation commit: `bfabab1`.
- Filtering, sorting and actions implemented and reviewed.
  Filtering reuses the existing sort, preserves pending explicit reads and never discovers more folders. Native
  headers and the actions menu offer Name, Kind, Date Modified and Size without writing browser sort settings.
  Copy, Copy Path, Open and Show in Strata retain their preview item, session and originating pane. File and parent
  identity checks refuse replaced paths; an old menu cannot act on a newly opened preview of the same path.
- Review fixes: prevent file-editing commands and file Undo from falling through to the browser behind the panel;
  keep normal text editing; close Space previews from read-only content while allowing spaces in editable fields;
  avoid recursive native window closing; release closed outline rows; retain partial-listing notices during filtering.
  The new controls retain native search bezels and render on the existing content surface in all 36 appearance cases.
- Additional security review: automatic file renderers accept only current regular files, refusing named pipes and
  replacement links before any rich or native renderer starts. The real view regression passes for both cases.
- Focused action verification: nine action/sorting/window tests and the theme test pass; the broader 31-test preview,
  provider-clipboard and Quick Look regression selection also passes. All 22 catalogs contain 1,425 complete strings.
- Final action verification: the complete Debug ASan suite passes 924 tests in 112 suites; the final 30-test ASan
  selection also covers the added special-file and late-fallback cases, with no sanitizer diagnostics. All seven
  action/sorting/provider-path/renderer mutations are caught. The 44 Python regressions, catalogs and source audits
  pass, and temporary verification checkouts are removed.
- Actions commit: `8694811`.
- Native Icons implemented and reviewed. Use the existing
  GridLayout, GridItemView, typography, thumbnail owner and ThemeStyle canvas. Preview mode and icon size have their
  own preferences. Internal folder navigation, Back and Command-Up retain the source browser; switching modes
  preserves a selected descendant and expands its already-loaded ancestors. No folder measurements start here.
- Grid review fixes: clear hidden selections, use the active view for keyboard focus, cancel pending folder reads
  when going back, keep palette/font changes in place, and cancel offscreen/closed/reused cells. Eight concurrent
  thumbnail requests share the preview allowance; failures, cache hits and placeholder invalidation return it.
  Resizing within a size bucket keeps the existing request/image. Oversized callback images are rejected before
  cropping or display with checked byte-cost multiplication.
- Grid checks: 46 preview/thumbnail/provider tests pass, including native arrows, Return, Command-Up and Space,
  private preferences, cancellation, coalescing, cache and image-size boundaries. The 36-case theme fixture uses
  real native collection cells and verifies the drawn owning canvas plus AppKit's collection background binding;
  selection, cell and thumbnail identities survive. These remain headless checks, not a live compositor check.
- Final grid verification: 936 tests in 113 suites pass under Debug ASan; the final 31-test ASan selection and
  20-test native selection pass after adding the command-palette responder guard. All seven grid mutations are
  caught, all 44 Python regressions pass, 22 catalogs remain complete and both source audits pass. The preview
  cannot open the underlying browser's file-command palette while it has focus.

- Selective archive stage implemented and reviewed. The archive service, an XPC service in the app with an App Sandbox
  of its own, starts a worker for each read that inherits that sandbox and reads a pinned archive descriptor using
  macOS's libarchive, kept from your files, the network and other programs. Passwords reach the worker through its
  request pipe and stay with this preview; they never enter arguments, messages, preferences, logs or the keychain.
  Encrypted ZIP is supported; unsupported 7z/RAR encryption is reported without repeated prompts.
- Selected regular files render through the existing file preview. Explicit Copy stages exactly the chosen member
  or subtree for the owning clipboard and transfer queue; Paste and Move copies temporary sources, and normal Paste
  supplies conflict handling, History and Undo. Open also keeps its exported file alive beyond the preview. A delayed
  Copy respects a newer clipboard choice. Completed exports of one file reuse their content for the preview.
- Materialization uses private modes, clears inherited root ACLs, preserves archive quarantine and records each
  created identity before publication. Cleanup never adopts a replacement or removes foreign children. Closing,
  replacing the source or selection, and Cancel stop work and discard late responses. Copy Path remains the archive
  member's location, never a private staging path.
- Limits are explicit: 256 MiB per file copied out, for a preview or an export, streamed to its file as it comes; 60 MiB
  of worker output per folder copied out; 512 MiB of preview cache including orphaned files and preview copies still
  being written; 50,000 archive headers, 128 path components, 1 GiB of cumulative input reads, and a 20-second read
  deadline (the service ends a worker after 25). Each worker also has a CPU limit and a sampled 256 MiB resident-memory
  ceiling; this does not guarantee a per-allocation limit inside the system parser. System libarchive itself is not
  sanitizer instrumented. Unknown cache files are counted and left alone rather than deleted to reclaim space.
- Selective extraction deliberately refuses links, special files, duplicate/ambiguous paths and members with a
  resource fork. Full extraction remains available for those items; selective Copy never silently drops a fork.
  Only file data and quarantine are copied, with safe new permissions; other archive metadata is not applied.
- The native password field uses the owning themed window and preserves its input in all 36 palette/appearance
  combinations. These remain headless native checks, not live compositor verification.
- Final archive verification: 957 tests in 114 suites pass under Debug Address Sanitizer; the final 33-test
  sanitizer selection also passes. The broader 117-test preview/provider run passes, and 13 standalone C helper
  cases pass under Undefined Behavior Sanitizer. All 15 archive mutations are caught. One initially exposed a gap
  in the test: a second guard still refused a symlink after transient scratch creation. The test now checks the
  unchosen target directory's timestamps as well as its contents, proving refusal occurs before that creation.
  The final mutation runner independently builds and passes its unchanged baseline before breaking the guard.
- All 22 catalogs contain 1,432 complete strings. The 44 Python regressions, destructive-action audit (122 mapped
  functions), theme audit (61 reviewed exceptions) and whitespace check pass. Temporary verification worktrees are
  removed. Runtime sanitizer checks do not instrument the system libarchive binary.

- Size reporting implemented and reviewed. A file's logical bytes and filesystem-reported
  allocated blocks are separate. Sparse files use metadata only. Calculate Size explicitly starts a bounded folder
  walk; Cancel, selection changes and closure stop it and discard late results. Hidden contents are included,
  hard links are counted once, links contribute only their own bytes, and mounted volumes are not traversed.
- Measurements stop after 100,000 entries, 128 directory levels or five seconds. Unreadable or skipped contents and
  reached limits produce an “At least” lower bound, never a completed total. Cancellation produces no new result.
  The root and parent stay pinned, directory streams close before descending, and opened child identities match the
  names captured without following links. Filesystem allocation can include shared APFS extents more than once;
  this is the space the filesystem reports for these files, not exclusive ownership of physical blocks.
- Provider contents never measure their host caches or fetch a folder to calculate its size. The native controls
  reuse the existing themed footer and summary, and results survive every palette/light/dark/contrast change.
  Archive limit notices remain visible while unrelated metadata loads. No measurement writes to user files.
- Final size verification: all 967 tests in 115 suites pass under Debug Address Sanitizer without runtime
  diagnostics. The focused 22-test preview/measurement/theme selection passes, all ten size mutations are caught,
  and 44 Python regressions, all 22 catalogs (1,435 strings), both source audits and the whitespace check pass.
  Review fixes keep archive-limit notices visible during metadata loading, count invalid directory records against
  the entry budget, refuse host-cache measurements for providers, and prevent closed measurement owners restarting.

- Provider previews implemented and reviewed. Native server and container folders have a metadata-only listing
  path that does not schedule eager downloads. Container content listings require shell metadata; unavailable
  metadata does not fall back to streaming the whole folder as an archive. Existing engine/stack roots retain
  their metadata-only refresh. Listing requests coalesce within their owner, reject more than 50,000 entries before
  applying placeholders, pin the cache folder identity, and drain before that copy is removed.
- Selecting a provider file automatically fetches only that regular file, with a known size at most 32 MiB.
  Folders and links never take that path; larger files offer explicit Open. Cancel, selection changes, navigation
  and pane closure invalidate the request. A fetched archive starts its independent archive listing, and a fresh
  fetched file receives a current command identity. Notifications match the owning provider and exact source path.
- Explicit Copy may prepare the chosen folder, then uses the transfer engine to create a private clipboard export.
  It verifies recursive placeholder absence before publication, keeps creation receipts for cleanup, respects a
  newer clipboard choice and retains published exports beyond panel closure. Paste and Move copies staging files;
  conflict handling, History and Undo remain with the owning queue. No preview command changes the remote source.
- Review fixes keep an explicit file command attached to an already pending automatic read without discarding its
  target, suppress notification adoption during that command, and clean unpublished exports when a pane closes or
  its clipboard changes. Provider failures stay in the native themed footer. No new color exceptions were added.
- Focused provider verification: the initial 20 new provider tests and broader 39-test selection pass. These cover real
  native provider metadata paths, held cancellation/disconnects, source isolation, oversized listings, exact Copy,
  export receipt cleanup, clipboard changes, normal Paste/Undo, fetched archives and every view in both panes.
- Final review also disables Open for unsupported provider file links, while retaining folder-link navigation and
  normal local-link behavior. A plain command-availability regression covers all three cases.
- The finished Debug suite passes 988 tests in 117 suites. The full Release and Debug Address Sanitizer runs pass
  987 tests in 117 suites before the final pure link-action availability change; that change has its own passing
  sanitizer regression. The two clipboard-export tests also pass under the sanitizer with Redo assertions, returning
  their own copies from Trash to their temporary trees before cleanup.
- One initial Debug run failed the existing archive extraction/History test. Its original assertion omitted the
  extraction error; the assertion now includes that diagnostic. The failure did not reproduce in 20 independent
  focused attempts or the subsequent complete Debug run. Its cause remains unconfirmed; no assertion was weakened
  and no production extraction change was made on that evidence.
- All eight provider mutations are caught, bringing the staged feature verification to 51 caught mutations. All
  22 catalogs contain 1,436 complete strings. The 44 Python regressions, destructive-action audit (122 functions),
  theme audit (61 reviewed exceptions) and whitespace check pass. The Debug app bundle contains 22 unique
  localizations, its license notice and both helpers; signature verification and real bundled archive listing and
  exact-member reading pass without changing the source archive. The app was not launched.
- Final optimized regressions pass all 15 tests in four suites, including preview commands, provider link
  availability, both archive/provider clipboard Paste/Undo/Redo cases and archive History extraction. Production
  sources stayed frozen throughout this final run. All six implementation stages are complete.

## HTML documents

HTML, HTM and XHTML now open in a rendered Preview, with a native Preview / Source switch and an explicit Open in
Browser action. Vue, Svelte, PHP and other templates retain their source-code previews. The shared rich-preview
route makes this available in Space, Columns, Gallery and Get Info. Source uses the existing syntax highlighter;
its file descriptor is opened relative to the captured selection and refuses replacement files or links.

The renderer uses an ephemeral WebKit data store with content JavaScript disabled. A compiled content blocker
rejects resources outside the private document scheme, independently of the document's Content Security Policy.
Only the initial main document and clicked same-document anchors navigate inside it; clicked HTTP(S) links can open
externally. Forms, downloads, embedded pages, popups, file pickers, automatic redirects and other URI schemes are
refused. Competing base/refresh/DNS metadata and resource hints are removed before parsing. Local stylesheet links
retain their media condition. No production JavaScript is injected.

WebKit never receives file URLs or broad filesystem access. Its custom scheme reads only the selected document's
folder, through no-follow descriptors and bounded reads. Selecting HTML in a provider or archive does not fetch its
surrounding assets. Already-local CSS and raster images can load; images become bounded static thumbnails, a JPEG
staying a JPEG and anything else becoming a PNG.
External fonts, SVG asset files, data URLs and online resources stay blocked. Inline document markup and authored
colors are retained. The panel, native controls and Source mode use the existing Strata theme.

The document input limit is 512 KiB. Assets allow 32 distinct attempts and 8 MiB in all, including image conversion;
CSS is limited to 256 KiB and image input to 4 MiB; images share sixteen million pixels in all, checked from their
headers before decoding (`PreviewPicture`), and an attempt once counted runs to its end so a later WebKit lifetime
can still use it. Raster thumbnails are at most 2,048 pixels on an edge. A WebKit session also caps all requests,
including repeated cached resources, at 32 and total response delivery at 9.5 MiB. A page WebKit hasn't started
showing within eight seconds switches to Source; once it shows, styles and pictures still coming never end it. A page
kept behind Source that fails is shown again when Preview is chosen. Oversized or unsupported documents use bounded
Source with no unrestricted Quick Look fallback.

Cancellation stops the current WebKit lifetime, suppresses late scheme callbacks and rejects changed files.
Reattachment starts a fresh lifetime for the document read at first. A page that can't be shown, its file changed
since for one, shows its Source as it is now, and choosing Preview reads it again. The HTML, EPUB and OneNote previews
share this lifecycle (`WebPreviewView`) and their WebKit page (`PreviewWebPage`). Theme changes preserve the current
web view, Source text and selection.
The browser action keeps the originally selected file and refuses a replacement; interactive pages run only when
the user explicitly opens them externally.

HTML verification includes real WebKit DOM/style/image checks, all palette/light/dark/contrast combinations, stopped
and reentrant scheme tasks, reattachment, file replacements, FIFOs, escaping links, URL decoding, byte/count/pixel
budgets and Source fallback. A loopback-only HTTP fixture proves network refusal with a separate positive-control
server; the blocker is also tested without the document CSP. Initial fixture failures came from answering before a
complete HTTP request was read on a nonblocking accepted socket. The fixture now reads complete bounded headers on
its background queue with a timeout, and never mixes control connections with forbidden-resource connections.
No network assertion was relaxed. All nine HTML security mutations were caught; the network mutation was caught
again against the corrected fixture after its unchanged baseline passed.

Final HTML verification passes the complete Debug suite under Address Sanitizer and the complete optimized Release
suite: 1,004 tests in 118 suites each, with no sanitizer diagnostics. The focused HTML/theme selection passes 16
tests; the source-highlighter/JSON/text safety selection passes 22. All nine new mutations were caught, and the
corrected network fixture independently caught the missing-blocker mutation again. All 22 catalogs contain 1,440
complete strings; 44 Python regressions and the destructive-action (122 functions), theme (61 reviewed exceptions)
and whitespace audits pass. No C archive helper code changed in this feature.

The signed Debug bundle is `build/Strata-HTML.app`, keeping the previously running build untouched. App and Sparkle
share the Developer ID team; deep signature verification, 22 unique bundled localizations, archive-helper listing
and exact-member reading pass. Startup and foreground activation were verified by the new app's actual process ID.

## Window and pane sizing

The preview starts at a 1,000 × 640 content size with 40% for browsing and 60% for the selected item's preview.
Manual window resizing is saved after the native resize ends. Reopening centers the panel on the source browser's
display and fits its remembered size within that display's available area. Display fitting never overwrites the
saved size. Preferences remain with the originating BrowserServices environment.

A native NSSplitView retains its divider interaction and accessibility. Its small owning controller lays out the
two child controllers and remembers intentional divider changes; it preserves the chosen fraction during window
resizing. The list and preview keep 280-point and 320-point minimum widths. A single-file preview temporarily hides
the list and fills the window without changing the remembered folder/archive split.

Pure size validation, display fitting, pane limits and column-space decisions live in PreviewLayout. Window
lifecycle belongs to PreviewCoordinator; native divider interaction belongs to PreviewSplitViewController. The
preview browser applies the column decision without changing its session, file selection or originating browser.
No file commands or background reads own layout preferences.

Name absorbs available list width. Size stays visible; Date Modified and then Kind appear only when Name retains
a useful width. Metadata columns use localized header minimums and remember manual widths. A narrow panel can
compress Size without discarding its preferred width for the next wider layout. Surfaces, native controls and
file typography continue to use the existing theme and owning preferences.

Seven native/pure regressions cover malformed preferences, smaller displays, independent environments, window
restoration, native divider changes, narrow/wide columns, temporary full-width file previews, selection preservation
and release of the split controller and its layout callback. These are headless layout checks.

Layout verification passes all 1,011 tests in 119 suites under Debug Address Sanitizer and optimized Release.
The seven layout regressions also pass under the sanitizer after strengthening the narrow-window case to force
the preview to its minimum width and verify the saved fraction survives that clamp. No sanitizer diagnostics or
layout constraint warnings were reported. All 22 catalogs contain 1,440 complete strings; 44 Python regressions,
the destructive-action audit (122 mapped functions), the theme audit (61 reviewed exceptions) and whitespace
checks pass. The layout checks remain headless and do not claim live compositor verification.

The signed Debug bundle is `build/Strata-Preview-Layout.app`. Deep signature verification passes, and the app
and Sparkle share the Developer ID team. Bundle checks confirm 22 unique localizations, the license notice and
archive helper, a real archive metadata listing and exact-member reading without changing the source archive.

## Preview cancellation and root-directory follow-up

Archive selection cancellation dismisses its own password request synchronously on the main actor, before a new
selection or command can ask again. The content owner keeps only a weak reference to that archive access and
clears it before callbacks. Normal sheet cancellation retains its alert-identity guard.

Replacement archive exports and provider commands wait for both the preceding selection read and command to
finish. Provider commands retain an already pending automatic file read across repeated Copy requests, while
Cancel and closure still cancel that read. Only the latest command can publish an export.

Archive workers ignore relative root directory aliases such as `.` and `./.`. The exemption checks the entry type
and rejects links, special entries and absolute roots, including during selective reads. It preserves libarchive's
classification of legacy empty slash-terminated directory headers. Real system-generated CPIO and tar fixtures
exercise listing and exact-member reading without changing their source archives.

The regressions reproduced the password ownership race, overlapping commands and rejected tar/CPIO root entries
before the fixes. Headless tests use held continuations and independent preview environments. They check immediate
password release for Cancel, selection replacement, commands and closure; serial command replacement; preserved
shared reads; exact exported contents; scratch cleanup; and unchanged neighboring files. Seven matching mutations
cover these rules.

Final verification passes all 1,019 tests in 121 suites under Debug Address Sanitizer and optimized Release.
The focused archive/provider selection passes 43 tests, including all eight new regressions. All seven follow-up
mutations were caught. A separately instrumented copy of the real C worker passes 63 requests under combined
Address Sanitizer and Undefined Behavior Sanitizer, including ordinary and unsafe root aliases, real CPIO,
passwords, malformed requests, byte limits and AppleDouble resource forks, with no sanitizer diagnostics.
All 22 catalogs remain complete at 1,440 strings; 44 Python regressions, the destructive-action audit (122 mapped
functions), the theme audit (61 reviewed exceptions) and whitespace checks pass. Checks remain headless.
