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
