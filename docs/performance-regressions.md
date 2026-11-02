# Performance regressions and their guards

Foundation is Apple's built-in framework for common facilities such as file reading and data buffers. The memory
measurements below use standalone developer benchmarks; they do not represent the app's complete memory footprint.

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
