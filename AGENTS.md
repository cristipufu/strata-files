# Strata: notes for coding agents

Strata is a native macOS file manager (Swift, AppKit, SwiftPM; macOS 26, Apple silicon). People trust it with their
files: a bug that deletes, trashes, moves or overwrites the wrong thing is the worst bug it can have. Read
[Changes that touch files](#changes-that-touch-files) before changing anything that does.

## Repository map

- `Sources/Strata/` — the app, one folder per area: `Browser` (the file list and its commands), `Views` (Icons,
  Columns, Gallery, Disk Usage), `Window` (windows, panes, sidebar wiring, Compare & Sync), `Transfers` (copy/move
  jobs, conflicts, archives), `Model` (FileOps, Trash, History in `OperationLog`, SecureStorage), `AI` (Ask Strata
  plans), `Remote` (SFTP and S3), `Containers`, `Dev` (git, project cleanup), `Inspector`, `Toolbar` (path bar,
  suggestions), `Palette` (command palette), `Previews` (file previews), `Previewing` (Space previews of folders and
  archives), `Index`, `Sidebar`, `Settings`, `Dock`, `AppUpdates`, `App`, `Support`. `Package.swift` compiles the lower
  layers as internal library targets (`StrataSupport`, `StrataTheme`, `StrataModel`, `StrataPreviews`, `StrataIndex`)
  imported by `Strata`, so the compiler enforces module boundaries and `IndexStore`'s private storage.
- `Sources/CArchivePreview/` and `Sources/StrataArchiveWorker/` — the C archive parser and its sandboxed helper
  process.
- `Sources/StrataCLI/` — the `strata` command.
- `Tests/StrataTests/` — Swift Testing. Shared helpers in `Support/`: `TestTree`, and the injected clocks, readers and
  volumes the principles below ask for (`TestClock`, `ControlledDirectoryReads`, `TestWork`, `ScratchVolume`).
- `Localization/*.json` — one file per language; `en.json` is generated from the code.
- `docs/` — guides (themes, website, README translation, destructive actions); `docs/release-notes/<version>.md` is
  shown on GitHub and in the update window.
- `site/` — the website.
- `scripts/` — build, localization, audit and release tooling.

## Build, test and CI

```sh
scripts/build.sh debug                  # build/Strata.app; no argument builds release (see "--open" below)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
python3 scripts/localize.py extract     # after editing Swift files: regenerates Localization/en.json
python3 scripts/localize.py check --all --complete  # every supported language must be complete
python3 scripts/audit-theme-colors.py    # no unreviewed surface colors or unthemed Inspector gray text
python3 scripts/audit-destructive.py --check  # the map names every flagged function; mutations.json fits the code
python3 -m unittest discover -s Tests -p 'test_*.py'  # checkers and generated resources
```

- `swift test` needs Xcode's toolchain: the Command Line Tools fail with "no such module 'Testing'".
- Run the debug and sanitizer suites one after the other, never together: both use the real Trash, and a second
  runner can reuse a pending Redo's old Trash path and correctly trigger a refusal.
- `scripts/build.sh debug --open` quits every running Strata, the user's installed copy included, before launching
  the build. To try a build next to the user's copy, run `open -n build/Strata.app` instead.

### Localization

- User-facing text goes through `String(localized:comment:)`; plurals carry `comment: "plural"`; quotes are curly.
- `en.json` records each string's `File.swift:line`, so even a line shift above a `String(localized:)` makes it stale
  and fails the Translations check. Run `extract` and commit `en.json` in the same commit as the code.
- Adding or changing text means updating every `Localization/<language>.json` in the same commit: extraction updates
  only English. Reuse translations supplied by users. `check --all --complete` fails on missing keys, blank text
  (including whitespace) and missing plural forms. Text identical to English is fine when intentional (Strata, Finder,
  Git, shortcuts).
- `swift test` runs the same completeness check (`LocalizationTests`).

### CI and release gates

- Pushes to `main` and pull requests that touch the code run **CI** (destructive-action audit, Python checks, build
  and `swift test`, plus an Address Sanitizer job) and **Translations** (complete catalogs, `en.json` matching the
  code). README and website changes run **README translations** and **Website** (see `docs/readme-localization.md`
  and `docs/website.md`). **Mutations** runs weekly.
- Tags run **Release**, which repeats extraction, completeness and localization regression tests, the full Swift suite
  and the sanitizer suite before importing signing credentials, signing or publishing, including on manual runs.
- Never bypass these gates or release with incomplete translations.

## Changes that touch files

Every code path that deletes, trashes, moves, renames, overwrites, evicts, or changes the permissions or metadata of
user files, on this Mac or on a server, needs headless tests in the same commit. A change to such a path without tests
isn't done. The tests must show that:

- **Only the chosen items change**: never a sibling, a look-alike name (`a` next to `ab`, `a.txt`), the same name in
  another folder, a parent, or what a link points to. Selections that nest (`a` and `a/b`) are handled once.
- **Refusals happen up front**, before anything changes: disks, folders you can't change, archive copies (read-only),
  a server's top or a bucket, a folder into itself.
- **Nothing is replaced without an explicit decision**, and a replacement happens only once a complete copy exists.
  Two items of one operation never replace each other.
- **Undo (⌘Z and History) restores exactly those items**, and never touches something that took their place.
- **Every view hands commands exactly its selection** (List incl. open folders, Icons, Columns incl. deeper columns,
  Gallery, Disk Usage, results, both panes), and it stays the same items when the folder changes.

### The map and the mutations

- `docs/destructive-actions.md` lists every destructive action with the code that does it and its tests, and, at the
  end, every function `scripts/audit-destructive.py` finds holding a file-changing call, a folder creation or a tool
  launch (`Process`, AppleScript). Add a row for a new one and keep the rows true when code moves: CI fails when a
  function isn't named.
- A new destructive-action test comes with an entry in `Tests/mutations.json`: a one-line change that breaks its rule
  (skip the check, read it late, apply it to the wrong item) and the tests that must then fail. Commit the change,
  then run `python3 scripts/mutate.py <a word from the rule>` and see it caught before pushing. It refuses source files
  with uncommitted changes, restores them with `git checkout`, and runs `swift test` itself, so never run it alongside
  another test run. The Mutations workflow runs them all weekly. Update an entry when code moves and its text no
  longer matches.
- Every function the audit finds must be reached by a mutation, or listed under "Not mutated, and why" with its reason
  (it makes Strata's own scratch files, hands work to a function that is mutated, or guards an instant no test can
  time); CI fails otherwise.

### Decisions are plain functions

Keep the decision separate from the alert or UI so tests call it directly: `BrowserViewController.deletionPlan`,
`FileOps.canTrash`, `FileDrop.operation(_:into:mask:option:copies:)`, `PlanValidator.validate`,
`TransferEngine.mergePlan`, `FolderCompare.defaultAction` and `syncPlan`. Prove a new test guards its rule: break the
rule once, watch the test fail, restore it.

### Safety idioms

- Reuse what's in place: `lstat`, `O_NOFOLLOW`, `renamex_np(RENAME_EXCL)`, deleting relative to an open folder, and
  identity checks before undo (`LandedFiles` for ⌘Z, `OperationLog.identity` for History). An undo that trashes or moves
  items checks that each is still the one the operation left there.
- Validate every source in a remote delete or move batch before connecting or changing anything: an unsupported later
  source must not turn an up-front refusal into a partial operation.
- A decision that needs a window to ask in falls back to what changes nothing when the window has closed meanwhile,
  as `uploadChoice` does.

## Undo, History and file identity

- File identity reads belong in `FileIdentity`; live operation ownership belongs in `LandedFiles`. Read without
  following links, and record identities when items land, before callbacks can replace them. Runtime identities
  include birth time; History keeps its volume UUID/inode and legacy device:inode formats. Don't silently change those
  saved representations or replace a same-disk expectation with an identity read later.
- Pass captured `LandedFiles` into History registration after asynchronous work or callbacks. Converting to saved
  identities must still match that ownership; a failed match gets an explicit refusing key, never an absent key that
  would enable legacy existence-only Undo. Cover saving, reopening and a replacement arriving before logging.
- Folders an operation creates: `CreatedFolders` captures their ownership when they're made, before alerts or
  asynchronous transfers, and is shared by live Undo, History and cancellation cleanup. Cleanup verifies the recorded
  identity and removes empty folders nonrecursively; a failed directory listing is not an empty folder. Redo records
  the folders it recreates and updates their saved History identities. Old records without container identities may
  restore files but must not remove those folders. Read and remove Finder records relative to an owned, opened
  directory and never follow a cleanup symlink. Cover replacement files, folders and symlinks, including anything at a
  link's target; never use recursive removal for this cleanup.
- Retrying a failed transfer keeps the destination and parent identities of the failed attempt: a replacement file,
  directory or redirected parent is not the incomplete copy. Cover safe refusals and successful repair of retained
  fragments, missing destinations and nested failures. Copying directory metadata can change birth time: keep the
  original descriptor through cleanup instead of adopting the cleanup pass's reopened pathname.
- `TransferJournal` journals results after each completed pass, and native Undo and History share the same receipt:
  a repaired copy updates its captured identity, and a finished move replaces its copy classification. Never extend a
  record whose Undo has started, whose action has been replayed, or which History has cleared. History buttons
  resolve the current saved entry ID before acting, since a captured row can predate a retry.
- Browser file commands use `BrowserServices.files`, which keeps the transfer queue's History, preferences and
  providers. New File, New Folder, Rename, Trash, project cleanup and Ask Strata keep that owner through native
  Undo/Redo and sheets. Capture creation identities before History notifications can replace an item.
  `BrowserRename.decision` is separate from its native confirmation; commits recheck navigation and item identity.
- History panels receive their store and native Undo manager from the application owner, observe only that store, and
  keep both through a requested Undo even if the panel closes. A delayed alert must not clear a different History.
  Headless panels disable native frame autosaving and never show error sheets.

## Architecture: who owns what

### Principles

These apply everywhere below; the sections that follow add only what is specific to each part.

- **One environment per window.** A window's settings, stores, providers, History and server access all come from its
  `BrowserServices`. Injected code never falls back to application-wide stores, and notifications are scoped by their
  owner even when environments share a notification center.
- **One owner per asynchronous request**: a pane, sheet, session or provider actor. Replacing the request, navigating,
  or closing the owner cancels it; focus changes alone don't.
- **Late results never win.** An old success, failure or notice cannot replace a newer request, clear it, publish over
  it, or navigate another pane. Recheck ownership after every suspension and callback.
- **Cancel only your own work.** A Cancel action ends only its own request or ticket, and shared work stops when its
  last caller leaves. Only an explicit Disconnect or server removal ends a server's sessions.
- **Pending work holds windows, panes, sheets and browsers weakly**, and one-shot actions release their captures on
  every terminal path.
- **Test with injected readers, backends and clocks**: hold I/O, complete in both orders, cancel, replace and close.
  Tests never connect to live servers, mount network shares or read the real keychain (a throwaway `ScratchVolume`
  disk image for moves across disks is fine).

### Services and composition

- Build application services with `BrowserServices.shared`, independent ones with `BrowserServices.isolated`, and a
  custom composition explicitly with `configured`, whose queue supplies preferences, History and copy routing. Never
  mutate a supplied queue when constructing a window; copy routing is immutable.
- `BrowserServices` owns its `Clipboard`, `CopyProviders` (`remoteCopies`, `containerCopies` and `clipboardRoot`),
  `ContainerFiles` and `ContainerStore`, and passes them to `TransferQueue`, `TransferJob`, `RemoteUploadJob`,
  `BrowserViewController` (server and container commands, deletion plans, clipboard staging, `Copy Path`, archive
  checks, drag and drop), `InspectorViewController`, `PathBar` and every presentation (`FileOutlineView`, Icons,
  Columns, Gallery, Disk Usage, Sidebar).
- Transfer queues own their preferences and History, through archive work, retries and every Undo/Redo step,
  including queued moves across disks; an injected job never falls back to the global queue. Active work keeps its
  queue until completion, but finished jobs must not form a queue/job retain cycle. Queue-held completion callbacks
  keep panes weak, and one-shot fetch actions release their captures on every terminal path. Test teardown while
  finished jobs remain in the queue.
- Keep `StrataSupport`, `StrataTheme`, `StrataModel`, `StrataPreviews` and `StrataIndex` free of dependencies on
  `Browser`, `Window`, `Transfers`, `Remote` or `Containers`. `FileThumbnails` and `ItemInfoLoader` resolve container
  and Compose stack icon marks and status text from their injected `CopyProviders` and `ContainerStore`; `FileDrop` and
  `ShelfWell` use their injected or active window's `CopyProviders`; `PathSuggestions` reads `showHidden` from its
  injected `Prefs`.
- **Settings.** Windows, panes, sidebars and View Options use the preferences and notification center in
  `BrowserServices`, and pass them into native file views, typography, rename fields and favorite operations. An
  injected pane never reads or changes another environment's settings. Production windows share the application
  services, and app-wide theme and material integration stays application-scoped. Test independent settings with
  native headless views, including cached views and deeper columns, instead of changing shared preferences.
- **Connect to Server settings** (selected protocol, recent shares) belong to `BrowserServices.connectionSettings`.
  Keep the `connectKind` and `recentServers` formats, password removal and the ten-address limit, and inject them into
  new and editing sheets. Share requests belong to the sheet's `ServerMountSession`: detach an old request before
  cancelling it; only the current request may change controls, navigate or save recent addresses; the sheet cancels
  when released. Inject `ServerMounter` for headless tests of failure, cancellation and replacement.
- **Saved searches** belong to `BrowserServices.savedSearches`: saving from the active pane, sidebar removal and change
  notifications. Keep their preference format, and tell searches apart by query and scope as well as name.
- **Workspaces** belong to `BrowserServices`: saved preferences, change notifications and open-window lookup. New tabs
  and restored workspace windows keep that owner through `BrowserWindows`; production uses AppKit's native tab and
  window presentation. Menu choices and sheets keep their originating store, so a focus change or closed window never
  redirects a pending save or update into another environment.
- **Commands** live in `StrataCommand`: keep their action/tag identities and shortcut overrides. Menus use native
  responder routing; the palette uses the same validator and revalidates before dispatch. Never use a translated title
  as identity. A captured file command stays bound to its pane, folder and selection. Test menu and palette
  availability, and stale actions across view, result and location changes.
- Compare reads the owning window's current hidden-files setting each time it scans.

### The file browser

- **`BrowserListing`** owns entries, filtered rows and path lookup. Preserve node identity on refresh, create fresh
  roots on navigation, and validate a whole result update before changing any node. The AppKit controller keeps native
  selection, expansion and editing; publish entries before applying pending actions.
- **`BrowserOrdering`** owns sort choices and comparisons, with cached metadata supplied by its owner. Results keep
  their incoming order until a column is chosen, and late metadata never imposes the previous folder's order.
  Returning to a folder restores its choice; programmatic choices never write preferences through a native descriptor
  callback. AppKit keeps native headers and row animation. Refresh changed child orders even when roots don't move,
  preserving expansion and selection. Defer metadata ordering during inline editing and apply it when editing ends.
  Batch directory totals per pass and never cache an unknown size across passes. Test read counts and results with
  injected metadata, not elapsed-time thresholds.
- **`BrowserPresentations`** owns lazy view creation and attachment. Alternative views get the same sorted, filtered
  content through `FileCollectionController.apply`; each keeps its native selection policy and requests only the
  metadata it needs. Keep cached views, safe-area placement, theme refresh on reattachment and native responder
  routing.
- **`DirectoryReadSession`** schedules folder reads: each presentation owns its generation, rejects late success and
  error responses, and invalidates reads when removed or replaced by results. An explicit Reload's invalidation and
  the listing that follows are one cancellable request: check cancellation after invalidation, and an old Reload never
  starts a read after navigation or a newer Reload. Selections made during I/O survive when entries are applied; keep
  explicit pending selections (including an empty one) distinct from that fallback. Inject `DirectoryReader` in tests.
- **`BrowserLoading`** owns folder state, expanded-row reads and free-space work. Invalidate child reads before reusing
  rows, coalesce them by node identity and keep that identity alive until the read ends. Free-space results stay with
  their folder, also when applying entries navigates again. AppKit marks entries applied only when it displays them;
  a read completing during inline editing is not enough. Inject the capacity reader through `BrowserServices` for
  footer tests.
- **After an operation**, selection and rename wait for entries to be applied, not for a delay, and keep the original
  pane and navigation revision (leaving and returning is a different navigation). Cancel a pending rename when its
  column is removed, the explicit selection or mode changes, or its read fails. A reload that drops the old selection
  still allows the new item's pending rename. Keep each view's selection policy, including Gallery's preview item.
  A listing deferred during inline editing must still match the current read generation.
- **Pane actions** (`browseArchive`, `openArchiveAsFolder`, `open(_:fileOpener:)`, `open(_:withApplicationAt:opener:)`,
  `openQuickLook`, and Connect to Server's `onConnected`/`onServer`) keep their pane and
  `BrowserViewController.navigationRevision`. Navigating away (even back to the same folder), entering a deeper column,
  showing results or messages, or closing the pane cancels `actionFetch` and drops stale completions; deferred Quick
  Look also checks window visibility and selection membership. Closing a pane (`stopBackgroundWork()`) stops active and
  cached presentation work in `ColumnBrowserViewController` and `GalleryViewController`, directory watchers, git
  observation and deferred resort work.
- **Server and container navigation** belongs to the pane's `FolderOpenSession`: replacing its request, navigating
  (including deeper Columns) or closing the pane or window cancels it. Native Cancel buttons target their captured
  request.
- **Sidebar watchers** belong to `FolderWatchers`. Release their shared allowance when a tree closes, collapses folders
  or becomes inactive. Count successfully opened physical directories, including both Applications roots, and never
  evict another tree's watchers. Tests inject an independent budget and expand native headless outlines.

### Server and container copies

Strata browses servers and containers through local copies whose files are placeholders until fetched.

- Common reads go through `CopyProvider` / `CopyProviders`. Each URL stays with its owning provider, fetch and
  preparation errors propagate, and provider-specific write, permission and archive behavior stays in its
  implementation. Selection prefetch is bounded (20 items, 256 MB) and ends on replacement, navigation or pane closure.
- `BrowserServices.copies` and its default directory reader share the window's server environment. Inspector folder
  links prepare their path through that owner and navigate through the pane's `FolderOpenSession`. Provider cache
  paths never become remembered local locations or draggable window-title URLs.
- Shared fetching lives in `BrowserViewController+Fetching`, queued preparation in `CopyFetchJob`; both keep their
  providers through completion, placeholder checks and error messages. Install a job's task before notifying
  observers, because a callback can request Stop. Cancelled work never delivers a completion action or a late failure
  message, and small reads present no error after their browser has closed.
- Media-column readers use the same provider owner and `BrowserServices.mediaReader`. Recheck placeholder state when
  queued work starts and before publishing metadata; never reuse cached dimensions for an invalidated copy, and cancel
  an in-flight read when its copy becomes a placeholder. Fetched placeholders start media reads for active media sorts.
  Keep the four-reader bound, deduplication and empty-result caching. Test replacement reads and reentrant callbacks
  with held completions.
- `BrowserServices.thumbnails` and `BrowserServices.itemInfo` share that provider owner and media reader across List,
  Icons, Columns (including deeper columns and the preview pane), Gallery and Quick Look transition images; folder-size
  checks (`folderSize`, `sizeText`, `canMeasure`) consult the owning providers. When a copy becomes a placeholder,
  evict its cached thumbnails and item info, cancel in-flight requests, and record no Quick Look failure or fallback
  byte size. When placeholders are fetched, refresh visible cells, column previews and gallery previews.
- Before clipboard staging, verify after `prepareForCopying` that no placeholder remains, recursively. Drag symlinks
  from a copy with a `.data` file-promise type. Scope `.containerCopyProblem` notifications to their copy root.
- `InspectorViewController` receives `BrowserServices` and passes `services.preferences` to its cards. It uses
  `services.copies` and `services.remote.copies` for read-only gating (project, Compose, tags, Get Info), server titles
  and `Where` rows, single and multiple-selection folder sizing (`browser.canMeasure`, even for the unselected current
  folder), image dimensions, document summaries and Rich/Quick Look previews. It skips symlinks and placeholders,
  refreshes metadata, summaries and previews when `.containerFilesFetched` arrives for an item in the owning provider,
  and commits any active comment edit before hiding Get Info.
- **`CopyListings`**, owned by each provider actor, coalesces listings and tracks freshness. Invalidation during a read
  requires another read; an old waiter can't clear its replacement or make it fresh. Drain listings before removing a
  copy.
- **`CopyFetches`**, owned by each provider actor, shares downloads. The download stops only after its last waiting
  caller stops. Keep cancelled tasks until they finish, drain explicit and background downloads before removing a
  copy, and coalesce overlapping removals; late cleanup can't clear a reopened copy's requests.
- **`RemoteCopyStore`** serves `RemoteFiles` and its `CopyProvider` adapter for server lookup, paths, placeholders,
  download staging and removal; an injected backend never falls back to the application's copy root. Prepare and remove
  cache children relative to an opened root without following a replacement symlink; invalid IDs change nothing. Test
  identical server IDs in independent roots, including refused cross-environment writes and scoped cleanup.
- Tests inject providers, container listing and content readers, or server backends; a fixture never falls back to a
  live connection.

### Servers: credentials, sessions and connections

- `BrowserServices.remote` owns a window's server access: saved definitions, status, connection sheets, session pools
  and copies come from one environment. Saved-server, status and disconnect notifications are scoped by owner, and
  workspace planning and tooltips stay with that owner. A missing local server copy is a waiting server folder, not a
  missing local folder. Test identical IDs with independent credentials and roots, both sidebar modes, native sheets
  and both panes.
- **Credentials** go through an injected `RemoteKeychain` / `KeychainAccess`. Update secrets in place and never delete
  a working secret before saving its replacement. Only a missing item permits creation; a concurrent creator permits
  one scoped update retry. Keep the native service/account format and an existing item's access policy. Tests use
  independent in-memory Security implementations and assert that neighboring items stay unchanged on errors and
  deletion.
- **Session pools** inject server lookup, backend creation and status delivery. Only an attempt's producer publishes or
  closes its result; disconnect removes pending work before cancelling it. Cancelling a reader cancels only its waiting
  ticket: a shared login stays alive for other panes and is retired when its last reader leaves, a retry never joins
  an abandoned attempt, and a published backend belongs to the pool even if its first reader cancelled. Browser and
  workspace Cancel actions cancel their own requests and never disconnect by server ID; check cancellation after
  resolving a starting folder too, before navigating.
- Providers backed by a pool receive it through `RemoteFiles(sessions:)`. A failed read may retire only the exact
  backend it acquired, through that owner: never a replacement, a newer login or a publication reservation. Ordinary
  operation errors keep the connection.
- **Connect to Server** authenticates proposed settings through `RemoteConnections` before saving credentials or
  changing the registry, and cancels by request identity, never rolling back another attempt's settings. Cache
  retirement and publication are serialized per server with a revocable pool reservation; readers fail promptly
  during that handoff because cleanup can wait for them. The pool and copy cache stay in one environment. Sheet
  teardown cancels its request; published backends belong to the pool.
- **Disconnect and removal** use the same per-server handoff queue: register retirement before notifying saved-setting
  observers, keep automatic readers blocked through cache cleanup, and refuse confirmations whose saved definition has
  changed. Cancelling a waiter never abandons accepted cleanup.
- **Saved server stores** own preferences, credentials, registry and notifications. Publish the complete new state
  before notifying observers; removal never deletes credentials after an observer has saved a replacement. Reading an
  invalid or unreadable saved definition never rewrites preferences.
- Tests use independent pools with controlled backends and fake credentials: cancelled attempts, late failures and
  timeouts, dropped connections, both orders of late completion, and identical server IDs in independent pools.

### Index storage

Index columns belong to `IndexStore.Storage`: borrow them inside `read`, mutate them inside `write`, and keep related
column changes in one write scope. Never reenter the same store's lock from a scope. Returning a column creates a
copy-on-write snapshot, so avoid that in hot paths. Raw column pointers stay inside `withColumns`, with parallel
searches joined before the scope ends. Keep the compact-storage and buffer-growth tests.

## Appearance and theming

- UI backgrounds and borders use `ThemeStyle`; `swift test` and CI run the color audit.
  `python3 scripts/audit-theme-colors.py --list` inventories direct colors. Only deliberate native defaults, semantic
  artwork and document colors belong in `Tests/theme-colors.json`, each with an exact use count and a reviewed reason;
  missing or stale exceptions fail. Never add an exception to silence an unthemed surface. The audit cannot see
  AppKit's implicit gray materials, so keep headless rendered and layout coverage for complete windows and views.
- AppKit stays in charge of toolbar controls, panel corners, material masks and focus. Color owned canvases beneath
  native chrome and use glass's public tint; never paint overlays inside native visual-effect materials. Check the
  full native accessory padding, not just the smaller label container. Keep the native scroll-edge preference when
  clipping the file viewport already keeps content out of the toolbar.
- Inspector text uses `InspectorColors`, including cached attributed strings in Git, Scripts and container cards. Keep
  at least 4.5:1 rendered contrast against every light and dark panel palette, and native colors for System and
  Increase Contrast. Recolor existing cards without rebuilding them or changing selections.
- `NativeHeaderFillTint` is a guarded compatibility adapter, not a public AppKit tint API. It supports only the
  active and inactive titlebar layer structures seen on macOS 26: match structure, not the OS version, since later
  versions can keep it. Unknown structures or non-neutral fills keep native drawing. Never change blur, opacity,
  masks, filters or controls to force a match. Keep native-layer tests for changed structures and check new macOS
  releases visually. `ToolbarBackdropTint.prepare` recognizes known header sections at the titlebar edge and keeps
  their original colors across the window/full-screen move; never extend this lookup into arbitrary content.
- An unshown window cannot verify AppKit's live full-screen compositor. Report headless layout and drawing checks
  separately from visual confirmation in a focused, unfocused or full-screen window; an empty bitmap or a borderless
  fixture is no proof of the real full-screen appearance.
- Contributed color themes are JSON files; see `docs/themes.md`.

## Writing tests

### Fixtures

- `TestTree("a/", "a/b.txt", "link -> a")` makes a throwaway tree (`"x/"` folder, `"x -> y"` link; targets starting
  with `/` or `.` are written as is). `snapshot()` lists it without following links: assert the whole listing, so any
  unexpected change fails. `TestTree.listing(of:)` does the same for any folder.
- Keep a `TestTree` alive until the checks are done: never discard it (`let (_, …) =`), and assert on it last. Swift
  frees it after its last use and its folder goes with it, so a test that only expects refusals would pass without
  checking anything.
- The temporary folder is `/private/var/...`. Spell URLs the way `DirectoryLoader` lists them (`TestTree.root` is
  already resolved); `standardizedFileURL` and `resolvingSymlinksInPath` drop the `/private`.
- View controllers run without a window: `BrowserViewController`, `ColumnBrowserViewController` and
  `BrowserWindowController` (two panes) all load, select and run commands headless.
- If a check you broke on purpose still passes, `touch` the file and run again: the build can miss quick edits.

### Isolation

- Saved-state storage defaults to a temporary context with a throwaway key in every build configuration, release-mode
  tests included; only `main.swift` opts into application storage, before creating services. Tests inject
  `SecureStorage.Context` for independent stores and never use application storage or the real keychain. Keep
  authenticated store names relative to the injected root, and keep the owning History instance through Undo/Redo.
- Preferences default to a private domain until `main.swift` selects the application domain. Inject `Prefs` with a
  named `UserDefaults` suite and its own notification center, keep the suite alive through persistence checks, and
  remove only that suite afterward. App-owned settings use the selected defaults; macOS-wide spring loading and
  default-file-manager settings keep their system scope. Defaults registration is process-wide even across named
  suites: keep app fallback values in the typed getters, and use another private suite to test inherited preferences.
- Tests that use the real Trash remove exactly what they put there (`tree.removeFromTrash()`), matching the saved file
  identity: a restored item's old Trash path can be reused by another file, so a historical path alone is not
  ownership, and that reuse needs its own coverage. Keep parked originals alive through cleanup so their identities
  can't be reused before the checks. Never empty, trash or delete a real Trash, even to show it's refused: test the
  decision (`FileOps.canTrash`, `deletionPlan`), and pass `Trash.empty(_:)` a fake folder.
- Never use `NSPasteboard.general` or Strata's own preferences. Inject
  `Clipboard(pasteboard: .withUniqueName(), notifications: NotificationCenter())` into the services; only the
  serialized `ClipboardTests` sets the global `Clipboard.pasteboard`.
- The test SFTP server (`RemoteFilesTests`, macOS's `sftp-server` over a pipe) isn't confined to its folder and can
  reach the whole Mac. Never exercise top-level or escaping deletes against it; use `RecordingBackend`.
- Suites sharing global state (`RemoteRegistry`, `TransferEngine.hooks`) run as one `.serialized` suite, but a
  serialized suite doesn't exclude other suites. Shared fault-injection hooks match only their own fixture's full URL
  (or its unique temporary parent), never a basename; prove an unrelated same-name file stays unchanged while the hook
  is installed. Synchronize hook storage and invoke callbacks after releasing its lock, since resets can overlap
  workers from other suites.

### Timing and concurrency

- Suites run in parallel and CI machines are slower: poll for a condition, never sleep a fixed time, and never compare
  listings of shared folders like `$TMPDIR`. `for _ in 0..<n where !done() { sleep }` skips rather than stops, so it
  only suits a condition that stays true once met. After ⌘Z or ⇧⌘Z, whose steps can pass through the expected state,
  `await FileOps.undoWork?.value` instead (undo and redo work runs there, in order).
- Use continuation signals for asynchronous work that is guaranteed to start: a background polling deadline can expire
  while main-actor tasks are still queued behind other suites. When a negative-path mutation deliberately prevents a
  callback, keep its bounded polling on the request tasks' actor.
- Cache freshness tests inject a clock and advance it explicitly, including expiry boundaries and delayed reads.
- A helper that blocks (a `Process`, a semaphore) runs on a Dispatch queue, never on the main thread or in a
  `@concurrent` function, because other suites' file work waits on those (see `ScratchVolume`, a disk image for moves
  across disks).

### What to assert

- Assert observable results and unchanged fixture files. Use explicit completion signals, deterministic boundary
  fixtures and controlled failures. Avoid wall-clock performance thresholds, exact memory expectations,
  nondeterministic random inputs, and tests that depend on installed apps.
- Synthetic CGEvents set their own modifier flags before conversion to NSEvent (a nil event source can inherit the
  live keyboard's Shift state), and fixture events are never posted to the system queue.
- Measure performance separately under matched conditions; passing tests establish only the cases they exercise.
- Preferences and other dependencies need explicit isolation in every configuration, including optimized test runs.

## Robustness: crashes, input and limits

- A crash fix needs a headless regression that calls the real affected reader, decoder, layout or process helper,
  fails before the fix and passes after it. Keep it in `Tests/StrataTests` so local runs, pull-request CI and Release
  all run it. Regex checks, source-text assertions or tests of a duplicate implementation don't count.
- Run the complete debug suite under Address Sanitizer when changing unsafe memory, parsing, indexing or callback
  lifetimes, in its own build directory:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --sanitize address --scratch-path .build/sanitizers/address --disable-automatic-resolution --jobs 4`.
  Locally, add `--no-parallel` for the full AppKit suite so hundreds of native window fixtures don't overlap; tests that
  coordinate concurrent requests still run their own tasks together. Investigate sanitizer diagnostics instead of
  suppressing them, retrying until green or skipping tests. Sanitizers don't instrument prebuilt system frameworks or
  prove unexecuted paths safe.
- Apple's Undefined Behavior Sanitizer covers C-based languages, not Swift; accepting the flag is no evidence of Swift
  coverage. `CArchivePreview` and the standalone `StrataArchiveWorker` are C targets: exercise their real parser
  callbacks under Address and Undefined Behavior Sanitizer when changing them.
- Treat file contents, authenticated saved data, process output and macOS callback values as external input.
  Validate array shapes, offsets, counts, parent/child links and cycles before indexing or walking them. Check CF type
  IDs before casts, and finite values and representable ranges before numeric conversion. Test empty, truncated,
  malformed, minimum/maximum and just-over-limit inputs alongside valid ones.
- Authentication doesn't prove a saved structure is valid. Keep valid neighboring records when records are
  independent; reject an invalid linked structure as a whole through its existing recovery path. Never salvage
  unauthenticated bytes, or overwrite the saved file just because a read failed. Test older supported formats,
  preservation of valid records, and byte-for-byte preservation of the input file, with real writer → save → reopen
  tests, not only hand-built fixtures; validation must include context the writer adds, such as titles and filenames
  in content-search token counts.
- Apply byte, nesting, entry and output limits before allocation or expansion; a time budget can't interrupt one
  expensive library call. Test limits with bounded fixtures on either side of the boundary, never by exhausting the
  machine's memory. For files that could be replaced while opening, inspect the opened descriptor and reject nonregular
  input before reading, as `TextFile.readPrefix` does.
- Register C callbacks such as `atexit` from a nonisolated function when the system may call them on another thread:
  a closure created in a MainActor context can assert at runtime even if its body is thread-safe. Include process
  shutdown when validating lifecycle changes.
- Use throwing Foundation I/O APIs: Swift `do`/`catch` doesn't catch Objective-C exceptions from older ones. Keep
  streaming semantics when replacing an API, covering short pipe output while the writer stays open, read failures and
  EOF. A failed read never reports partial output as success; a partial preview shows its error and keeps the rows
  already read.
- Pipes the app writes to suppress `SIGPIPE` on their own descriptor before use (`F_SETNOSIGPIPE`): a child can close
  its input after a connection check, and a throwing write alone doesn't prevent termination. Test the real transport
  with a closed-reader fixture, and keep the signal policy local to its descriptor.
- A closed `QLPreviewView` can't accept another item. `QuickLookPreviewView` owns the native view for one window
  lifetime, rejects late completions after closing, and creates a new native view when moved to another window. Cover
  deferred selection work and the rich-preview fallback after closing with a controlled scheduler.

## Checking the real app

Prefer headless tests. When a GUI check is needed: the debug build has the same bundle ID as an installed Strata, so
AppleScript `set frontmost` and keystrokes can land in the user's own copy. Activate the debug build by process ID
(`NSRunningApplication(processIdentifier:)` from JXA), confirm it's frontmost, then post CGEvents; read a confirmation
sheet's text before clicking a destructive button. Both builds share preferences: put back anything you change (view
mode, sidebar mode, last location).

## Code style

- Swift 6 with `defaultIsolation(MainActor)` and `NonisolatedNonsendingByDefault`. Disk and network work runs in
  `@concurrent` functions or `nonisolated` types. Keep the Swift 6.3 hop workaround in `Package.swift`.
- Follow Clean Code (Robert C. Martin): intention-revealing names, small functions that do one thing, explicit
  dependencies instead of hidden global state, no duplication, no dead code, and errors handled where they occur.
  Where this file is more specific, it wins.
- Comment only what the code can't say: a decision that isn't obvious, or why something deliberately differs. Never
  write a comment that restates a name or the code beside it, doc comments on new properties and functions included.
  Use plain sentences in the app's own words (Trash, Put Back, Delete Immediately).

## Commits and releases

- Subject: `Area: what changed, in the user's terms` (e.g. "Transfers: two items with one name never replace each
  other"). Body: what was wrong, what changed, and what the tests cover.
- Release: write `docs/release-notes/X.Y.Z.md` ("Strata X.Y.Z adds … and fixes …", then `## New` / `## Fixed` items
  with a bold first sentence), commit "Release notes X.Y.Z", push `main`, then
  `git tag vX.Y.Z && git push origin vX.Y.Z`. Watch the Release, CI and Translations workflows.

- Adding or bumping a package dependency updates `THIRD_PARTY_NOTICES.md` at its pinned version; a Python check fails
  otherwise.

## Hunting bugs

When a report gives steps, list every place they could run before saying it doesn't reproduce: each view (List, Icons,
Columns and its deeper columns, Gallery, Disk Usage), search results, Recents and Duplicates, both panes, both sidebar
modes, and the shape of the selection. A bug can live in just one of them, such as deleting from a deeper column.
