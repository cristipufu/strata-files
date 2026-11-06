# Memory measurements

The benchmarks below compare the original policies at `8cad325` with the optimized implementations, using the
same fixtures and compiler settings. Measurements from 19 October 2026 are medians of three fresh processes on an
Apple silicon Mac (macOS 26.7.1, Apple Swift 6.4 / Xcode 27.1, build 27A9275), in MiB (1,048,576 bytes).
They describe the measured workloads, not a promised reduction for every running Strata instance.

Run `scripts/benchmark-memory.sh semantic 50000`. The benchmark compiles production code with optimization and
`DEBUG` storage isolation, uses an encrypted synthetic version-3 index, and checks an exact content-search result.
It never reads the app's index or Keychain. The fixture builder's freed allocations are returned before measuring;
the load measurement includes allocations made by the normal reader. The script repeats each workload three times.

## 1. Disabled sentence embeddings allocate no vector storage

The default content index uses word vectors and keyword scoring, but it also grew and zeroed a 512-element Float16
sentence row for every passage. A disabled sentence matrix now has zero dimensions. Enabled sentence embeddings,
the encrypted store format, word vectors, passage text, keyword statistics and search behavior stay the same.

| 50,000 passages, sentence embeddings off | Before | After |
| --- | ---: | ---: |
| Process footprint after loading | 295.42 MiB | 159.99 MiB |
| Footprint increase from immediately before loading | 285.98 MiB | 150.59 MiB |
| Reserved sentence-vector capacity | 80.00 MiB | 0.00 MiB |
| Reserved word-vector capacity | 55.00 MiB | 40.00 MiB |
| Load time | 461 ms | 440 ms |

The measured load-footprint reduction is **135.39 MiB (47.3%)**. Load-footprint increases ranged from
285.72–287.56 MiB before and 150.58–150.70 MiB after. Removing the sentence allocations also changes array growth
and allocator reuse; the observed process saving is larger than the eliminated matrix's reserved capacity.

Validation: exact keyword hit and snippet, disabled vectors on load/refresh/row reuse, enabled vectors preserved,
encrypted save/reopen, forgetting exactly one document, and reset.

## 2. Thumbnails stay within a decoded-image budget

The previous shared NSCache had a 400 MiB soft cost limit. The cache now evicts the least recently used images before
crossing 128 MiB or 1,500 entries, and clears on memory-pressure warnings. Visible views retain their own images;
evicting a cache entry does not remove an image from the screen. Quick Look size/scale buckets, request coalescing,
cancellation and image quality stay the same. A cropped image is charged for its original decoded backing.

Run `scripts/benchmark-memory.sh thumbnails-baseline 160` and `scripts/benchmark-memory.sh thumbnails 160`.
The baseline reproduces main 8cad325's NSCache policy. Both runs generate the same 160 distinct, heap-backed,
1024 × 1024 RGBA thumbnails (4 MiB each) without retaining them outside the cache. They use the app's default actor
isolation. These workloads measure decoded image retention, not Quick Look generation or whole-app memory.

| 160 generated Retina thumbnails | Before | After |
| --- | ---: | ---: |
| Images retained | 100 | 32 |
| Process footprint increase | 408.64 MiB | 135.41 MiB |
| Time to generate and cache all images | 276 ms | 285 ms |

The measured reduction is **273.23 MiB (66.9%)** for this cache-filling workload. Before/after footprint increases
varied by less than 0.04 MiB across three runs. A smaller cache can regenerate more thumbnails when revisiting older
folders; it does not reduce thumbnail resolution. The fill-time ranges overlap (272–322 ms before, 282–314 ms after).

Validation: deterministic eviction and recency, replacements, oversized entries, count limit, releasing offscreen
images while visible images remain usable, coalesced requests, last-reader cancellation, ignoring stale completions,
regeneration with identical pixels, fallback size buckets, changed files, failed/cancelled requests and cropped backing
cost.

## 3. Loading reserves room for the first burst of index changes

Previously, loading an index allocated its columns at their saved count. A burst of additions could then allocate
larger buffers and copy the old columns, raising memory and update time. For columns with at least 4,096 elements,
the reader now reserves 12.5% growth room, with a minimum of 1,024 elements and a cap of 16 MiB per column.
It initializes and saves only the actual count.
Untouched capacity costs virtual address space; this workload's initial process footprint rises by just 0.05 MiB.
Growth beyond that reserve can still require resizing.

Run `scripts/benchmark-memory.sh index-growth-comparison 1000000`. A separate process builds one encrypted synthetic
fixture, then three pairs of fresh processes load it and add the same 8,192 files. The baseline compiles the reader
from main 8cad325; both readers use current, identical store and encryption code. Separate processes prevent the
fixture builder's freed buffers from favoring one allocation size. Only this synthetic comparison uses a public
fixed key in a temporary compiler input; the app's key handling is unchanged.

| One-million-file index, then 8,192 additions | Before | After |
| --- | ---: | ---: |
| Footprint increase after loading | 107.58 MiB | 107.63 MiB |
| Footprint increase after the burst | 153.47 MiB | 108.56 MiB |
| Additional footprint during the burst | 45.89 MiB | 0.94 MiB |
| Peak resident memory | 162.55 MiB | 117.63 MiB |
| Load time | 22.7 ms | 21.7 ms |
| Burst update time | 4.53 ms | 1.70 ms |

The measured post-burst saving is **44.91 MiB (29.3%)**; burst-related growth falls by **98.0%**. Across three pairs,
the post-burst increase was 153.45–153.47 MiB before and 108.56 MiB after. These are separate workloads from the
document-index and thumbnail measurements, so their savings must not be added into a whole-app estimate.

Validation: all eleven column buffers stay at the same addresses through a real append/integration burst; original
and added items retain sizes, timestamps, file identities, hidden/link flags and folder totals after save/reopen.
Saving a freshly loaded index produces identical decrypted version-6 bytes, proving spare capacity is neither read
nor serialized as file entries.
