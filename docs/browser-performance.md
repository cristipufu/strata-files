# Native browser measurements

Run `python3 scripts/benchmark-browser.py` from the checkout. The default is an optimized build, 10,000 synthetic
entries (5% folders, 95% small text files), three runs each of List and Icons, a 1000 × 700 point viewport, and generic
icons. `--entries 100000`, `--runs 5` and `--configuration debug` change those conditions. `--output /path/to/new-folder`
keeps the JSON, test log and crash diagnostics at a chosen location. Otherwise the script prints a temporary result
directory. It does not activate, drive or restart an installed Strata.

`--scenario resort` measures the metadata-driven native row-reordering path separately. It loads the same synthetic
folder in List, draws it, selects an item, then reverses name ordering through `resortAfterMetadata` and draws again.
Its timed interval includes sorting, updating native rows and drawing. It checks that native rows match the model
and that the selected file stays selected. This is a controlled large-permutation workload, not a measurement of
metadata I/O or a claim that normal metadata changes reverse every row. Results record the revision, configuration,
OS, core count, power and thermal state. For example:

```sh
python3 scripts/benchmark-browser.py --scenario resort --entries 10000 --runs 3 --configuration debug
```

The opt-in `BrowserPerformanceMeasurements` fixture uses the real directory reader, browser controller and native
views. Every sample creates independent preferences, encrypted storage, credentials, providers and a private
pasteboard. Source files live only in a temporary fixture. The benchmark is disabled during ordinary correctness
test runs; the wrapper explicitly enables it.

- **First native frame:** navigation starts the timer. The real folder read, sorting, view installation, native layout
  and bitmap drawing of the viewport must finish before it stops. The fixture requires the correct entry count and
  materialized native rows/items. Read completion alone is insufficient.
- **Scroll frames:** 60 deterministic viewport jumps down and back through the folder, each followed by native layout
  and drawing, with 16 milliseconds between samples. The report contains every duration, and the summary shows p95.
- **Main actor delay:** a 16 millisecond heartbeat records how late the main actor answers during loading and scrolling.
  It includes synchronous UI work and scheduling delays; it does not identify their cause.
- **Idle CPU:** after scrolling and 500 milliseconds to settle, process user + system CPU time is sampled for two seconds.
  100% means one logical core. Unfinished background work contributes to this measurement.
- **Memory:** physical footprint before navigation and after idle, and the process resident high-water mark. Peak RSS
  includes the test host, setup and earlier samples; it cannot be attributed to an individual view or reset between
  runs. Each repeated benchmark invocation starts a fresh process.

These are offscreen AppKit frames, not measurements of the display compositor, input hardware, trackpad scrolling or
user-perceived on-screen latency. Fixture generation warms filesystem caches. Generic text-file icons do not represent
image thumbnail generation, Applications, remote volumes or mixed media. Results are methodology baselines, not a
promise about every workload. JSON includes revision, build configuration, macOS, processor count, memory, power mode
and thermal state, plus each native bitmap's pixel dimensions. Keep those conditions, fixture sizes and viewport fixed when comparing revisions; use a quiet
machine and compare several independent invocations. Debug and sanitizer results are not release performance targets.

Progressive directory loading needs a separate decision based on these measurements and representative manual or
Instruments traces. A faster partial listing must preserve ordering, selection, refresh ownership and cancellation.

## Initial measurements, 5 November 2026

On this 14-core Apple silicon Mac, macOS 26.7.2, Xcode 27.2, nominal thermal state and Low Power Mode off, the initial
optimized 10,000-entry run (three samples per mode, app code at `70a045d` plus the measurement fixture) gave:

| Mode | First native frame, median | Scroll draw, p95 | Largest main actor delay | Idle CPU, median | Process peak RSS |
|---|---:|---:|---:|---:|---:|
| List | 1,021 ms | 22.3 ms | 182 ms | 0.36% | 170 MiB |
| Icons | 1,048 ms | 22.5 ms | 216 ms | 0.26% | 238 MiB |

Those are baseline measurements before the path-key improvement. A separate sampled trace found repeated lexical
path normalization in `BrowserListing.replace` and `rebuildIndex`. Fresh listings looked up old nodes despite reuse
being disabled. Entries now capture that same normalized key once when the immutable snapshot is made, and the listing
uses it without repeating the normalization. No path comparison rules changed.

A matched debug run with 10,000 entries and one sample per mode observed the largest main actor delay fall from
283 to 135 ms in List and 293 to 161 ms in Icons. First native frame fell from 1,181 to 1,122 ms and 1,187 to 1,078 ms
respectively. One paired run does not establish a stable performance target, and debug values cannot be substituted
for the optimized baseline. Remaining first-frame and actor delay costs need representative profiles before selecting
a larger loading change. These observations justify removing redundant work; they do not establish that progressive
loading is the next best change.

## Follow-up profiling, 6 November 2026

The optimized 10,000-entry browsing baseline at `25034e4` (three runs per mode) recorded first-frame medians of
949 ms in List and 984 ms in Icons, largest main actor delays of 92 ms and 118 ms, and scroll-draw p95 of about 22 ms
in both modes. A separate 12-second sample of this workload showed `TagStore.load` repeating lexical URL
normalization for every entry. Bulk tag preparation now uses each entry's existing location key. Cache keys, tag
invalidation and read ownership are unchanged; injected-reader tests cover private-path aliases, dot components,
Unicode and escaped filenames.

The new reordering scenario found a larger cost: the previous metadata pass searched the full working array even for
rows already in place and could ask AppKit to animate thousands of moves. For 10,000 entries, the initial debug
sample took 6,891 ms. After the change, three debug samples had a median of 54 ms. These measurements are from the
same machine and scenario; the one-sample baseline does not establish a stable release performance ratio.

`BrowserRowMoves` validates a complete identity permutation before native updates, skips rows already in place and
plans at most 64 moves. Larger changes use one native reload, preserving expanded folders and exact selection.
Inactive List views do not animate while Icons, Gallery or another presentation is active. Unchanged orders do no
native work. Tests exercise all small permutations, invalid identities, the animation limit, a 10,000-row change,
and materialized native List, Icons and Gallery views. Loosening the limit by one makes the boundary test fail.

The matched optimized browsing follow-up (three samples per mode, same viewport, OS, core count, nominal thermal
state and Low Power Mode off) measured:

| Measurement | Before | After |
|---|---:|---:|
| List: largest main actor delay | 92.0 ms | 37.7 ms |
| Icons: largest main actor delay | 117.8 ms | 53.4 ms |
| List: median first native frame | 949 ms | 937 ms |
| Icons: median first native frame | 984 ms | 946 ms |

Scroll-draw p95 stayed around 22–23 ms; these samples do not establish a scrolling improvement. Idle CPU remained
below 0.5% of one core. Process peak RSS was 169 MiB for List samples and 235 MiB after Icons, compared with 171 MiB
and 244 MiB before. These are whole-test-process high-water marks, not per-view allocations or installed-app memory.
