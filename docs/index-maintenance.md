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
