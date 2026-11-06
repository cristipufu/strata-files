# Folder and archive previews

Space opens a temporary preview of the selection without changing the originating browser's folder, selection,
scroll position or view mode. Folders and archives expose a list or thumbnail grid; selecting a child previews it
alongside the contents. Filtering and sorting affect the preview alone. Escape closes it and restores source focus;
editable text keeps its normal keys.

## Ownership and commands

The preview uses the originating `BrowserServices` environment: settings, providers, clipboard, thumbnails and file
commands remain with that owner. `PreviewCoordinator` owns the window and session. Replacing the selection,
navigating or closing the source pane, or closing the preview cancels its work and rejects late completions.
Pending work keeps the source pane weakly.

Preview navigation is read-only. Open, Show in Strata, Copy, Copy Path and extraction are explicit actions on
captured items. File-editing commands and file Undo cannot fall through to the browser behind the panel; normal
text selection and Copy remain available. Deferred commands verify their session and file identity before acting.
A preview never starts a recursive index scan or changes browser view settings.

Local listings are bounded before allocating native rows. Provider previews list metadata first and fetch only a
selected file through the owning provider. Opening or copying a folder is an explicit operation. Replacing a
command waits for its predecessor to finish; repeated commands can retain an existing shared file read.
Cancellation releases only the preview's request.

## Archives

Listings, selective reads and extraction use the sandboxed archive service and its workers described in
[Reading archives in a sandbox](archive-sandbox.md). Merely listing an archive never invokes full extraction.
Partial or unsupported listings keep an explanation visible. Copying from a Space preview requires a complete
listing, validated member paths and an owned export destination.

Single-entry exports use bounded streams and private scratch files. The cache reserves the whole export size before
writing the first byte. File and parent identities prevent replacement paths or links from redirecting exports or
cleanup. Cancelling a password request dismisses its own sheet before another selection or command can ask again.

## Size measurements

Logical size and size on disk remain distinct. Recursive folder measurement is explicit and cancellable, does not
follow links, and reports a lower bound when some contents are unavailable. Listing a folder or changing the preview
mode does not begin a recursive size calculation. Provider folders retain their provider's measurement policy.

## HTML documents

HTML, HTM and XHTML use an offline WebKit preview with a Preview / Source switch and an explicit Open in Browser
command. Templates such as Vue, Svelte and PHP remain source previews. `WebPreviewView` owns reattachment and
shutdown; `PreviewWebPage` owns one WebKit lifetime. A closed lifetime cannot receive late resources or content.

The renderer uses a nonpersistent data store, disables document JavaScript and blocks network requests independently
of the document's Content Security Policy. Forms, downloads, embedded pages, popups, file pickers and automatic
redirects are refused. WebKit receives a private document scheme rather than file URLs or broad filesystem access.
Local CSS and bounded raster images are read through no-follow descriptors in the selected document's folder.
Provider and archive previews do not fetch surrounding assets automatically.

Input is limited to 512 KiB. Assets allow 32 distinct attempts and 8 MiB in total, including conversion; CSS is limited
to 256 KiB and image input to 4 MiB. Images share a sixteen-million-pixel budget and are reduced to at most 2,048 pixels
on an edge. A WebKit lifetime also limits repeated requests and total response bytes. Unsupported or oversized HTML
uses bounded Source rather than unrestricted Quick Look. A page that has not started displaying within eight seconds
switches to Source; an already displayed page may finish loading its allowed assets.

## Layout and appearance

The initial content size is 1,000 × 640 points, with 40% for browsing and 60% for the selected item's preview.
`PreviewLayout` validates saved sizes and fits them to the source display. `PreviewSplitViewController` retains native
divider interaction and remembers intentional changes. Display fitting does not overwrite the user's saved size.
A single-file preview temporarily fills the window without changing the remembered folder split.

Name absorbs available list width. Size stays visible; Date Modified and Kind appear when enough space remains.
Metadata columns retain manual widths. Theme changes recolor existing views without replacing content or selection.
Backgrounds use `ThemeStyle`, file cells use their owner's typography and native controls retain macOS styling.

## Regression coverage

The preview suites exercise native dispatch across the browser's views and both panes, held and reordered reads,
window and renderer teardown, captured commands, sparse sizes, provider ownership, archive paths and streams,
password replacement, and owned scratch cleanup. HTML tests use real WebKit and a loopback positive control to
verify network refusal. Layout and theme tests render native headless views. Tests use isolated preferences,
clipboards, storage and providers; they do not activate or drive the installed app.

File-changing paths and their mutation coverage are maintained in
[Destructive actions and their tests](destructive-actions.md).
