# Reading archives in a sandbox

Strata lets you look inside archives without extracting them: open a ZIP, a tar, a 7z or RAR, a Windows cabinet or
OneNote package, an EPUB or a comic book, preview what's in it, and copy just the parts you want. Those archives come
from anywhere, and the code that reads them, macOS's libarchive, is a large C library. If a crafted archive ever found a
bug in it, that bug must not be able to reach your files.

So Strata doesn't read archives itself. Listing one in the preview pane, looking inside it with Space, copying items
out of it, checking it before Extract and Extract itself all happen in a separate worker process that runs in an App
Sandbox, lives for exactly one read, and can be stopped the moment it isn't needed. The worker can't write a file, so
for Extract it sends what it read and Strata writes the files, checking everything it's sent. This page explains how
that works and why it ended up this way.

## Where we started

Space previews already ran each read in its own process. Strata started a small worker for it, handed it the archive
as an open file, and read its output through a pipe. The worker locked itself down at startup with `sandbox_init` and
a profile that denied almost everything: no files, no network, no other programs. The preview pane's listing and the
check before Extract were another story: they ran macOS's `tar` and `zipinfo` with your access and parsed their text
output, and Extract ran `tar` with your access too.

It worked well, but it rested on an API Apple deprecated back in macOS 10.8, with the note "No longer supported". The
compiler warned about it on every build, and the macOS 27 SDK goes further: processes that opt into those profiles
"will be killed". Silencing the warning would only have postponed the day archive previews stopped working.

## What Apple recommends

Apple's supported way to confine code is App Sandbox: an entitlement in the code signature, enforced by the system from
the moment the process starts. And for giving one part of an app a sandbox of its own, Apple's answer is an XPC service:

> Each XPC service has its own sandbox, so XPC services can make it easier to implement proper privilege separation.

The same guide is just as clear about the alternative we had been using: helpers started with `NSTask` or `posix_spawn`
"do not let you put each part of the application in its own sandbox".

There's one more piece of the puzzle. A sandboxed process can start helper processes, and they inherit its sandbox.
Apple documents how to sign such a helper: with the App Sandbox entitlement and `com.apple.security.inherit`, nothing
else.

## The design

Strata combines the two. The archive service is an XPC service inside the app, with an App Sandbox of its own. It never
reads an archive. For each read it starts a worker, a small helper inside its bundle that inherits the service's
sandbox, reads one archive and exits.

```
Strata.app
└── Contents/XPCServices/StrataArchiveService.xpc      the archive service (App Sandbox)
    └── Contents/Helpers/StrataArchiveWorker           one worker per read (inherits the sandbox)
```

In the source tree, the service is `Sources/StrataArchiveService`, the worker `Sources/StrataArchiveWorker` with the
parser in `Sources/CArchivePreview`, and the app side `Sources/StrataArchiveClient`, used by `PreviewArchiveReader`.
What the service and its workers share, their statuses and the sandbox check, is `Sources/CArchiveSandbox`: the service
links only that, so the parser isn't even in its process.

### A read, step by step

1. **The app** opens the archive, checks it's the file you chose, and makes two pipes: one already holding the request,
   one for the output. It sends the service a single message carrying the three descriptors. The request names what to
   read and, for an encrypted archive, the password. Because it holds the password, it's built in memory that is wiped
   when released, and it never appears in a message, an argument or a log.
2. **The service** starts the worker with exactly those three descriptors: the request as standard input, the archive
   as descriptor 3, the output pipe as standard output. The worker gets nothing else from the service.
3. **The worker** sets its limits, reads the request, lists the archive or streams the chosen file, or for Extract
   every entry, into the output pipe, and exits. Its exit status is the result: done, wrong password, too large, unsafe
   paths, unreadable.
4. **The service** passes that status back to the app.
5. **The app** reads the output as it arrives and accepts only the worker's own length-prefixed records, at most 60 MB
   except for Extract's and a copy of one file out of Space, for its preview or an export. That copy, up to 256 MB,
   goes to its file as it comes, never more of it in memory than a chunk: the worker allows it only for a request that
   streams one file, and for a preview the app takes the file's whole size from the preview cache before writing its
   first byte.

**Listing.** A listing that reaches 50,000 entries or 60 MB of records ends with a mark saying there's more, and one
stopped by its time or by an unsafe entry keeps the rows it read: the preview pane shows them with a note saying why.
A Space preview, which copies from its listing, refuses an archive it can't list completely.

**Checking before Extract.** Before Extract unpacks an archive, or opens it as a folder, a worker counts what it
holds: its entries, the size of its files, and whether any entry is encrypted. It sends no listing, so none of a
preview's limits on how much it reads or lists apply, only the worker's own CPU, memory and time. It reports its
totals as it goes, so a check cut short still gives lower bounds: if even those don't fit on the disk, Extract
refuses, and a large total still asks before opening the archive as a folder.

**Extracting.** For Extract, and for opening an archive as a folder, the worker sends every entry `tar` would write: its
name, contents, permissions, times and Mac metadata, which goes back on its items, including the metadata a zip keeps in
its `__MACOSX` folder. Only a zip's directory tells that metadata from the zip's own items: a damaged zip that can be
read only from the start comes with the folder as entries, as `tar` writes it, and nothing is left out. Strata writes
the entries into a private folder on the destination's disk, and trusts none of it, as if the worker had been
compromised:

- each record is checked before anything is made from it: a name that climbs out, an empty or overlong one, one more
  than 128 folders deep (as in previews), an unknown kind or a malformed field ends the extraction;
- every item is made relative to a folder Strata opened, one name at a time, never following a link, so nothing is
  ever written through one, and never over another item: a second entry with a taken name, file or folder, gets a
  number, the way Finder numbers a copy, and what's inside a numbered folder follows it;
- on a disk that keeps an item's extended attributes in "._name" beside it (exFAT, FAT, some shares), no item meets
  its partner there ("._x" and "x", in either order, of any kind): made over a "._x", "x" would have the system take
  it over or remove it, and a "._x" beside "x" would be taken for x's attributes, which the check that follows leaves
  to the system, so the one that would meet the other gets a number, as on a taken name, and no hard link is made to
  the system's "._x". A "._" item without its partner, or a "._" file's own "._._" one, is the archive's own and is
  checked like any other;
- permissions stay within what a new folder gets there, without setuid, setgid or sticky bits, as `tar` restores them
  for you; times come back as `tar` sets them;
- Mac metadata (resource forks, Finder info, extended attributes) goes back as `copyfile` puts it back, except access
  lists. The worker reads it from the AppleDouble form archives keep it in, refusing what `copyfile` refuses, so Strata
  never parses it;
- it stops when the disk runs low on space, as the watchdog around `tar` did: it counts every item it makes, the
  folders an entry implies included, as at least a block of that disk, reads the free space again before what it
  counted could use up the reserve, and checks before writing anything large.

What's written then goes through the checks it always went through before being put in place: links must stay inside
it, special files go, and the archive's quarantine goes on everything. Those checks read every name in the folder
itself, files named "._…" included, which `FileManager` leaves out, except on a disk that keeps extended attributes in
"._" files beside its items (exFAT, FAT): those are the system's. Extract's worker has no 25-second deadline and no
CPU limit, since both grow with the archive, and up to 4 GB of memory, for the largest dictionaries archivers use; Stop
ends it like any other read.

Stopping a read is just as direct. When you close a preview or move on, when the app's 20-second timeout passes, or
when the output grows past its limit, the app stops reading and asks the service to end the worker, which it does on
the spot. The app waits for the service to confirm before it starts another read, so a stopped read never leaves a
worker running, and Strata's two reads at a time are two workers at most.

## What keeps a read contained

**The sandbox.** The worker can't open your files, reach the network or use devices. It can read the system's own files
and the service's container, a folder macOS creates for every sandboxed program.

**Its own limits.** Each worker:

- can't start other programs (the sandbox would allow it, and libarchive can call external decompressors for a few
  formats);
- gets 15 seconds of CPU time, 256 MB of memory, 32 open files and no core dumps (Extract's: no CPU limit and 4 GB). The
  service starts it with no signal blocked: its own threads, like all Dispatch threads, block asynchronous signals, and
  a worker that inherited that mask would never receive the kernel's SIGXCPU at its CPU limit;
- has 25 seconds in all, after which the service ends it (Extract's reads as long as the archive takes);
- reads only the archive it was handed, and its only output is its pipe: its file size limit is zero, so it can't
  put a byte into any file. It reads every format libarchive reads but one, mtree: that's a manifest, not an archive,
  and its reader takes each entry's contents from the file the entry names, which would let a "manifest" read any
  file the worker can, instead of the archive. One kind of zip it reads twice: macOS's libarchive refuses an intact zip
  with an item of its own in `__MACOSX` when it reads Mac metadata (after its check that no two items overlap, it tests
  the wrong variable), and Finder extracts it. The worker reads such a zip again without Mac metadata, before it has
  sent anything, unless the first read stopped at its limits: its items come as they are stored, its "._" files too, and
  the overlap check still runs. Copying one item out of such a zip takes a full Extract, which keeps its Mac metadata in
  those "._" files.

**No system services.** App Sandbox lets every sandboxed program look up some system services through `launchd`, and a
few could carry data out: we measured that a worker could reach the pasteboard and LaunchServices, which opens URLs. A
worker needs no service once it has checked its own signature, so before it reads anything it clears its bootstrap
port and gives up every right to `launchd`'s. After that, every lookup fails, through `launchd` or XPC. The worker
confirms that no right is left and refuses to read otherwise. Its other send rights stay, but none of them is
`launchd`'s: a process holds one name per port, and that name is gone. This is plain Mach, not something Apple
documents as part of App Sandbox, so the tests keep checking it: a worker that kept its bootstrap port would refuse
every read.

**One process per read.** If an archive did find a bug in the parser, whatever it achieved ends with that read's
process: the next archive gets a fresh worker, with no memory, open file or process of the last one. The one thing all
workers share is the service's container, where a compromised worker could leave small traces (empty files, links,
extended attributes) for a later compromised one; nothing outside the container. Strata runs up to two reads at once,
each in its own worker.

**Refusing to run unconfined.** The service and the worker both check their own signature for the App Sandbox
entitlement when they start, and refuse to read anything without it. A packaging mistake shows up as an error, never as
a parser running unconfined, and the build fails before such an app could ship. A worker started any other way than by
the sandboxed service doesn't get that far: signed to inherit a sandbox, it is stopped by macOS at launch (we
checked; no test does it on every run, since each such crash leaves a crash report).

## Why a worker per read

A simpler design would have the XPC service read the archives itself. It's tempting, and we tried it. It runs into
three problems.

**A stuck read can only be stopped by ending the whole service.** Some archives make the parser spend a long time inside
a single library call, like a small file that unpacks to something enormous. A service can't interrupt its own thread
halfway through one, so the only way out is to end the service.

**Ending a service is slow to undo.** XPC services are started by `launchd`, and `launchd` holds back a program that
ends soon after starting. From its manual: "by default, jobs will not be spawned more than once every 10 seconds. The
principle behind this is that jobs should linger around just in case they are needed again." We measured it: a service
that ended after each read came back only after 10 seconds every time, and one that was killed repeatedly didn't come
back within three minutes. That rules out a fresh service per read, too.

**Reads would share everything.** Memory one read leaves behind counts against the next, CPU time piles up on threads
the service reuses, and a parser that one archive compromised would still be there for the next one, along with its
password.

Workers avoid all three. They're the service's own child processes, not `launchd` jobs, so ending one is instant and
costs nothing; the service itself only starts workers, so it never needs to end. Starting a worker takes about 10
milliseconds. The first read after the service starts takes about 300.

## Other paths we didn't take

**Keeping `sandbox_init`.** Chromium still calls private variants of it, because it found no replacement that fit.
OpenSSH builds without its macOS sandbox, and mandoc removed its own. For us it would have meant living with a warning
until the SDK broke it.

**A helper with an App Sandbox of its own,** started by Strata directly. Apple's support engineers describe it: sign the
helper with App Sandbox but without `inherit`, and it gets a sandbox of its own. It worked, except that on our
development Mac the helper died at launch whenever Strata itself was inside `~/Documents` ("Failed to create a code
identity", `EPERM`). The XPC service and its workers start from `~/Documents` like anywhere else.

## Signing

`scripts/archive-service.sh` lays out the service inside an app and signs from the inside out:

1. the worker, with `ArchiveWorker.entitlements`: App Sandbox and `com.apple.security.inherit`, and nothing else, as
   Apple's guide for helper tools requires;
2. the service, with `ArchiveService.entitlements`: App Sandbox only.

It fails unless each signature carries exactly those entitlements. `scripts/build.sh` runs it, then signs the app
around it. The service's bundle identifier is `dev.strata.app.ArchiveService` in the builds Strata distributes, and
`dev.strata.app.local.ArchiveService` in any other: macOS ties a sandbox container to the signature that made it, and
a build signed another way, such as a contributor's ad hoc build, could take over an installed Strata's container.

## Testing

An XPC service has to live inside an app, and `swift test` isn't one. So the tests build one. Suites that read
archives use the `.archiveWorkerApp` trait, which builds `StrataArchiveHarness.app` around the freshly built service
and worker with the same `scripts/archive-service.sh`. Its small host forwards each request through the same client
code the app uses, so every archive test runs the real sandboxed service and worker, laid out and signed as they ship.

macOS gives every sandboxed program a container the first time it runs, and keeps it: a command-line process can
empty a container but can't remove its record. So the test services use two fixed identifiers,
`dev.strata.tests.ArchiveService` and `dev.strata.tests.ArchiveService.NoWorker` (for a worker signed without its
entitlements): a Mac gets those two containers once, and since the services and workers write nothing, they hold only
the empty folders macOS creates.

Tests can lower the worker's limits, but never raise them. That lets them stop a read at its CPU or memory limit on
purpose, then show the next read in the same service works. They also check that a service or worker signed without its
entitlements refuses to read. The parser's callbacks also run under Address and Undefined Behavior Sanitizer.

## What it doesn't do

App Sandbox is broader than the old deny-everything profile. A worker can still read system files and the service's
container, leave empty files, links and extended attributes there, open the few device interfaces App Sandbox allows,
send signals to processes in the same sandbox (the service and other workers, so a compromised worker could end other
reads), and keep using the send rights it took while starting. Dropping its bootstrap port closes the system services
it could otherwise look up, such as the pasteboard. What it can't do is reach your documents, the network or other
services, start other programs or put data into a file, and no process it runs outlives the read. That's the trade we
made for building on the mechanism Apple supports.

For Extract, a compromised worker could still decide what the extracted files hold, as the archive itself could, and
make Strata refuse the archive. It can't make Strata write anywhere but the extraction's private folder, through a
link or over anything, and what it sends is checked again before it's put in place.

## How this compares with Apple's tools

Apple moves archive work out of the apps that ask for it too, but not the same way.

| | Strata | Apple |
|---|---|---|
| Previews | Space reads each member through a fresh sandboxed worker | Quick Look preview extensions run in a sandbox with no network, by design [1, 2] |
| Looking inside an archive | The preview pane, Space and copying out all read through a fresh worker per read, which can't look up system services | Finder doesn't look inside archives: double-clicking one hands it to Archive Utility to unpack [3] |
| Unpacking | Extract reads through a fresh worker too, and Strata writes what it sends, checking every item | Archive Utility hands the unpacking to separate helper processes, an ArchiveService and a SandboxedServiceRunner [3] |

We couldn't find how tightly Archive Utility's helpers are confined, but its history shows where unpacking goes wrong:
quarantine lost on long paths, which let an unsigned app skip Gatekeeper (CVE-2021-1810) [3, 4]; a helper holding Full
Disk Access that accepted any caller [5]; and Archive Utility itself having "nearly unrestricted filesystem access"
until macOS 26.4 (CVE-2026-28910) [6]. None of those were bugs in reading the archive: they were in what happens around
it, the permissions of the process doing the work and the attributes of what it writes.

So the parsing side here follows what Apple does for Quick Look, and adds a fresh process for every read and no system
services at all. The writing side is where Archive Utility's bugs were, and it gets its own care: Strata, never the
worker, writes what an archive holds, never through a link or over another item, keeps the archive's quarantine on all
of it, and refuses links that lead out, special files and unsafe paths.

## References

- Apple: [Creating XPC Services](https://developer.apple.com/library/mac/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html)
- Apple: [Embedding a helper tool in a sandboxed app](https://developer.apple.com/tutorials/data/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app.md)
- Apple Developer Forums: [Resolving App Sandbox Inheritance Problems](https://developer.apple.com/forums/thread/706390)
- `man launchd.plist` (ThrottleInterval) and `man sandbox_init`
- OpenSSH: [sandbox.h is deprecated](https://lists.mindrot.org/pipermail/openssh-unix-dev/2026-August/042690.html)
  and [mandoc's decision](https://lists.mindrot.org/pipermail/openssh-unix-dev/2026-August/042695.html)
- Chromium: [Mac Sandbox V2 design](https://chromium.googlesource.com/chromium/src/+/HEAD/sandbox/mac/seatbelt_sandbox_design.md)
- [1] Apple Developer Forums: [Sandbox: ExternalQuickLook deny network-outbound](https://developer.apple.com/forums/thread/701940)
- [2] QuickGPX, a Quick Look extension: [notes on the `quicklook-preview.sb` profile](https://github.com/nst/quickgpx)
- [3] F-Secure: [Analysis of CVE-2021-1810 Gatekeeper bypass](https://blog.f-secure.com/analysis-of-cve-2021-1810-gatekeeper-bypass)
- [4] Jamf Threat Labs: [macOS Archive Utility vulnerability](https://www.jamf.com/blog/jamf-threat-labs-macos-archive-utility-vulnerability/)
- [5] [macOS AUHelperService Full TCC Bypass](https://jhftss.github.io/macOS-AUHelperService-Full-TCC-Bypass)
- [6] Mysk: [CVE-2026-28910: Breaking macOS App Sandbox Data Containers, TCC, and Hijacking Apps Using Archive Utility](https://mysk.blog/2026/05/19/cve-2026-28910/)
