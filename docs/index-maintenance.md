# Index maintenance

File events are aggregated into folder refreshes as they arrive, bounded to 4,096 folders between deliveries to
the index worker.

## Lost events

When macOS reports that events were lost, the index rebuilds; a loss is never treated as an ordinary file change.
The reports come while a burst of changes is still going, and a rebuild then would compete with whatever is making
the changes and be out of date as soon as it ended. So the rebuild waits until ten seconds pass without another
report, and is forced ten minutes after the first when they never stop. Meanwhile the events that do arrive are
applied as usual, the index reports itself as updating, and it is not saved: quitting leaves the earlier file,
which the next launch replays from. Trees that wait for quiet are left alone, since the rebuild reads them.
Reports that arrive during the rebuild start the same wait again. A loss during the replay at launch is the
exception and rebuilds at once, since a scan is faster than waiting out a broken replay.

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
