# Performance regressions and their guards

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
