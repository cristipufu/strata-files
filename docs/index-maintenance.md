# Index maintenance

File events are aggregated into folder refreshes as they arrive, bounded to 4,096 folders between deliveries to
the index worker.

## The journal the index follows

The saved index records how far its events had got and which journal that position belongs to: macOS keeps one
journal per volume and gives it a new identity whenever it starts over, as after an unclean shutdown, a restore or
an erased disk. What changed since a position can only be asked of the journal that recorded it. A volume without a
journal answers with nothing, and a journal that replaced another holds nothing from before it; either way the
system says the history is complete. So at launch the index replays what changed while Strata was not running only
when every watched folder's volume still keeps the journal the index was saved with, and scans everything
otherwise. Recovering lost events makes the same check before it replays.

A change of the saved format starts a new file, which the first launch fills with a scan. The file of the format
before it stays, so an older copy of Strata running beside this one keeps its index; files of formats older than
that are removed with the temporary files their saves left behind.

## Lost events

When macOS reports that events were lost, what was delivered is not everything that changed; a loss is never
treated as an ordinary file change. The reports come while a burst of changes is still going, and recovering then
would compete with whatever is making the changes and be out of date as soon as it ended. So recovery waits until
ten seconds pass without another report, and is forced ten minutes after the first when they never stop. Meanwhile
the events that do arrive are applied as usual, the index reports itself as updating, and it is not saved: quitting
leaves the earlier file, which the next launch replays from. Trees that wait for quiet are left alone, since the
recovery covers them.

Recovery replays the system's journal. The event stream starts over from a point the index had reached at least a
minute before the first report arrived: a loss begins before it is reported, and events arrive slightly out of
order. Where the stream itself last started, at launch or with a scan, is such a point however recent it is, since
it precedes everything the stream delivers. Everything since is delivered again, the lost events with it, and the
folders they name are read; reading a folder twice is harmless. That costs what the changes cost to read, not what
the whole index costs to rebuild. Until the replay has been applied the index counts as complete only as far as the
replay started, and it is saved that way as the replay starts, even when nothing else changed. A report that
arrived while the index was busy is dealt with before recovery is decided, so it starts the wait again.

The index is rebuilt instead when the journal cannot be trusted to hold everything: the kernel lost the events
before the system recorded them, the journal is no longer the one the index has been following, the replay loses
events as well (after the same wait), the replay holds more events than a launch replay may, the event stream
cannot be started again, no point from before the loss is still known, or changes are not being watched. A loss
during the replay at launch rebuilds at once, since a scan is faster than waiting out a broken replay. A loss
reported while a rebuild is still scanning waits like any other, and is then replayed from where that scan began.

## Excluded folders

The index leaves out its own state and copies, the folders macOS guards until you open them, and the folders you
exclude in Settings ▸ Search & Index (a hundred at most). One rule says what an excluded folder covers, and the
scan, file events, refreshes and views all ask it: the folder and everything inside it, by whole path components
and without regard to letter case, so on a case-sensitive volume a folder that differs from an excluded one only in
case is left out with it: scans and file events pass it by, and what the index already held of it stays until the
index is rebuilt. A check does not get slower as the list grows.

An excluded folder stays in the index as an entry that was never read, so its parents' allocated sizes read as
incomplete; their logical sizes and file counts simply no longer include it. Views show no size for a folder you
excluded and start no walk of it until you ask (Inspector, Calculate Size). Excluding a folder empties it at once
and compacts the index a second later, so its memory is freed without waiting for a save; edits close together
share one compaction. Every excluded folder is looked at when the list changes and at launch, not only the newly
excluded, since a read cut short at quit can leave entries in a folder that is excluded again.

Taking a folder off the list indexes it again through the folder that holds it: that folder is listed, and a
listing reads the folders the index has never read and does not read into another volume mounted there, as a scan
does not. A folder removed and made again while it was excluded is found the same way, from the nearest folder the
index knows, unless the index has never read that one. A folder whose read a quit cut short is read through at the
next launch. Each is read at the path the index holds for it, since a list can spell a folder in another letter case
than its disk does; a folder still excluded under another spelling, or inside one that took its place in the list,
is not read. The index takes a change to the list as pending before views are told of it, so a folder taken off the
list is the index's own to size, and no view walks it beside the index's read.

Chosen folders are kept by their real paths; a volume that does not answer within two seconds leaves them as they
were spelled, so it never keeps the index from starting. A saved index that names more than 1,024 excluded folders,
or one longer than a path can be, is not one Strata wrote: it is not used, and the folders are scanned again.
Content search keeps its own index and does not follow this list.

## Other volumes

A volume mounted inside a folder the index covers (a network share, a disk image, an external disk mounted in your
home folder) holds another disk's files, or another machine's, and reading them can wait on it for good. The index
leaves such a volume out like a folder you excluded, for as long as it is mounted: a scan does not read into it,
and neither does anything that changes on it, of which the system does tell whoever watches the folder that holds
it. Which volumes are mounted comes from the system's own table, read without asking any volume anything, so one
that stopped answering is left out like any other. The table names a volume by where it is now, also after a folder
above it was renamed.

Only the index's worker reads that table: when it starts, with each configuration it is given, each time changes
arrive, and before it reads what waited to be read, so before anything is read. A volume mounted since is left out
at once: what the index held of the folder it now covers goes, and nothing on it is read. The folder of one that is
gone is read again like a folder taken off the excluded list, unless you excluded it yourself. Each time, the
worker says which volumes are mounted, and views take what is on one for another disk's and measure it as they
measure those. With the index off no worker has looked, so a search of a folder reads the table itself.

## The index turned off

Settings ▸ Search & Index ▸ Index files turns the whole index off: nothing is indexed, watched or kept. Its worker
ends for good, the way it stops at quit: a scan or refresh under way gives up, the event stream ends, the index is
let go from memory, and last the saved index is removed with its stale temporaries, on the worker's own queue, so no
save of that worker's can bring it back. Only that file goes: the previous format's stays for an older copy of Strata,
and the content index keeps its own, though its background gathering stops while the index is off, since nothing
shows its matches. What a retired worker still reports is not taken: each worker's results are told apart by the
run they belong to. Turning the index on again starts a new worker only once the old one has ended, so the two are
never held together and the new one never loads the file the old one is about to remove; it then scans everything.
A folder that does not answer holds none of this up (see below). Launching with the index off removes an index
saved by a run in which it was on, and starts no worker. The switch acts even when the preference already says so,
as one changed by another copy of Strata does.

With the index off, folders it would cover show no size until you ask (the Inspector, Calculate Size), since every
size shown would be a walk of its own; Disk Usage is asking, so it measures. A folder that holds one macOS guards
and you haven't opened, as your home folder does without Full Disk Access, is not walked for the size views show
(the list, icons, Disk Usage, the Inspector), with the index on or off: the index sizes it without opening those
folders, and a walk could not. A search of a folder reads
the folder, leaving out what the index would: the folders macOS guards until you open them, Strata's own, and those
you excluded, unless the search is inside one. Search across the Mac, Recents and Duplicates say that they need the
index, with a button that opens the setting. When the switch changes, every pane's search starts over at once, and a
folder read on the other side of the switch is let go, still reading or not. The search field searches the folder
shown.

## Folders that are only in the cloud

A folder kept by a cloud provider (iCloud Drive, or one under `~/Library/CloudStorage`) can be on the Mac in name
only: its contents are with the provider until something opens it. Reading such a folder makes macOS ask the
provider to fetch it, and waits for as long as that takes. The index never does that. The threads that read for it
are told not to fetch (`IOPOL_MATERIALIZE_DATALESS_FILES_OFF`, for those threads alone), so a folder that is only in
the cloud says so at once and stays in the index as an entry that was never read, like any folder that could not be
read. Files that are only in the cloud are listed like any other, by the folder that holds them: listing a folder
that is on the Mac fetches nothing.

A folder never read is read whole at its first change, whatever the change names, since everything else in it is as
new to the index: so a folder that is on the Mac at last, because you opened it in Strata or elsewhere, is read by
the change that says so. If it still cannot be listed, the items the change names are read by themselves, and it
stays unread. A folder the index did read, and which is later only in the cloud again, keeps what was read of it.
A listing of a folder tries the folders in it that were never read, so each folder there that is only in the cloud
costs one read that fails at once.

A folder the index holds without having read anything of it has no total, so views show no size for it and start
no walk of it until you ask (the Inspector, Calculate Size, Disk Usage), as for a folder you excluded: a walk would
have its provider fetch it. While the index applies changes elsewhere it stays that way, so a size you asked for is
not taken back by them; only while everything is read, at a scan, or a change to the excluded list is applied, is it
a folder the index is about to read. The folder that holds it is sized by what was read, and its allocated size
reads as incomplete.

The sizes a list works out for its rows by walking them, for folders outside the index or not yet in it, fetch
nothing either. A row whose cloud badge says its folder is only in the cloud shows no size and starts no walk,
unless its size is known already. The badge and the size have one source (`CloudStore`), so the size follows once
the badge says the folder is here; a walk you asked for fetches what it measures, so the badges of that folder, and
of what is in the folder shown, are read again when its size arrives. A walk that comes to a folder only in the
cloud all the same, its state not read yet or its place none the badge covers, measures nothing of it. One deeper
in a folder is passed over, and the size says it is not of everything; files that are only in the cloud count by
their length, as the folder that holds them lists it.

A size you ask for (the Inspector, Disk Usage) is another matter: its walk fetches what it needs and measures
everything, and is not stopped because the index took the folder over or is busy. It goes on for as long as
whoever asked still wants it: the Inspector until it shows something else or is hidden, Disk Usage until you leave
it, and both until you leave the folder. What it measured stands for as long as the index's own total leaves part
of the folder out, in the row and where rows are sorted by size; once the index has read all of it, the index's
total is the one. Rows sorted by size are ordered by what they show: a row that shows none, as one left until asked
does though the Inspector has measured its folder, is ordered as one that has none. Like every size a walk measured, it is measured again after Strata changes the folder or you
reload. Only a folder the index has not read, or does not hold, is walked: one it has read, and which holds folders
that are only in the cloud, shows the index's total of what is on the Mac, also where you ask.

What a browser's walks measured is kept for every window to use. That browser lets go of its own, never of another
window's, when it leaves a folder having measured many sizes, or closes: never as sizes arrive, since a selection
of more folders than it keeps would then be measured over and over. The window hears once of the sizes that arrive
in a stretch, and only if it shows one of them, so with thousands of folders selected the Inspector goes over the
selection a few times a second, not once for every size.

A search of a folder you ask for, with the index off, reads that folder itself and fetches what it finds there.

## Folders that stop answering

Leaving other volumes alone and never fetching from a provider keep the index away from most reads that could
hang. What is left, a failing disk or a file system that stops answering, can still hold a
read for good: the system call never returns and cannot be interrupted. Every folder the index reads, in a full scan and in a refresh alike,
and every single item, is therefore read through `IndexFolderReads`, on a thread kept for reading, while the index's
own thread waits for it only as long as the read gets somewhere. A read that gets no further for thirty seconds is
given up: the folder stays unread, as one that could not be opened does, and the scan or refresh goes on with the
rest. A long listing counts as getting somewhere with every batch it returns, so a huge folder is never given up for
being large. A full scan hands its folders over a batch at a time, up to thirty-two to one thread, so the handing
over costs it nothing that shows when measured; each folder of a batch has its own patience, and what follows one
given up is read on another thread. An item that does not answer says so of the folder it is in, which is then not
listed in its place.

The thread of a read given up is left where it is. What it finds, if it ever returns, is dropped; until then the
folder and everything inside it are refused at once, so a folder that never answers costs one thread and thirty
seconds once, however often file events or refreshes want it. After that it is a folder whose read failed, like any
other: it is read again when it next changes, or when the index is rebuilt. At most thirty-two reads are given up
at one time by one run of the index; past that a read is waited for, as every read was before, rather than give a
thread away for each. The folders the index is made of, your home folder and Applications, are always waited for:
an index without one of them would take the place of the index that has it.

Told to stop (quitting, the index turned off, a rebuild taking over), a read that can notice does at once, and one
that cannot is left after half a second, however many folders do not answer, so neither quitting nor turning the
index off waits on one. Nothing is held against the folder of a read left that way, which may be slow and no more:
the rebuild that follows reads it, and the read left keeps its thread until it returns. A read runs at the priority
of whoever asked for it. A thread kept for reading ends once nothing has used it for thirty seconds, all but one.

## Trees that wait for quiet

Changes inside a cache, dependency or build folder the index has already read wait for five seconds of quiet,
thirty at most, and are then read together. Other folders continue through the fast tier, and a completed refresh
starts its cooldown at completion.

What waits is narrower than what search leaves out. The Trash, the insides of sealed packages, and folders the
settings keep out of search as a whole, such as `~/Library` with iCloud Drive in it, do not wait. A folder inside
one of them waits only when it is a cache, dependency or build folder by name.

A folder a pass finds for the first time is read by that pass, whatever it is, so nothing is listed without its
total. The index keeps its entries and totals while a tree waits and goes on showing them: a total can trail a busy
tree by the wait. A deep read of a folder leaves the waiting trees below it to their own wait, unless the same pass
reads them whole. Waiting work does not mark the index as updating; released work does, until it is read.

Work that is due joins the pending queue, which owns it from then on and holds the event checkpoint behind it until
it has been read. A read that fails is over, as for any other folder: the folder is read again when it next
changes, and the checkpoint moves past it. Timers run at the index's own background priority. An earlier deadline
replaces a queued one, an obsolete timer cannot act on its successor, and releasing a tree leaves folders in their
cooldown alone. Saving holds the event checkpoint behind unfinished work so the next launch can replay it, and at
quit a tree still waiting is left to that replay. First scans and genuine recovery can still require broad reads.
