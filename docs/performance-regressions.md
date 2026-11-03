# Performance regressions and their guards

Foundation is Apple's built-in framework for common facilities such as file reading and data buffers. The memory
measurements below use standalone developer benchmarks; they do not represent the app's complete memory footprint.

## Toolbar startup and search layout (#33)

`01b6149` added per-pane address bars, hiding the toolbar's location item when both panes show their own. Window
startup still attached the toolbar before restoring its frame or creating the second pane. The location item
therefore entered AppKit's first layout as visible and was hidden afterward. This ordering predates the optional
toolbar contributions in #20 and #34. Saved display mode was also applied after the initial items were inserted.

The window now establishes its frame and panes before attaching the toolbar, and applies display mode before
attachment. Saved item order is applied immediately afterward: AppKit ignores `itemIdentifiers` before attachment.
Preference observation starts last, so initial default items do not replace saved choices.

`ToolbarStartupTests` observes actual native item insertions and checks location visibility for both address-bar
settings, initial display mode, retained customization and unchanged fresh preferences. Both startup regressions
failed before the fix. The exact search expansion reported on the 2560-point display was not reproduced on the
available system; these checks guard the demonstrated initialization defects, not every adaptive layout
decision AppKit makes.

## Application icons

`94e54e8` moved per-file icons off the main thread. Its new placeholder inferred a package from the filename's
type, but macOS classifies the `app` extension as an application file, not a package. App directories consequently
showed folder placeholders. Its completion also reused the broad row-refresh handler, rebuilding unrelated visible
cells and refreshing cached hidden presentations. Later refactoring preserved those behaviors.

The fix uses the listing's content type, recognizes application directories when metadata is unavailable, and reads
applications' individual icons. List icon arrivals update existing cells; other active presentations refresh only
affected items. Hidden Columns defers its refresh until shown. Git, tags and fetched-file refreshes also stay with
the active presentation.

`IconLoadingTests` covers application placeholders, unchanged unrelated images, retained native cells, editing and
selection, and hidden Columns catching up on reattachment. All three `Icon refresh` mutations were caught. The
earlier test checked eventual icon delivery, but did not cover bundle placeholders or native view retention.

## Duplicate scanning

Both the full-file hash loop and the per-size-group UI task were present in `afe394c`, the initial commit. The move
to `PaneSearch` in `2a5b751` preserved them; this was an existing defect, not introduced by that extraction.
Foundation's read buffers were autoreleased only after the whole scan, so hashing many gigabytes could retain as
much temporary memory as the files read. Cancellation was checked between groups and files, but not while collecting
candidates or hashing an individual large file. The pane also retained its untracked scan until it finished.

The fix drains buffers per chunk, checks cancellation throughout the work, and keeps the read on its own thread.
The pane owns and cancels its task; pending work holds the pane weakly. Progress keeps only the newest update and
reaches the UI at most five times a second, without clearing or rebuilding the results view on each update.

An optimized standalone run of the actual duplicate finder on two 128 MiB sparse files found the same group and
reclaimable bytes before and after the change. Maximum resident memory fell from 276,873,216 to 10,256,384 bytes;
elapsed time was 0.19 and 0.15 seconds. This measures temporary hashing work, not the app's full index or UI footprint.

`DuplicateFinderTests` covers filtering, cancellation without matching sizes, cancellation between hash chunks,
unchanged SHA-256 digests, equal ends with different middles, hard links, and pane release/replacement while the
index is held. The `Duplicates` mutations remove the cancellation and ownership guards to check those regressions.

## Duplicate locations in the sidebar

The initial `afe394c` sidebar selected the first matching destination, without remembering which section was
clicked. When a location also appeared in Frequent, navigation or a sidebar rebuild selected the earlier Frequent
row. Section extraction in `d923568` retained this policy.

The sidebar now remembers the chosen section and destination together, restores that occurrence after rebuilding,
and falls back to a visible match if its section is collapsed. Programmatic selection and rebuilding do not navigate.
`SidebarSelectionTests` uses a native outline with the same folder in Locations and Frequent, chooses both
occurrences, rebuilds, navigates elsewhere and back, and collapses/reopens the chosen section.

## Background progress and event bursts

Compare's per-2,000-item UI task came with `0720cd1`; container events' per-event main-queue block came with
`cb250c3`; semantic indexing's per-file UI task was in the initial `afe394c`. Coalescing after hopping to the UI
did not bound the callbacks waiting to get there. These were original implementation gaps, not new behavior from
the later module or controller extractions. Semantic indexing also let an old completion clear a restarted request.

`LatestUpdate` keeps one pending value and schedules one delivery before crossing to the main actor. Duplicates,
Compare, container events and semantic indexing use it. Each request cancels its bridge on replacement, completion
or closure. Semantic indexing has an injected request owner, and rechecks ownership after callbacks that can start
a replacement. Summary streams retain only their newest complete snapshot rather than every intermediate snapshot.

`LatestUpdateTests` holds delivery while publishing 10,000 updates and exercises concurrent publishers, cancellation,
finishing and release. `BackgroundUpdateTests` exercises the real Compare controller, container event watcher and
semantic request owner with held readers, including late updates, callback capture release and reentrant completion.

The callback audit also checked the paths below; their existing sampling or coalescing remains in place:

| Path | Delivery |
| --- | --- |
| Local and server transfers, archive jobs | Worker counters sampled by the queue every 250 ms |
| Direct folder search | One owned polling loop, 400–1,000 ms between reads |
| File index scan | Progress timer every 500 ms; change notifications coalesced |
| Git status | Batched FSEvents, one status reader and one pending refresh per repository |
| Folder watchers | Coalesced Dispatch sources and a debounced refresh |
| Thumbnails and media metadata | Four active readers, coalesced requests and stale-result guards |
| Server session results | A one-element result stream per waiting request |

## Other streaming read buffers

The same Foundation read ownership appeared in encrypted storage in `afe394c`, Compare in `0720cd1`, SFTP upload
in `3ab928c`, and archive-tool progress in `33e70a8`. These implementations predated the later refactoring.
Their loop-local Swift values did not release Foundation's additional autoreleased ownership per iteration.

`FileRead.chunk` now owns that boundary for these loops and the duplicate finder. It preserves the returned bytes,
EOF and throwing read errors, and rejects negative lengths before entering Foundation. Existing size validation,
opened-file checks, cancellation and write destinations stay with their callers.

`FileReadTests` injects a real native autoreleased lifetime probe alongside the file read and verifies release after
each chunk, inside an outer pool. Removing the inner pool fails this test without memory or timing thresholds.
It also checks retained bytes after later reads and handle closure, EOF, errors and multi-chunk encrypted input
preservation. The SFTP upload regression verifies complete bytes, dates and unchanged neighboring files.

Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 scripts/benchmark-streaming.py` to compile the
production helper and compare it with direct reads on the same workload. A 256 MiB run reported 263.6 MiB peak RSS
for direct reads and 8.6 MiB for chunk-owned reads, with identical SHA-256 digests. Results vary by system; this is
a separate measurement, not a CI memory threshold. A separate 256 MiB write experiment stayed around 9 MB RSS, so
the read ownership correction was not applied to the write paths.

## Disk-image cleanup fixture

The final full debug run exposed four assertions in one scratch-volume cleanup test. The mounted volume had gone,
but DiskImages still listed its backing image, so the helper correctly refused to remove the image's folder. The
mounted-path detach was already present in `469d3d0`; `7f84a86` added publication settling but retained that target.

The fixture now resolves the image's partition-scheme disk through its mounted filesystem. It requires the image
to be a regular file in the owned folder, verifies that the attachment record names that mount, and rechecks the
opened mount's device and filesystem identity before detaching. A missing or mismatched record refuses cleanup.
The pure mapping regression covers unrelated images, different mounts and missing records; the native test still
checks that the running disk stays attached and a symlink cannot redirect cleanup. This changes test infrastructure.
All seven fixture tests passed in debug and under Address Sanitizer. Disabling the mount-to-image guard failed the
mapping regression, after which the original source was restored.

## Validation of the first six fixes — 2 November 2026

- Full debug suite: 1,596 tests in 214 suites passed.
- Full Address Sanitizer suite: 1,596 tests in 214 suites passed, including native disk-image cleanup.
- Python checks: all 99 passed.
- Main-thread, app-wide ownership, destructive-action and theme audits passed; all localization catalogs are complete.
- Fifteen distinct negative controls were caught across the fixes, including the native read-pool lifetime and
  disk-image ownership guards. The duplicate-owner control was checked again after adopting the shared update helper.
- Optimized app and helper products built successfully. No package dependencies changed.

These checks cover the reported defects and the audited paths above. They do not establish that every path in the
app is free of bugs or performance limits.

## Inspector refreshes

The Where flicker came from `56b6c20`: it made Finder's name and icon asynchronous but retained a comparison of the
loaded name with a fresh row's stored filename. Applications with no selection shows the disk root, whose Finder
name differs from its initial path component. App extensions, colon names and localized folders can differ too.
Every metadata refresh then replaced the loaded row with a placeholder. The comparison now uses the requested
folder, path and explicit presentation overrides, preserving the loaded view while updating its selection action.

The review also found that `8532439` kept a separate array of requested rows. `InspectorRows` could retain a visible
row while that array held its discarded replacement. Adding image dimensions used the replacement and changed
Where again. Dimension updates now use the rows actually displayed; the duplicate array is gone.

Four native regressions cover repeated refreshes after names and icons load, text and click-action updates, genuine
location changes, and dimension insertion after a refresh. Both reported replacement paths failed before their
fixes. The retained-view checks include the disk root, a fixture app and a colon-named folder. Seventy Inspector,
icon, Columns, Gallery, thumbnail, Open With and Quick Look tests pass in debug and under Address Sanitizer. The
existing provider-name mutation was updated, and a new mutation restores the loaded-name comparison.

The related-view review checked Columns' cached thumbnail/dimension updates, Gallery's same-item preview refresh,
the Inspector's icon-only notifications, and the Project, Compose, container and Summary cards' change guards.
Those paths do not compare a loaded Finder name with a placeholder to decide view identity. Thumbnail images are
bounded by a 128 MiB/1,500-image cache, path icons by 4,000 entries, and path display names by 5,000 entries.

Read-only measurements of dev PID 14593 during the active session showed 2.5–20.4% CPU across five two-second
intervals, about 756–905 MiB physical footprint, and a 1.0 GiB peak. A separate three-second sample reported 912 MiB;
most main-thread samples were waiting for events. The VM summary showed roughly 605 MiB allocated on the default
heap, but does not attribute those allocations to app features or establish a leak. These are observations of an
interactive session, not a controlled idle-memory benchmark.

## Folder look cache ownership

`fd1f1c6` introduced the shared `FinderLooks` reads. Evicting a folder later removed only its completed value; an
in-flight read could finish after navigation and cache it again. Multiple waiters also independently cleared the
request and published the value, allowing an old waiter to clear or overwrite a replacement.

Each read now has an identity. Eviction detaches the request before cancelling it, and only the current request may
clear its slot or cache its result. Completed values stay limited to the folders the Inspector currently retains.
Already-cancelled callers start no read, and active callers still share one request. The reader is injected so tests
can hold I/O without real disks or LaunchServices. A held-read regression failed before the fix; further tests
exercise leaving and reopening a folder in both completion orders, coalescing and cancellation. The request-identity
guard has a negative-control entry. Both mutations for the preceding Where fix were also caught.

The complete debug and Address Sanitizer suites each passed 1,603 tests in 215 suites after these changes. All 99
Python checks, the four architecture audits and complete localization checks also passed.

The runtime index contains 7,186,592 records: its ten fixed-width columns alone occupy about 267 MiB, before names
and spare capacity. The replacement dev process (37566) measured 640 MiB in its first 30-second sample, then about
950–969 MiB during and after the user's browsing, previews and search, with a 1.1 GiB peak. These observations are
not a controlled before/after memory comparison. The interactive 45-second trace had the main thread waiting for
events in about 96% of samples and no watchdog stalls recorded within that interval. The log did record a 422 ms
startup stall and a separate 589 ms stall before that trace, without a matching sampled stack. CPU reached 70–99%
after the run; the trace's sustained work was a deep index refresh on its background queue. Builds and tests were
also producing filesystem changes. The refresh coverage defect found in that investigation is described below.
The earlier unmatched stalls still lack a sampled stack; the Where fixes alone do not establish that this workload
is now fully smooth.

## Overlapping index refreshes

The live trace prompted a review of deep-refresh batching. The initial implementation in `afe394c` recorded the
event's path as covered before resolving it to an indexed folder. After a deletion, several stale paths can resolve
to the same surviving parent. A mixed batch of ordinary deletion and deep-refresh events then rescans that parent
and its subtree repeatedly. The exact live event batch was not recorded, so this defect cannot be assigned all of
the CPU observed in that session.

Coverage now records the folder actually refreshed, after a complete deep read. Failed or cancelled reads do not
suppress later events, and a newly scanned subtree is conservatively left uncovered because that scanner does not
report unreadable folders. A folder's coverage includes itself and descendants with a path-component boundary.

The injected directory reader counts real production reads. The deletion regression failed before the fix: the
parent and an unrelated subtree were each read twice, and a deeper folder three times. They are now each read once.
Further regressions verify that a failed ancestor read still permits later child updates and that `a` never covers
its sibling `ab`. Saved indexes retain the expected deletions, updated file sizes and unrelated files. All 77 focused
index and search tests pass. Three negative controls target coverage identity, failed reads and sibling boundaries.
The final full Address Sanitizer run passed all 1,606 tests in 215 suites. All 99 Python checks, all four architecture
audits, and localization extraction and completeness checks passed. The optimized app product also built successfully.
All three index mutations were caught, completing six caught negative controls across the Inspector follow-up fixes.

## Storage measurements

The size discrepancy was caused by different definitions, rather than a new terabyte of disk use. Folder sizing
and the index summed logical file lengths, including sparse regions. OrbStack's `data.img.raw` had a logical length
of 994.66 GB while its allocated blocks occupied about 79 GB when checked. The Disk Usage chart included only the
visible entries; the user's hidden `Library` folder was absent. The footer showed macOS's availability for important
usage, which includes reclaimable space, rather than physically free space.

The Inspector now leads with Size on disk and keeps Logical size below it. Local Disk Usage tiles use allocated
bytes and the legend explicitly says visible items. Servers and archives retain logical sizes because the local
placeholder or extracted copy is not their storage allocation. Unknown allocation stays unknown; unreadable,
excluded and unvisited folders never become measured zeroes. Partial folder measurements retain the known allocated
bytes and show “+” as a lower bound, with an explanation beside the measurement. A folder's own unread state is distinct from unknown
descendant sizes, so a child update cannot accidentally mark an unread parent complete. Shared or cloned data can
still count toward multiple files: these totals are not a promise of uniquely reclaimable space.

The footer now shows physically free space; its tooltip separates actual occupied space, total capacity, free space
and availability including reclaimable space. Volume reads remain asynchronous, follow the folder actually listed,
reject obsolete results and coalesce event-driven refreshes with an injected five-second clock. Selection aggregation
has its own cancellable reader, off the main actor, and never retains a closed Inspector or publishes an older total.

Allocation is read with each listing, bulk scan and fallback folder walk. It remains separate from logical lengths
used by transfers and search. Index cache format 7 uses a separate filename, so a side-by-side older app cannot
overwrite it. Fixed-width index storage rises from 39 to 48 bytes per record, before names and spare capacity; this
costs about 62 MiB for the observed 7.2 million records. A first launch rebuilds the disposable index.

Regressions exercise a real sparse 1 TiB fixture with only one small data write, listing and tree-walk agreement,
scan → save → reopen → compact, allocation-only updates, missing allocation and recovery, late selection totals,
Inspector teardown, and arriving chart totals that must retain the chosen measurement. The fixtures never read the
sparse file's contents or allocate its logical length. These checks establish the cases exercised; they do not prove
the unique physical contribution of APFS clones or unreadable folders.

Validation passed: a full debug run of 1,616 tests, 47 final focused tests after the presentation review, the complete
Address Sanitizer suite with all 1,617 tests, all 99 Python checks, the four architecture audits and complete
localization checks. Five new negative controls cover allocation parsing, unread parents, chart updates, obsolete
Inspector totals and physical free space; the existing capacity and provider controls follow the refactored code.
All ten new or updated controls were caught, and the source was restored after every deliberate regression.

## Trash permissions and system apps

The live Blenny check moved only `/Applications/Blenny.app` to Trash, then used Strata's native Undo and verified the
restored device, inode and birth time against the original. The user also reported that Steam moved successfully.
Chess is a different case: this Mac's `/System/Applications/Chess.app` is restricted and belongs to the sealed,
read-only system volume. An administrator prompt cannot permit that removal. Apple's [uninstall guidance](https://support.apple.com/en-ie/102610)
also distinguishes protected system apps from ordinary installed apps.

Strata previously passed the OS's generic failure through to its alert, without distinguishing read-only volumes.
`RemovalVolume` now reads that policy away from the UI and produces a specific reason. Trash validates the whole
chosen batch before moving anything, including creation Undo and owned transfer/History Undo. Permanent-deletion
planning retains the reason for its refusal. Removing a symlink checks its parent's volume, so a writable link to a
protected system item remains removable. No system app was modified in this investigation.

The new headless regressions inject volume facts and use only throwaway files. They cover a protected last item in a
mixed batch, unchanged siblings, no partial History/Undo registration, ownership filtering, symlink targets, deletion
planning and the real native error alert. The original Topaz authorization failure remains unverified: that app had
already been removed with Finder. These results do not establish support for every administrator-only deletion or
Empty Trash failure.

Validation passed: 163 focused tests in both debug and Address Sanitizer, all 99 Python checks, the architecture
audits and complete localization checks. The native alert is checked headlessly. Six new negative controls exercise
batch refusal, synchronous creation Undo, owned Undo, link handling, deletion planning and the alert's explanation;
three existing ownership controls follow the refactored code.
All nine controls were caught, and the source was restored after every deliberate regression.

## SFTP disconnect during a write

CI on macOS 26 exposed an uncaught `NSFileHandleOperationException` while a background download sent an SFTP
request after its fixture closed the client. `SFTPClient` serialized writes with a lock, but `close()` closed the
same `FileHandle` independently. Foundation's throwing write still reads the handle's descriptor and can raise an
Objective-C exception when it has already closed. Suppressing `SIGPIPE` protects against the server closing its
end, not this lifetime race. The same independent write/close paths are present in the shipped `v0.7.5` source.

`SFTPInput` now owns packet serialization and handle lifetime. Disconnect immediately refuses queued writes, leaves
an active writer's handle open, and closes it exactly once when that write returns or throws. It never waits for
the writer's lock, so the client can end the child process and unblock a full pipe. Reader exit and explicit close
share one client cleanup path; only the first close ends the process. Failed sends close the session and release
its remaining waiters. The diagnostic signal-policy value is captured while the handle is open.

`SFTPInputTests` holds writes at an injected boundary and checks both successful and failed writes, queued refusal,
repeated close, and release of an unused input. The fake handle callbacks make lifecycle regressions fail without
deliberately invoking a native exception. Existing real-process SFTP and remote-file suites exercise the integrated
transport, including a peer that closes its input. These tests use temporary files and no live server.

## Text preview wrapping (#35)

The shipped 0.7.5 code deliberately used an unbounded text container and horizontal scrolling. Wrapping is a new
display option, enabled by default, rather than a repair to an unreleased refactoring regression. A preview's Wrap
Lines control saves its choice through the owning settings, supplied through a small model interface so the preview
library never depends on the application's preferences type. Changes are scoped to that settings owner and do not
reload the file or replace its text storage.

Wrapped containers follow the available width, including the native gutter inset. The gutter labels only each
document line's first visual fragment. Layout stays noncontiguous and background layout is disabled; the existing
512 KiB read limit and 2,000-character line limit remain. Hidden previews defer setting changes until shown.

Headless native checks cover text, source and JSON, Unicode, long unbroken lines, real control actions, persisted
horizontal scrolling, resize, retained selection and a single source read, lazy offscreen layout, and Space and
Inspector settings ownership. The renderer-retirement check also changes wrapping after a native failure, so the
new setting cannot reactivate the retired renderer.

## Optimized release compilation

The first 0.8.0 release attempt passed its normal suite, then failed while Swift 6.3.3 imported `FolderSizer` into
the optimized file module: its deinitializer was isolated but the imported class was not recognized as actor-isolated.
Commit `44e458e` introduced that cleanup while fixing obsolete folder measurements; 0.7.5 had no such deinitializer.
The newer local Swift 6.4.2 toolchain accepted it. The affected standalone owners now explicitly name `MainActor`
on their declarations, preserving the isolation and cancellation they already required. Native view subclasses
continue to inherit their actor from AppKit. A held folder-size read verifies that releasing its owner still
cancels active work, rather than dropping cleanup to make compilation pass.

Regular CI now runs the complete optimized suite with its pinned Xcode, alongside normal and sanitizer jobs, so
release-only compilation errors are checked before a tag. The Release workflow retains all three suites.


## Installed Mermaid preview crash (#36)

The reporter supplied a 45-byte Markdown file containing only `flowchart TD` and `north --> api`, and a crash report
for 0.8.0 build 45. Its executable UUID matches the published app. The stack is a Swift assertion in SwiftPM's
generated `Bundle.module` accessor, reached by `MermaidRenderer.script`; it is not a TextKit exception or a Chinese
text failure. The release contains the Mermaid bundle under `Contents/Resources`, but the shipping SwiftPM accessor
looks at the app root and then an absolute build-machine path. A checkout's build output hides that mismatch, and
newer local SwiftPM versions generate a different accessor that also checks `resourceURL`.

`ResourceBundle` now resolves packaged resources explicitly and throws when they are missing. Apps never borrow a
resource bundle from a sibling or the checkout. Themes use the same resolver and retain their System fallback;
a missing Mermaid script leaves the fenced source visible. The native TextKit protections in `7d0de6b` address
separate failure paths and did not fix this runtime trap.

The build now checks resource discovery after packaging, using a headless checker staged with only the app's actual
resource bundles. It loads the themes and renders the reporter's diagram through the production loader and Mermaid
renderer. Tests also omit each bundle and the script: these paths must exit with a normal failure, without a Swift
trap, even while build output exists on the test machine. The checker is a build tool and is not shipped in Strata.


## Native document extraction boundaries

Summaries and content indexing used Swift `try?` around rich-text importers and called PDFKit directly. Those calls
handled ordinary Cocoa errors but did not catch native exceptions. `CNativeReaders` now owns the native imports and
one PDF reader per extraction. A failed or cancelled PDF reader drops its document and refuses subsequent reads;
page loops check their caller's cancellation before advancing. Errors keep the existing unreadable-document path.

PDF input is checked through its opened descriptor, including regular-file and byte limits, and read in cancellable
64 KiB chunks with per-chunk autorelease ownership. Native text output is bounded without splitting composed
characters. OCR continues one page at a time; each thumbnail is decoded into an owned bitmap inside the boundary,
limited to 2,200 pixels per side, so releasing the PDF never leaves deferred decoding for the UI or OCR caller.
The existing Unicode title policy is preserved, and an exactly fitting document is not marked as truncated.

Headless tests exercise real RTF/PDF extraction, unchanged source bytes, controlled native exceptions, terminal reader
state, cancellation before another page, unexpected page counts, output boundaries and raster ownership after reader
release. The rich-text failure fixture catches an escaped exception itself, so breaking the production boundary
reports a test failure without intentionally crashing a process. These boundaries handle Objective-C exceptions;
native memory faults and native decoder expansion still require process isolation for a complete crash boundary.


## Shared image-reader boundaries

Image metadata, preview thumbnails and HTML image re-encoding previously called ImageIO directly from several Swift
readers; Mermaid also let `NSImage(data:)` defer decoding until native drawing. `CNativeReaders` now owns these calls,
catches Objective-C exceptions locally and retires a failed image reader. It copies bounded decoded pixels before
returning to AppKit or OCR, preserving RGB colour spaces. Preview byte, source-pixel, frame and output limits remain
with their callers, including HTML's per-document pixel and byte accounting.

Metadata remains a header read without the small preview byte limit. Its file source pins one non-following regular-file
descriptor, uses bounded positional reads instead of memory mapping and reports a file truncated during reading as an
error. Media rotation and EXIF capture dates/camera names retain their existing policies. OCR prepares its image through
the same boundary, observing the extraction byte limit and cancellation, with a 120-megapixel source ceiling and a
4,096-pixel raster side limit; unusually large images may be skipped or reduced before recognition.

Regression tests cover real PNG/JPEG decoding, rotated metadata, camera dates, colour spaces, encoded output,
reader release and failure, regular-file restrictions, descriptor ownership, truncation and ordinary/cancelled OCR.
Controlled per-reader failures avoid global framework replacements. These are exception and resource boundaries inside
the app, not process isolation: they cannot contain native memory faults or enforce a timeout inside a framework call.


## Whole-document Markdown work limits

The source-byte and per-table limits did not bound the total number of parsed nodes, native tables/cells or formatting
runs. A small file could contain many individually valid tables or alternate inline styles thousands of times.
Each parse now owns one budget shared by quotes and lists; each render owns a fresh budget for its document. Named
policies cap 4,096 structural nodes, 128 tables, 4,096 table cells, 16,384 formatting runs, 8,192 decorated lines and
1,048,576 rendered UTF-16 units. A native inline parse or syntax-highlighting pass takes at most 32,768 UTF-16 units;
longer code fences retain their text without highlighting. Existing Mermaid source/diagram limits remain separate.

Exhaustion switches the whole preview to selectable, searchable source and labels the footer “Source”. It preserves
all text that the existing 512 KiB file read returned, without retaining partially built tables or starting diagrams.
Tables beyond 20 columns or 200 rows also use this source fallback instead of silently dropping extra data. Other
native read/render failures still use the existing error message; cancellation propagates without becoming a fallback.
Source mode uses lazy layout, while rich Markdown retains its native layout policy. The native storage-installation
boundary switches that policy with its document, turning lazy layout off only after the old storage has been replaced.

Tests exercise parser and renderer boundaries, shared nested budgets, real inline/code formatting, table limits,
normal rich rendering, source drawing/search/Unicode, unchanged files, cancellation, document replacement and the
packaged Mermaid reproducer. Work counts bound these paths; they are not a universal time or memory guarantee for
prebuilt macOS frameworks.
