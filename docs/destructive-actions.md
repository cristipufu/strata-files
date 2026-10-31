# Destructive actions and their tests

Every way Strata deletes, trashes, moves, renames, overwrites, evicts, or changes the permissions or metadata of
files, on this Mac, on a server, in a container's copy, or in its own stores, with the code that does it and the tests
that cover it (`TestFile/test`, under `Tests/StrataTests`). Each test is proven by a mutation that breaks its rule (see
The proof, below). A change to any of these, or a new one, comes with tests and a row here (see AGENTS.md).

## Delete and the Trash

| Action | Code | Tests |
|---|---|---|
| Move to Trash (⌘⌫, menus, every view) | `BrowserViewController.moveToTrash`, `FileOps.trashInBackground`, `FileOps.canTrash`, `FileOps.isWholeDisk` (each item, where it's trashed) | `TrashUndoTests/onlyTheSelectionGoesAndUndoPutsItBack`, `aLinkGoesToTheTrashNotWhatItPointsTo`; `DeleteScopeTests/aTrashIsNeverTrashedOrDeletedItself`; `SelectionTargetsTests/*` |
| Delete Immediately (⌥⌘⌫) | `deletionPlan`, `deleteAll` | `DeleteTests/*` (selection only, nested, links, odd names, disks, unchangeable folders, locked, already gone); `DeleteScopeTests/aTrashIsNeverTrashedOrDeletedItself` |
| Empty Trash | `Trash.empty`, `Trash.folders` | `DeleteTests/emptyingATrashDeletesWhatsInItAndNothingElse`, `aTrashThatIsALinkIsNeverFollowed`, `aLockedItemInTheTrashIsReportedAndTheRestGo`, `aFolderThatCantBeListedWholeKeepsWhatsInItAndIsReported`, `aTrashThatCantBeOpenedIsReported`, `anItemThatWentMeanwhileIsntAFailureAndHidesNoOther`; `DeleteScopeTests/emptyTrashOnlyEverEmptiesTrashFolders`, `noOtherFolderCountsAsATrash` |
| Put Back | `putBack`, `makeFolders`, `Trash.originalLocations` (the window's History, then Finder's records), `Trash.location`, `FileOps.removeEmptyFolders` | `PutBackTests/*`; `FileCommandOwnershipTests/putBackFindsWhereAnItemCameFromInItsWindowsHistory`; `TrashUndoTests/onlyEmptyFoldersGoWhenTheirItemsDo`, `undoingAPutBackRemovesOnlyTheFoldersItMadeOnceEmpty` |
| Drop on the sidebar's Trash | `SidebarViewController.canTrash` (whole disks from the kernel's mount table, `MountPoints`, which waits on no disk, while dragging), then Move to Trash's `FileOps.isWholeDisk` | `DropTests/theSidebarsTrashTakesOnlyWhatCanBeTrashed`, `trashingRefusesADiskHoweverItsReached` |
| Customizable toolbar file commands | `BrowserToolbar.commands`, `BrowserWindowController.performToolbarCommand`, `toolbarCommandAvailable`, `commandTarget` | `ToolbarCustomizationTests/toolbarTrashKeepsTheActivePanesExactSelectionInEveryViewAndUndoRestoresIt`, `removedAndForeignItemsAndNativeEditingCannotTriggerFileCommands` (both panes, all five views, look-alike neighbors and same-name files elsewhere, immediate focus changes, History Undo, removed/foreign items and native editing); mutations: “Toolbar command ownership” |
| Commands on localized names (every view, results and both panes) | `FileEntry.url`, `BrowserViewController.selectedURLs`; labels use `FileEntry.displayName` | `LocalizedNamesTests/everyViewRenamesTheSelectedURLRatherThanItsTranslatedLabelAndUndoRestoresIt`, `resultsAndBothPanesKeepDifferentItemsWithTheSameLabel`; `SelectionTargetsTests/*` |
| Commands in the combined Applications listing | `ApplicationsFolders`, `DirectoryLoader.load`, `ColumnBrowserViewController.reveal` and `continueReveal`; entries retain physical URLs | `ApplicationsFoldersTests/*` (duplicate names, exact root, both source folders changing, every view, expanded folders, deeper columns, copy to the other pane and rename/undo) |

## Undo and History

| Action | Code | Tests |
|---|---|---|
| ⌘Z / ⇧⌘Z of moves, renames, Move to Trash | `FileOps.registerMoveUndo`, `LandedFiles` | `TrashUndoTests/undoingARenameLeavesAFileSwappedInSince`, `undoAndRedoPressedAtOnceHappenInOrder`, `undoingTwoOperationsAtOnceUndoesBoth`; `AcrossDisksTests/aRenameAcrossDisksUndoesAndRedoes` |
| ⌘Z / ⇧⌘Z of copies, duplicates, move jobs | `TransferUndo.register`, `TransferUndo.perform`, `TransferJob.landed` | `TrashUndoTests/undoingACopyTrashesOnlyItsOwnCopies`, `undoingAMoveJobMovesBackOnlyItsOwnItems`; `TransferTests/replacedItemsKeepTheirOwnershipAcrossTheWorkerHandoff` (replacement ownership through worker completion, native Undo/Redo and persisted History), `retriedCopiesKeepTheirOwnershipAcrossTheWorkerHandoff` (repaired files and folders retain worker ownership through native Undo), `undoingACopyLeavesAFileSwappedInWhileTheJobRan`, `aFileSwappedTheMomentItLandsIsNeverUndone`, `aRenamedFileSwappedTheMomentItLandsIsNeverUndone`; `AcrossDisksTests/aMoveJobAcrossDisksUndoesAndRedoesOnlyItsOwnItems`, `undoAndRedoPressedAtOnceAcrossDisksBothHappenInOrder`, `aFileSwappedTheMomentItLandsAcrossDisksIsNeverUndone` |
| Owned browser file commands | `FileCommands`, `FileOps.rename`, `newFolder`, `newFile`, `registerTrashUndo` | `FileCommandOwnershipTests/*` (independent journals, persisted History, repeated native Undo/Redo, exact targets in every view); `BrowserPreferencesTests/newFileUsesItsOwnExtensionAndTargetInEveryView` |
| ⌘Z of New Folder / New File | `FileOps.registerTrashUndo` | `TrashUndoTests/undoingANewFolderLeavesOneMadeInItsPlace` |
| Undo from History | `OperationLog.undo`, `holdsOriginal`, `FileIdentity.matchesHistory` | `TrashUndoTests/historyUndoBringsBackWhatWasTrashedAndOnlyThat`, `undoLeavesAloneWhatTookTheOldPlace`, `undoNeverMovesBackAnItemThatWasSwappedForAnother`, `undoMovesBackOnlyTheMovedItems`, `historyUndoChecksIdentitiesSavedByOlderVersions`, `HistoryOwnershipTests`, `TransferTests/historyRejectsItemsReplacedBeforeTransferRegistration`, `historyRejectsARenameReplacedBeforeRegistration` |
| History panels retain their store and native Undo manager, and Clear History requires confirmation | `HistoryWindowController.undo`, `clearHistory(after:)` | `HistoryWindowOwnershipTests/*`; mutations: “History window” |
| Saved History pairs have exactly one source and destination before undo can read them | `OperationLog.Entry.init(from:)` | `HistoryDecodingSafetyTests/malformedHistoryPairsAreRejectedBeforeUndo`, `validAndOlderHistoryRecordsKeepTheirPairs`, `invalidRecordsDoNotHideValidNeighborsOrRewriteHistory`, `unreadableHistoryNeverFallsBackToUnauthenticatedRecords`; mutation: “Malformed History pairs reach undo” |
| A retry updates its own completed operation, preserves captured ownership and converts completed moves from copies | `TransferJournal`, `TransferUndo.register`, `OperationLog.recordTransfer`, `undo` | `TransferTests/repairedCopiesKeepTheOriginalHistoryEntryAndItsOtherItems`, `repairedCrossVolumeMovesUpdateBothNativeUndoAndHistory`, `aPartialMoveCannotKeepCopyUndoAfterItsOriginalRemovalFails`, `retriesAfterUndoOrClearingHistoryStartANewRecord`, `retryFinishingDuringHistoryUndoStartsItsOwnRecord`, `unloggedRetriesKeepNativeUndoAfterTheirFirstActionWasUsed`, `staleHistoryRowsCannotUndoClearedOrAlreadyUndoneRecords`; mutations: “Retry journal” |
| Transfer ownership through queued work and Undo/Redo | `TransferQueue`, `TransferJob.registerUndo`, `ArchiveJob.register`, `TransferUndo`, `FileOps.registerLogMark` | `TransferContextTests/*` (private preferences and History, repeated same-disk and cross-disk Undo/Redo, replaced identities, queued archives); mutations: “Transfer ownership” |

## Copy, move, drop, paste

| Action | Code | Tests |
|---|---|---|
| Window and pane transfer ownership | `BrowserServices`, `Pane`, `BrowserWindowController.transferToOtherPane`, `BrowserViewController.transfer` | `TransferContextTests/bothPanesInEveryViewSendOnlyTheirSelectionToTheirOwnQueue`, `replacementPanesAndBrowserCommandsKeepTheWindowServices`, `bothSidebarDropModesUseTheWindowQueue`; mutations: “Browser service ownership” |
| Selection and inline rename after a completed operation | `BrowserWindowController.selectionAfterOperation`, `Pane.destination`, `BrowserViewController.renameWhenShown`, `ColumnBrowserViewController.paneLoaded` | `DirectoryReadSessionTests/*` (applied entries, original pane, navigation and search edits, cancelled rename, native edit completion); mutations: “Applied browser actions” |
| Metadata arriving during a List rename | `BrowserViewController.folderSizeArrived`, `indexChanged`, `mediaInfoArrived`, `exceptRenaming` | `DirectoryReadSessionTests/metadataDoesNotEndAnInlineRename` (both panes, root and expanded rows, size/index/media updates preserve the editor and leave the whole tree unchanged); mutations: “Inline rename metadata” |
| Deferred metadata after a rename ends, and visible metadata during a Columns rename | `BrowserViewController.controlTextDidEndEditing`, `ColumnPane.refreshVisibleRows`, `applyDeferred`, `ColumnBrowserViewController.beginRename` | `DirectoryReadSessionTests/endingAnUnchangedListRenameDisplaysDeferredMetadata`, `columnMetadataRefreshKeepsTheEditedLabelHidden` (Escape and unchanged names refresh results/media cells; both panes and deeper Columns retain the editor, hide its old label, refresh other rows and apply cut dimming after cancellation; whole trees stay unchanged); mutations: “Rename refresh follow-up” |
| Parent-folder navigation keeps commands in the chosen pane and focused column | `BrowserWindowController.goToEnclosingFolder`, `ColumnBrowserViewController.focusParentColumn` | `FinderNavigationTests/commandUpOpensTheParentAndSelectsTheFolderInTheOwningPane` (native ⌘↑ twice, all five views, both panes and deeper Columns; cancels a held folder open, selects each folder left behind, preserves the other pane and the complete tree); mutations: “Finder parent navigation” |
| Preparing provider copies before file operations | `CopyProviders.prepareForCopying`, `CopyProviders.fetch`, `LazyCopies` | `CopyProvidersTests/*` (exact owner, mixed selections, errors, prefetch budget); `RemoteFilesTests/theProviderInterfaceUsesItsInjectedServerAndPreservesFetchedFiles`; mutations: “Copy provider routing” |
| Refreshing and removing provider copies | `CopyListings`, `RemoteFiles.refresh`, `RemoteFiles.discard`, `ContainerFiles.refresh`, `ContainerFiles.discard` | `CopyListingsTests/*`; `RemoteFilesTests/invalidatingAnInFlightListingReadsAgainBeforeReportingItFresh`, `discardingACopyDrainsItsListingBeforeRemovingIt`; mutations: “Copy listing coordination” |
| Fetching and disconnecting provider copies | `CopyFetches`, `RemoteFiles.fetchOne`, `RemoteFiles.drainAndRemove`, `ContainerFiles.fetchOne`, `ContainerFiles.fetchTree`, `ContainerFiles.drainAndRemove` | `CopyFetchesTests/*`; `RemoteFilesTests/disconnectWaitsForAnActiveDownloadToStopBeforeRemovingItsCopy`, `cancellingOneServerReaderKeepsAnotherReadersDownloadAlive`, `disconnectAlsoDrainsAutomaticallyPrefetchedFiles`; mutations: “Copy fetch coordination” |
| Copy / move items (engine) | `TransferEngine.perform`, replace, merge, verify | `TransferTests/*` |
| Retry a failed transfer only within its original destination, preserving replacements and repairing nested failures once | `TransferEngine.retry`, `retryFailures`, `TransferRetryTarget`, `CopySession`, `verify`, `removeIfPresent`, `removeSource` | `TransferTests/retriesLeaveReplacementsAndChangedParentsAlone`, `retriesRepairOnlyTheirRetainedPartialCopies`, `retryingAFailedFolderRepairsItsNestedFailuresOnlyOnce`, `retriesRequireTheOriginalRootEvenWhenTheImmediateParentSurvives`, `failedDirectoryCleanupKeepsItsOriginalDescriptorOwnership`, `verificationDetectsReplacedCopiesAndNeverDeletesUnownedReplacements`, `retryingAPartialDirectoryRepairsInPlaceAndPreservesUnownedChildren`, `crossDiskMoveKeepsOriginalWhenDestinationOrSourceIdentityIsReplaced`; mutations: “Retry cleanup”, “Shared operation safety” |
| Order waiting copies, moves and archives | `TransferOrdering`, `TransferQueue.reorder`, `releaseDisk`, `startNextArchiveJob` | `QueueOrderingTests/*` (real scheduling, native controls, conflicts, cancellation, independent disks, private History, Undo/Redo and replacements); mutations: “Queue order” |
| Copy / move jobs (drag and drop, paste, other pane, Duplicate) | `TransferQueue.enqueue`, `TransferJob` | `TransferJobTests/*`, incl. `aReadOnlyCopyTakesNothingAndWhatLeavesItIsCopied` |
| What a drop does | `FileDrop.operation(_:into:mask:option:)` | `DropTests/*` |
| Cut and paste | `Clipboard`, `pasteItems` | `ClipboardTests/*` |
| Space previews stop file edits before they reach the source browser; Copy retains its chosen item, clipboard and pane | `PreviewReadOnlyCommands`, `PreviewCommandTarget`, `PreviewCoordinator.perform` | `PreviewCommandTests/*` (native responder dispatch, stale menus and sessions, replacement files and redirected parents, independent clipboards, original pane after focus changes); mutations: “Space preview actions” |

## Rename and new items

| Action | Code | Tests |
|---|---|---|
| Rename (inline, click to rename, Rename menu) | `FileOps.rename`, `BrowserRename.confirmedName` | `InlineRenameTests/*`; `RenameTests/*` |
| Batch rename, swaps and chains | `RenameRules`, `FileOps.moveAll` | `RenameTests/*` |
| New Folder / New File | `FileOps.newFolder`, `newFile`, `BrowserViewController.newFile` | `NewFileTests/*` (incl. `newFolderNeverTakesAnExistingOne`); `TrashUndoTests/undoingANewFolderLeavesOneMadeInItsPlace`; `BrowserPreferencesTests/newFileUsesItsOwnExtensionAndTargetInEveryView` |

## Metadata

| Action | Code | Tests |
|---|---|---|
| Locked, permissions, comments (Get Info) | `FileInfoEditing`; `InfoEditor` retains a chosen comment item while editing | `MetadataEditTests/lockingTouchesOnlyThatItem`, `permissionsChangeOnlyThatAccessOnThatItem`, `aCommentChangesOnlyTheComment`; `SecurityFollowupTests/commentEditsRefuseItemsReplacedWhileTyping`, `focusedCommentsKeepTheirDisplayedItemBeforeTheFirstEditNotification`; `InspectorProviderTests/switchingFromEditableItemToProviderCopyCommitsActiveCommentToOriginalItem`; `ChosenFileFollowupTests/commentWritesAndRemovalRefuseReplacedParents`, `commentRemovalChangesOnlyTheChosenLink` |
| Tags | `TagStore.update`, `toggle`, `canTag` | `MetadataEditTests/tagsGoOnTheChosenFilesOnly`, `FileCommandOwnershipTests/tagsNeverGoOnItemsOfTheirWindowsCopies` |

## Compare and Sync, archives, Ask Strata, project cleanup

| Action | Code | Tests |
|---|---|---|
| Sync (copies and extras to the Trash) | `FolderCompare.defaultAction`, `syncPlan` | `FolderSyncTests/*` |
| Compress | `Archiver.compress`, `place` | `MetadataEditTests/compressingAddsOneArchiveAndNeverReplacesOne`, `aLinkIsArchivedAsALink` |
| Extract and browse an archive | `Archiver.extract`, `extractContents`, `unpack`, `check`; `ArchiveWriter` | `ArchiveSafetyTests/*`, including `browsingAnArchiveNeverReplacesAnExistingFolder` for the copy used to browse; `ArchiveWriterTests/*` for every record a worker could send; `ArchiveExtractTests/*` through the real service and worker; `TransferContextTests/undoingAnExtractTrashesOnlyWhatItMade` for ⌘Z |
| Copy an archive member from Space preview, then Paste or Paste and Move | `PreviewArchiveReader`, `PreviewArchiveSource`, `PreviewArchiveLease`, `PreviewArchiveContent`, `PreviewCoordinator`, `ReadOnlyCopies` | `PreviewArchiveTests/*`, `PreviewCancellationTests/*`, `PreviewArchiveRootTests/*`, `BookPreviewTests/comicContactSheetCopiesOnlyTheChosenPageAndUndoKeepsTheComic`, `draggingAPreviewedPageKeepsItsReadOnlyCopyAndRejectsOtherRowsAndReplacements`: comic page drag/Copy/Paste and Undo keep the source archive and siblings; synchronous password cancellation, ordered replacement exports, safe tar/CPIO root aliases, exact members/subtrees, unsafe and duplicate paths, source stamps, cancellation, private permissions/ACLs/quarantine, bounded cache, replaced leaves/parents/root, clipboard replacement, resource forks refused, owning copy queue and Undo; mutations: “Space preview archives”, “Preview follow-up”, “Book previews” |
| Space preview sizes are read-only, bounded and remain with their selection | `FootprintReader`, `FootprintSource`, `PreviewMeasurement` | `PreviewMeasurementTests/*`: sparse allocation, hard links, hidden contents, link targets, parent/target replacements, entry/depth/clock limits, cancellation, held late reads, provider cache refusal and explicit native Calculate Size; mutations: “Space preview sizes” |
| HTML previews only read their chosen document and bounded local assets; scripts, network loads and stale callbacks are refused | `HTMLPreviewDocument`, `HTMLPreviewMarkup`, `HTMLWebSession`, `PreviewWebPage`, `WebPreviewView`, `HTMLPreviewView` | `HTMLPreviewTests/*`, `ColorThemeTests/htmlPreviewControlsFollowEveryThemeWithoutReplacingDocumentOrSourceSelection`; real WebKit, loopback probe, source fallback identities, budgets, cancellation and theme preservation; mutations: “HTML preview”. Compiled WebKit rules use only `SecureStorage.Context.shared.caches`; no user files change. |
| Space previews list provider metadata and fetch/copy only the chosen contents through their owner | `RemoteFiles.previewFolder`, `ContainerFiles.previewFolder`, `CopyWriter.apply`, `PreviewProviderContent`, `PreviewArchiveLease.exporting`, `PreviewCoordinator` | `PreviewProviderListingTests/*`, `PreviewProviderContentTests/*`, `PreviewCancellationTests/*`: ordered replacement commands, shared-read ownership, no eager/recursive downloads on listing, bounded listing, pinned cache root, cancellation/draining, chosen exports and receipt cleanup, clipboard replacement, owning Paste and Undo, fetched archives and scoped notifications; mutations: “Space preview providers”, “Preview follow-up” |
| Ask Strata plans (rename, move, trash, new folders), their undo and redo | `PlanValidator`, `PlanExecutor`, `PlanTransaction`; created folders use `CreatedFolders` and `removeEmptyFolders` | `PlanSafetyTests/*`, including `undoKeepsAReplacementAtACreatedFolderPath`, `TransferTests/aCaseOnlyRenameThatCantFinishNeverLeavesTheItemHidden` |
| Cleanup and recreation of folders made for Put Back, queued transfers and History | `CreatedFolders`, `TransferUndo`, `OperationLog.undo`, `FileOps.removeEmptyFolders` | `CreatedFolderOwnershipTests/*` covers captured ownership, replacements before and after transfer completion, symlink targets, failed reads, legacy History, repeated Undo/Redo and cross-disk completion |
| Project cleanup | `ProjectDetector.detectSync`, `isRealDirectory` | `ProjectCleanupTests/*` |
| Git for status badges (a browsed repository's own commands never run, and a disabled driver is no longer required) | `GitRunner.runBlocking`, `hardening`, `repositoryFilterOverrides` | `GitSafetyTests/*` |

## Servers (SFTP, S3)

| Action | Code | Tests |
|---|---|---|
| Window server removal keeps credentials, cached copies and notifications with their owning environment | `RemoteServices.remove`, `RemoteConnections.disconnect` | `RemoteEnvironmentTests/browsingAndRemovalKeepMatchingIDsInSeparateEnvironments`, `disconnectNotificationsMoveOnlyTheirOwnersPanes`; mutations: “Remote environment” |
| Remote connections retain their own attempt and backend through cancellation, reconnection and status delivery | `RemoteSessions.backend`, `establish`, `disconnect` | `RemoteSessionOwnershipTests/*`; mutations: “Remote session ownership” |
| Sorting preserves file identity and native selection, including loaded descendants; metadata cannot impose folder order on unsorted results | `BrowserOrdering`, `BrowserViewController.resortAfterMetadata`, `applySort` | `BrowserOrderingTests/*`, `BrowserListingTests/*`, `MediaColumnsTests/*`; mutations: “Browser ordering” |
| Remote listing timeouts retire only the acquired backend in its owning pool; late failures leave replacements and reservations intact | `RemoteFiles.list`, `RemoteSessions.retire` | `RemoteFilesTests/unresponsiveListingsRetireOnlyTheirOwningPoolAndLeaveOtherErrorsConnected`, `lateListingTimeoutCannotRetireAReplacementOrRevokeItsReservation`, `failedBackendAcquisitionHasNoConnectionToRetire`; mutations: “Remote read ownership” |
| Proposed server settings and credentials stay private until verification; cache retirement and publication retain request ownership through cancellation, removal and retry | `RemoteConnections`, `RemoteSessions.reserveReplacement`, `release`, `install`, `ConnectToServerController.tryConnecting` | `RemoteConnectionTests/*`; mutations: “Staged connections” |
| Disconnect and removal serialize cache cleanup with reconnect publication, refuse stale confirmations, and keep readers out until cleanup finishes | `RemoteConnections.disconnect`, `remove`, `RemoteServices.remove` | `RemoteConnectionTests/staleRemovalAndDisconnectConfirmationsLeaveEditedServersAndPendingLoginsAlone`, `removalBlocksReadersUntilCleanupFinishesAndPreservesItsNeighbor`, `removalObserversCanReconnectWithoutOldCleanupErasingTheirConnection`, `disconnectWaitsForAnOlderHandoffAndReleasesItsCoordinator`; mutations: “Server retirement” |
| Saved server metadata, registry and credentials share an owner; removal retires the old secret before observers can save its replacement | `RemoteServerStore.save`, `forget`, `persist`, `RemoteServerRegistry` | `RemoteServerStoreTests/*`; mutations: “Server store” |
| Remote secrets are updated in place and kept on errors; all reads, writes and deletion target only their server and service | `RemoteKeychain`, `KeychainAccess`, `S3Backend.init` | `RemoteKeychainTests/*`; mutations: “Remote credentials” |
| Delete, move, rename, new items on a server | `RemoteFiles`, `SFTPBackend`, `BrowserViewController.newFileNameOnServer` | `ServerSafetyTests/*`; `RemoteFilesTests/newFilesAreMadeOnTheServerNeverOverAnything`, `deletingALinkLeavesWhatItPointsTo`; `SFTPClientTests/foldersRenamesAndRemoval`; `BrowserPreferencesTests/serverNewFileNamesUseTheirOwnSettingsAndAvoidExistingFilesAndLinks` |
| Upload (asks before replacing) | `copyToServer`, `uploadChoice`, `RemoteFiles.upload` | `ServerSafetyTests/copyingOntoTakenNamesAsksOrLeavesThem`; `RemoteFilesTests/uploadsFilesAndFolders`, `uploadingOverALinkReplacesTheLink` |
| S3 delete, rename, upload | `S3Backend` | `DeleteScopeTests` (S3Tests extension): `deletingAFolderTakesOnlyTheKeysInIt`, `deletingAFileTakesOnlyThatKey`, `theBucketItselfIsNeverDeleted`, `renamingAFolderMovesExactlyItsKeys`, `renamingOnS3NeverReplacesAnything`, `aCopyThatFailsLeavesTheOriginal`, `uploadsAndFoldersNeverTakeTheBucketsTop`, `whatsTakenIsSeenBeforeCopyingOntoIt` |
| Copying out of a server's copy | `ContainerCopies.finishCopyingOut`, `LazyCopies.stageForClipboard` | `RemoteFilesTests/copiedOutLinksLeadingOutsideAreDropped`, `mergingOutLeavesWhatWasThereAlone`, `theClipboardGetsAFinishedCopy` |

## Containers

| Action | Code | Tests |
|---|---|---|
| Writing a container's files into its copy | `CopyWriter.writeTree`, listings | `ContainerCopyTests/aContainersFolderIsWrittenOnlyIntoItsCopy`, `aCopyThatIsALinkIsNotWrittenThrough`; `ContainerTests/listingsAreWrittenWithoutEscapingTheFolder`, `linksAlwaysResolveInsideTheCopy` |
| Fetching one file | `CopyWriter.fetchFile` | `ContainerCopyTests/aFetchedFileTakesOnlyItsPlaceholdersPlace`, `aFetchThatIsntAFileOrFindsSomethingElseChangesNothing` |
| Containers' and projects' folders | `CopyWriter.syncContainers` | `ContainerTests/theContainersFolderFollowsTheEngine`, `composeProjectsGroupTheirContainers`, `aLeftoverFolderNamedLikeAProjectMakesWay`, `projectsNamedAlikeShareAFolder`, `aContainerCalledLikeAProjectKeepsItsFiles` |
| Dragging out of a container | `ContainerPromises` | `ContainerCopyTests/aDraggedOutItemNeverReplacesWhatsAtTheDrop` |
| Start, stop, restart, pause | `ContainerAPI.perform` | `ContainerTests/actionsAreOnePostEach` |

## iCloud and File Provider

| Action | Code | Tests |
|---|---|---|
| Remove Download | `CloudActions.removeDownloads` (both, away from the main thread), `removable`, `removeDownload` (the system's evict injected); capture the batch before requests, verify ownership and current upload state | `DeleteScopeTests/removeDownloadFreesOnlyWhatsAlsoInTheCloud`, `removeDownloadAsksToFreeExactlyTheItemsChosen`, `removeDownloadChoosesFromTheListingAndFreesOnlyWhatsInTheCloudNow`; `CloudFoldersTests/evictionRechecksUploadStateAndTheWholeChosenBatch`, `missingUploadMetadataNeverOffersEviction` |
| Download Now | `CloudActions.Download`: capture the item and parent before dispatch, refuse links and replacements; coordinate File Provider file reads on a worker | `CloudFoldersTests/aDownloadKeepsItsChosenFileAcrossDelayedWork`, `downloadsRefuseLinksLocalItemsAndRedirectedParents`, `coordinatedDownloadReadsOnlyTheChosenRegularFile` |

## The `strata` command, Strata's own data

| Action | Code | Tests |
|---|---|---|
| Installing the command | `CommandLineTool.mayReplace` | `DeleteScopeTests/theCommandReplacesOnlyItsOwnLink` |
| Archives' copies (remove, replace, prune) | `ArchiveCache`, `Archiver.removeTree` | `CacheRemovalTests/aCopyIsRemovedOnlyAsAWholeEntryOfTheCache`, `aNewCopyReplacesOnlyOlderCopiesOfTheSameArchive`, `pruningTakesOnlyStaleCopies`, `removingATreeNeverFollowsALinkOut` |
| Containers' and servers' copies (remove, set aside at quit) | `ContainerCopyStore.remove`, `RemoteCopyStore.remove`, `setAsideForRemoval`, `removeSetAside` | `CacheRemovalTests/aContainersOwnFilesAreNeverRemovedAsAFolder`, `settingCopiesAsideRemovesOnlyThemAtQuit` |
| Server copies stay with their owning cache and registry; preparation and removal reject replacement links and escaping names | `RemoteCopyStore.prepare`, `remove`, `Archiver.removeTree(_:in:)`, `hasEntry(_:in:)`, `RemoteFiles`, `RemoteWriter.place`, `ServerCopyProvider` | `RemoteCopyOwnershipTests/*`; mutations: “Remote copy ownership”, “Shared operation safety” |
| Recent share addresses omit passwords and clearing them preserves other settings and environments | `ServerConnectionSettings`, `ServerConnection.displayString` | `ServerConnectionSettingsTests/*`; mutations: “Connection settings” |
| Share addresses accept ordinary URLs and refuse embedded control characters before reaching NetFS | `ServerConnection.url` | `ServerAddressTests/*`; mutation: “Share addresses refuse embedded control characters before mounting” |
| Network share results belong to their sheet and request through cancellation, replacement and teardown | `ServerMountSession`, `ConnectToServerController.connectShare` | `ServerMountSessionTests/*`; mutations: “Share mount ownership” |
| Independent storage contexts and History Undo/Redo retain their key, directory and journal | `SecureStorage.Context`, `OperationLog.init`, `registerRedo`, `FileOps.registerMoveUndo` | `StorageContextTests`; mutations: “Storage isolation” |
| Stores (History, index), content index reset, script files | `SecureStorage.Context.write`, `makeFolder`, `SemanticIndex.reset`, `ProjectActions.removeStaleCommandFiles` | `CacheRemovalTests/savingAStoreReplacesOnlyItsOwnFile`, `resettingTheContentIndexRemovesOnlyItsStore`, `staleScriptFilesGoOnlyFromTheirFolder` |
| Tests never touch your data, including optimized builds | `SecureStorage.Context.shared`, `temporary`, `caches` | `DeleteTests/testRunsKeepHistoryAndIndexesOutOfYourOwn`; `DeleteScopeTests/testsKeepToCachesOfTheirOwn` |
| A test run keeps its settings in a temporary folder of its own and removes that suite and its file when it exits, never the app's | `Prefs.testPreferencesFolder`, `Prefs.registerTestCleanup` | `PreferencesTests/processPreferencesAreIsolatedFromTheAppInEveryConfiguration` (the suite's place); the exit itself can't be tested (see “Not mutated, and why”) |

## The proof: mutations

`Tests/mutations.json` holds, for every action row above, at least one mutation: a one-line change to the code that
breaks the rule (skips a check, reads it late, applies it to the wrong item), and the tests that must then fail.
`scripts/mutate.py` applies each alone, runs those tests, and restores the file; the **Mutations** workflow runs it
weekly and on request. The runner first checks that the unmodified tests pass. Each run has a five-minute limit;
a timeout, a build failure, or no tests never counts as caught, and stopping the runner restores the source. The
workflow splits the selected rules across four isolated checkouts; together they run every rule exactly once. An
empty rule input selects all rules. Local runs keep using one working tree and apply mutations in order. The
SFTP rename mutation removes both the preflight check and the protocol’s refusal to replace, so the tests reach the
rule instead of passing on the second defense. A row whose tests pass with the rule broken isn't covered, whatever the
map says, so a new test comes with a mutation, and a mutation whose text no longer matches the code is updated, not dropped.

| Action | Code | Tests |
|---|---|---|
| Delete confirmation keeps both the selected inode and its parent across the sheet; replacement names and ancestors are refused | `Model/ChosenFile :: remove`; `Browser/BrowserViewController+Trash :: deletionPlan`, `deleteAll` | `SecurityReviewTests/deletionKeepsReplacementsAcrossTheConfirmation`, `deletionKeepsAnAncestorReplacedByAnotherDirectoryOrLink`; `DeleteTests/*` |
| Copies from servers and containers finish sanitizing their own receipts on the worker, before completion; merged owners stay unchanged | `Containers/ContainerCopies :: finishCopyingOut`; `Transfers/TransferEngine :: copyForExport`, `performItem`, `retryItems` | `SecurityReviewTests/copiedLinksAreSanitizedFromReceiptsAfterTheSourceDisappears`, `copiedReceiptsDoNotAdoptReplacementFilesOrFollowReplacementAncestors`, `queuedCopiesFinishSanitizingBeforeCompletionAndPreserveMergeOwners`; `ContainerTests/hardlinksUseContainerPathsAndNeverReuseAnUnfetchedPlaceholder` |
| SFTP without atomic replacement keeps a backup until the upload lands; failed rollback retains both recovery paths | `Remote/RemoteSession :: replaceWithoutExtension` | `SecurityReviewTests/standardSFTPRenameRestoresTheOriginalWhenInstallationFails`, `standardSFTPRenameKeepsBothCompleteVersionsWhenRollbackFails`, `standardSFTPRenameOnlyRemovesTheBackupAfterTheUploadLands` |
| Every archive is parsed by the sandboxed worker and written by Strata; single hidden roots stay in an archive folder; flags, privileged modes and ACLs are checked, on files named like Mac metadata too | `Transfers/Archiver :: unpack`, `extract`, `listed`, `checkItem`, `checkedPermissions`, `clearFlagsAndAccessList`; `Transfers/ArchiveWriter :: apply` | `ArchiveSecurityReviewTests/*` (including resource forks and AppleDouble links); `ArchiveSafetyTests/*` |
| Extract writes only what it checked: inside its private folder, never through a link (a folder's or link's metadata, a hard link), never over an earlier entry, within a new folder's permissions, until the disk runs low, and on a disk that keeps attributes in "._" files never an item beside its "._" partner; the worker refuses names that climb out and metadata copyfile refuses or that is past its limit, and reads only in the mode it was started for | `Transfers/ArchiveWriter :: folder`, `openFolder`, `subfolder`, `writeFolder`, `writeLink`, `writeHardLink`, `finish`, `components`, `makeRoom`, `write`; `CArchivePreview/ArchivePreview :: tar_path`, `mac_attributes`, `counted`, `strata_archive_preview_worker` | `ArchiveWriterTests/*`; `ArchiveExtractTests/*` |
| Recursive deletion snapshots child names and identities and closes the stream before descending; wide and deep folders leave siblings and link targets unchanged | `Model/ChosenFile :: entries`, `forEachName`, `remove` | `ChosenFileFollowupTests/snapshotsCloseTheirStreamAndKeepExactChildIdentities`, `wideAndDeepDeletionKeepsSiblingsAndLinkTargets`, `aFailedDirectorySnapshotChangesNothing` |
| Binary plist budgets cover tags, Finder comments and installed-app metadata before Foundation decoding | `Support/BinaryPropertyListBudget`; `Model/TagStore :: parse`; `Model/FileInfoEditing :: comment`; `AppUpdates/InstalledApp :: plist` | `SecurityFollowupTests/tagAttributesRefuseExcessiveSharedStrings`, `bundlePlistsRefuseExcessiveSharedStrings`, `malformedBinaryCommentsNeverBecomePlainText` |
| Packed directory records are decoded within their declared lengths, without copying the fixed-size C name tuple or accepting lossy names | `Support/DirectoryEntryName :: read`; `Model/ChosenFile :: forEachName`; `Transfers/Archiver :: entries`; `Containers/CopyWriter :: names`; `Model/FileOps :: removeCreatedFolders` | `DirectoryEntryNameTests/*`; `ChosenFileFollowupTests/wideAndDeepDeletionKeepsSiblingsAndLinkTargets` |

## Not mutated, and why

Functions the audit lists that no mutation reaches, each with the reason. `scripts/audit-destructive.py --check` fails
on any function that is in neither this table nor a mutation.

| Functions | Why no mutation |
|---|---|
| `AI/PlanGenerator :: (top level)`, `recipe`, `init`, `expand`; `AI/PlanModel :: init`; `AI/PlanValidator :: validate`, `add`, `needFolder`; `AI/RenameRules :: plan` | `rename` here is a plan step's name, not a file call, and `add` hands each step to the check for its kind (mutated). The steps are carried out by `PlanExecutor` (mutated). |
| `App/StrataCommand :: init`; `App/MainMenu :: fileMenu`, `menuNeedsUpdate`, `rename`; `Window/Workspaces :: rename`, `askToRename` | A workspace's name in saved settings, and the menu items for it. No files. |
| `Browser/BrowserViewController+Actions :: renameItem`; `Views/ClickToRename :: clicked`; `Browser/BrowserViewController+Servers :: renameOnServer` | Hand the typed name to `FileOps.rename` or `RemoteFiles.rename` (both mutated), which hold every check. |
| `Model/Places :: eject`; `Sidebar/SidebarViewController :: menuNeedsUpdate`, `ejectItem`; `Window/BrowserWindowController :: focusSearch`, `ejectVolume`, `validateMenuItem` | Hand a disk to macOS to eject. Nothing of the user's changes. |
| `Dock/DockSearch :: restartDock` | Relaunches the Dock (`killall Dock`). No files. |
| `Model/Prefs :: registerTestCleanup` | Runs as a test process exits and removes only that run's own `dev.strata.tests.<id>` settings suite and file; a test can't watch its own process exit. |
| `Index/IndexStore :: remove`, `unlink` | An in-memory tree, not files. |
| `Toolbar/BrowserToolbar :: toolbarDidRemoveItem` | AppKit removed a toolbar control; this clears references to its UI object. No files. Native removal and persistence are tested in `ToolbarCustomizationTests`. |
| `Dev/GitRepository :: execute` | Runs git with the arguments `runBlocking` hardened (mutated); git's own commands here (`status`, `config`, `ls-files`) change nothing. |
| `Dev/ProjectActions :: writeCommandFile` | Writes its own script into a fresh folder in the temporary directory, away from the main thread, for `openCommandFile`; what the script runs is tested (`theTerminalScriptQuotesEverything`). |
| `Browser/BrowserViewController+ArchiveBrowsing :: prepareCopy`; `Containers/ContainerCopies :: prepare`, `stackFolder`, `record`, `setAttribute`; `Containers/ContainerFiles :: close`, `makeFolders`, `makePlaceholder`, `setLinkTimes`, `remember`, `restoreTimes`, `setTimes`, `markDownloaded`, `systemQuarantine`; `Remote/RemoteFiles :: list`, `fetch`; `Remote/LazyCopies :: newFolder`; `Model/SecureStorage :: url`, `init`, `prepare`, `useApplicationStorage`; `Model/ArchiveCache :: touch`; `Transfers/Archiver :: unpack` | Make or mark Strata's own folders, placeholders and temporary files inside its copies and caches (Put Back's `makeFolders`, mutated, remakes the folders `Trash.location`, mutated, leads to). Nothing of the user's. |
| `Containers/ContainerFiles :: place`, `bringDown`, `write`, `endFile` | Arrange Strata's copy of a container's files (`endFile` puts a file the stream wrote whole in its place there) (`theContainersFolderFollowsTheEngine`, `composeProjectsGroupTheirContainers`, `aLeftoverFolderNamedLikeAProjectMakesWay`; `aContainersFolderIsWrittenOnlyIntoItsCopy`). The copy is Strata's own; what comes out of it is covered above. |
| `Model/FileOps :: trash` | Called only by undo, with items an operation itself created (filtered by `LandedFiles`, mutated). What users trash goes through `canTrash` and `deletionPlan` (both mutated). |
| `Model/SecureStorage :: removeLegacy`, `commit` | Remove the old store names Strata itself used; swap its own temporary into place with `rename()`, which replaces a planted link without following it (`savingAStoreReplacesOnlyItsOwnFile`). |
| `Model/TagStore :: apply`, `write` | `canTag` (mutated) keeps links and read-only copies out; tags are the item's own metadata. |
| `Remote/RemoteFiles :: makeFile`, `place`; `Remote/RemoteSession :: upload` | Refuse a taken name, then rename under the server's own refusal (`SFTPBackend.rename`, mutated); swap a fetched file over its placeholder inside the copy; replace a file or link as asked (`uploadingOverALinkReplacesTheLink`), never a folder. |
| `Remote/S3Client :: download`; `Connections/SFTPClient :: init`, `rename`, `setTimes`, `download`, `upload` | Protocol calls and the copy's own temporary files; the refusals live in the backends (mutated). |
| `Settings/SettingsWindowController :: install` | Goes ahead only when `mayReplace` (mutated) allows. |
| `Transfers/Archiver :: clearFlagsAndAccessList`, `checkedPermissions`, `markQuarantined`, `run` | Act on the extracted copy in Strata's scratch folder before `check` (mutated) and `place` (mutated). |
| `Transfers/ArchiveWriter :: run`, `setTimes` | Give items the writer made in Strata's scratch folder their times, through folders `openFolder` (mutated) opens, before `check` (mutated) and `place` (mutated). |
| `Transfers/TransferEngine :: removeIfPresent`, `removeSource`; `Transfers/TransferSession :: repairOwnedDirectory` | Remove the incomplete copy the engine made itself; remove the original only after `changedSinceCopy` (mutated) and verification (mutated) pass; restore owner write access on a read-only folder the engine created itself during that job (`recordedDirectories`, mutated). |

## Where the system is stood in for

- **iCloud eviction.** `evictUbiquitousItem` needs a signed-in account, so `CloudActions.removeDownload` takes the
  evict call and the test records exactly which items it's asked to free, in which order, and that it goes on past a
  refusal. What macOS does with an item not in the cloud is tested too: it refuses, and the item stays.
- **The moment an item lands.** `TransferEngine.hooks.afterLanding` is called the instant an item has been placed
  and recorded for undo, before anything else happens to it (also in same-disk `TransferUndo.start`). Tests swap the file right then, for a copy, a rename
  and a move across disks, and show the undo leaves the swapped file alone. (A move across disks keeps its original
  too: the copy no longer matches it.)
- **Worker completion.** `TransferEngine.hooks.afterResult` runs before the main actor receives the worker’s result.
  Tests replace an operation’s own Trash item or a retried copy at that point. The result must carry captured identity,
  never adopt the item now at that path. Cleanup identifies each fixture item individually.
- **Alerts and sheets.** What they decide is a plain function, and that function is tested (`deletionPlan`,
  `uploadChoice`, `FolderCompare.syncPlan`, `CommandLineTool.mayReplace`).
- **Disks.** Moves across disks run against a disk image each test attaches and detaches (`ScratchVolume`). Each disk's
  folder names the process that made it, and a test process's first disk removes those of processes that have ended: it
  detaches only what's mounted on a folder inside, opened without following a link, and leaves a folder whose image is
  still attached or that holds anything else (`ScratchVolume.sweep`, `ScratchVolumeTests`). An attempt that attached its
  image before failing detaches that image's own disk, found by the image's path, which no other attempt has. A disk
  that says it's busy is tried again a few times, each time looking again at what's mounted in the folder, or at the
  disk the image's path names, and none of it if it has gone meanwhile; between that look and the detach, as in a single
  detach, hdiutil's device names leave a moment no look can close. Ejecting a disk (`Places.eject`, the sidebar's and
  the menu's Eject) only hands the volume to macOS; nothing of the user's changes, and it isn't tested.

## Every function, by file

| Selective archive preview functions | Headless coverage |
|---|---|
| `Previewing/PreviewArchiveLease :: init`, `prepare`, `makeFolders`, `create`, `open`, `mark`, `clean` | `PreviewArchiveTests/*`, `PreviewArchiveStreamTests/*`; identity receipts, no-follow parents, private modes/ACLs, quarantine, only owned leaves and empty folders removed; a streamed copy is owned and takes its whole size from the cache before its first byte is written. All functions have “Space preview archives” mutations. |
| `CArchivePreview/ArchivePreview :: strata_archive_preview_worker`, `drop_bootstrap`, `input`, `seek_input`, `valid_path`, `needs_full_extraction`, `support_formats`, `tar_path`, `mac_attributes`, `unpack_entry`, `unpack` | `PreviewArchiveTests/*` and `ArchiveExtractTests/*` read through the real archive service and its workers: one process per read that inherits the service's App Sandbox (none of your files, no network, new processes or system service lookups; it can still read system files and its container) and refuses to read without its own entitlement. It writes only the output pipe it is handed; Extract's read sends what Strata then writes itself. Bounds, selection/fork, limit and sandbox rules have “Space preview archives” mutations, and Extract's names, modes and Mac metadata “Extract” ones; wrapper callbacks also run under ASan and UBSan. |
| `StrataArchiveService/main :: start`, `spawn_worker` (starts a worker for one read; the service never reads an archive) | `PreviewArchiveTests/aServiceOrWorkerSignedWithoutItsSandboxRefusesToReadAnything` and every suite with `.archiveWorkerApp`; mutation: “the archive service starts workers without its sandbox” |


What the audit found (`scripts/audit-destructive.py` lists each function in `Sources/` holding a call that can delete,
move, rename, overwrite, truncate, evict or change metadata, or that runs a tool), and what covers it. Functions that
only write Strata's own new files where nothing was (`createDirectory`, a temporary name) are listed with what they
belong to.

| File :: function | Covered by |
|---|---|
| `AI/PlanExecutor :: perform`, `moveBack`, `trash` | `PlanSafetyTests/runningAPlanDoesOnlyItsCheckedSteps`, `undoKeepsAFolderThePlanMadeOnceSomethingElseIsInIt`, `undoAndRedoOfAPlanTouchOnlyItsOwnItems`, `TransferTests/aCaseOnlyRenameThatCantFinishNeverLeavesTheItemHidden` |
| `AI/PlanGenerator :: (top level)`, `recipe`, `init`, `expand`; `AI/PlanModel :: init`; `AI/PlanValidator :: validate`, `add`, `rename`, `needFolder`, `strandChains`; `AI/RenameRules :: plan` (`rename` here is a plan step's name, not a file call) | `PlanSafetyTests/*`, `RenameTests/*` |
| `AI/SemanticIndex :: reset` | `CacheRemovalTests/resettingTheContentIndexRemovesOnlyItsStore` |
| `Model/Prefs :: registerTestCleanup` (a test run's own settings suite, at exit) | `PreferencesTests/processPreferencesAreIsolatedFromTheAppInEveryConfiguration` checks the suite's place; the exit itself is untested |
| `App/StrataCommand :: init`; `App/MainMenu :: fileMenu`, `menuNeedsUpdate`, `rename` (menu items; `rename` is a workspace's name) | `WorkspaceTests/*` |
| `Queue/FileCommands :: rename` | `FileCommandOwnershipTests/*` |
| `Browser/BrowserViewController+ArchiveBrowsing :: prepareCopy` (makes the copy's folder) | `ArchiveSafetyTests/*` |
| `Browser/BrowserViewController+Servers :: renameOnServer` | `ServerSafetyTests/renamingOnAServerStaysInTheFolderAndReplacesNothing` |
| `Browser/BrowserViewController+Trash :: makeFolders` (remakes missing folders for Put Back), `deleteAll` | `PutBackTests/*`, `TrashUndoTests/undoingAPutBackRemovesOnlyTheFoldersItMadeOnceEmpty`, `FileCommandOwnershipTests/putBackFindsWhereAnItemCameFromInItsWindowsHistory`; `DeleteTests/*` |
| `Browser/BrowserViewController :: resortAfterMetadata` (rows in a table, not files); `Browser/BrowserViewController+Actions :: renameItem` | `BrowserOrderingTests/*`; `InlineRenameTests/*` |
| `Containers/ContainerCopies :: prepare`, `stackFolder`, `record`, `setAttribute`, `finishCopyingOut`, `setAsideForRemoval` | `ContainerTests/theContainersFolderFollowsTheEngine` … `aContainerCalledLikeAProjectKeepsItsFiles`; `RemoteFilesTests/copiedOutLinksLeadingOutsideAreDropped`, `mergingOutLeavesWhatWasThereAlone`; `CacheRemovalTests/settingCopiesAsideRemovesOnlyThemAtQuit` |
| `Views/ContainerDrag :: filePromiseProvider` | `ContainerCopyTests/aDraggedOutItemNeverReplacesWhatsAtTheDrop` |
| `Containers/ContainerFiles :: place`, `bringDown`, `apply`, `makeFolders`, `folderFD`, `begin`, `endFile`, `linkHardlink`, `close`, `write`, `makePlaceholder`, `remember`, `restoreTimes`, `setTimes`, `setLinkTimes`, `markDownloaded`, `systemQuarantine` (a probe file of its own), `removeAt` | `ContainerCopyTests/aContainersFolderIsWrittenOnlyIntoItsCopy`, `aCopyThatIsALinkIsNotWrittenThrough`; `ContainerTests/listingsAreWrittenWithoutEscapingTheFolder`, `linksAlwaysResolveInsideTheCopy`, `composeProjectsGroupTheirContainers`, `aLeftoverFolderNamedLikeAProjectMakesWay` |
| `Containers/ContainerFiles :: fetchFile` | `ContainerCopyTests/aFetchedFileTakesOnlyItsPlaceholdersPlace`, `aFetchThatIsntAFileOrFindsSomethingElseChangesNothing` |
| `Dev/GitRepository :: execute` (runs `git`, reads only: `status`, `config`, `ls-files`, hardened against the repository's own config) | `ProjectCleanupTests/*` for what's offered; git's own commands change nothing |
| `Dev/ProjectActions :: writeCommandFile` (its own script file), `removeStaleCommandFiles` | `CacheRemovalTests/staleScriptFilesGoOnlyFromTheirFolder`; `ContainerTests/theTerminalScriptQuotesEverything`, `terminalFileNamesArePlainASCII` |
| `Dock/DockSearch :: restartDock` (`killall Dock`: the Dock relaunches, no files) | `DockSearchTests/*` for what's changed in its list |
| `Index/IndexStore :: remove`, `unlink` (an in-memory tree, not files) | `PathQueryTests/*` |
| `Model/ArchiveCache :: finish`, `touch`, `setAside` | `CacheRemovalTests/aNewCopyReplacesOnlyOlderCopiesOfTheSameArchive`, `pruningTakesOnlyStaleCopies`, `aCopySetAsideLeavesAtOnceAndGoesAfter` |
| `Model/CloudStatus :: removeDownload` | `DeleteScopeTests/removeDownloadAsksToFreeExactlyTheItemsChosen`, `removeDownloadFreesOnlyWhatsAlsoInTheCloud`; `CloudFoldersTests/evictionRechecksUploadStateAndTheWholeChosenBatch` |
| `Model/CreatedFolders :: makeMissing`, `make` (away from the main thread, for it and plans) | `CreatedFolderOwnershipTests/recreationRecordsOnlyFoldersItMakesAndKeepsTryingWhenRequested`, `redoUpdatesOwnershipForLiveAndSavedHistory`, `crossDiskUndoFinishesBeforeRemovingItsCreatedFolders` |
| `Model/FileInfoEditing :: setComment`, `setLocked`, `setAccess` | `MetadataEditTests/aCommentChangesOnlyTheComment`, `lockingTouchesOnlyThatItem`, `permissionsChangeOnlyThatAccessOnThatItem` |
| `Model/FileOps :: rename`, `moveAll`, `moveItem`, `newFolder`, `newFile`, `trash`, `trashItems`, `trashOwned`, `removeEmptyFolders`, `registerMoveUndo` | `InlineRenameTests/*`, `RenameTests/*`, `NewFileTests/*`, `TrashUndoTests/*`, `AcrossDisksTests/*`, `TransferTests/historyUndoOfACopyTrashesOnlyItsOwnCopies` |
| `Model/Places :: eject` (hands the disk to macOS) | not a file change; see above |
| `Model/SecureStorage :: (top level)`, `prepare`, `useApplicationStorage`, `url`, `removeLegacy`, `sweepStaleTemporaries`, `init`, `commit` | `CacheRemovalTests/savingAStoreReplacesOnlyItsOwnFile`; `DeleteTests/testRunsKeepHistoryAndIndexesOutOfYourOwn`; `DeleteScopeTests/testsKeepToCachesOfTheirOwn` |
| `Model/TagStore :: apply`, `write` | `MetadataEditTests/tagsGoOnTheChosenFilesOnly`, `FileCommandOwnershipTests/tagsNeverGoOnItemsOfTheirWindowsCopies` |
| `Model/Trash :: removeTree` | `DeleteTests/emptyingATrashDeletesWhatsInItAndNothingElse`, `aTrashThatIsALinkIsNeverFollowed`, `aLockedItemInTheTrashIsReportedAndTheRestGo`, `aFolderThatCantBeListedWholeKeepsWhatsInItAndIsReported`, `anItemThatWentMeanwhileIsntAFailureAndHidesNoOther` |
| `Remote/LazyCopies :: newFolder` (stages a clipboard copy) | `RemoteFilesTests/theClipboardGetsAFinishedCopy` |
| `Remote/RemoteCopyStore :: setAsideForRemoval` | `RemoteFilesTests/listsIntoTheCopy`; `CacheRemovalTests/settingCopiesAsideRemovesOnlyThemAtQuit` |
| `Remote/RemoteCopyStore :: prepare`, `remove` | `RemoteCopyOwnershipTests/preparingCopiesRefusesInvalidIDsAndReplacementLinks`, `removingCopiesNeverFollowsAReplacedRootOrAChildLink` |
| `Remote/RemoteFiles :: list`, `makeFile`, `rename`, `move`, `fetch`, `place` | `RemoteFilesTests/*`; `ServerSafetyTests/*` |
| `Remote/RemoteSession :: rename`, `upload` (S3) | `S3Tests` rows above (in `DeleteScopeTests`) |
| `Remote/S3Client :: download`, `Connections/SFTPClient :: init`, `rename`, `setTimes`, `download`, `upload` | `S3Tests/downloadsStopAtTheListedSize`; `SFTPClientTests/*` |
| `Settings/SettingsWindowController :: install` | `DeleteScopeTests/theCommandReplacesOnlyItsOwnLink` |
| `Sidebar/SidebarViewController :: menuNeedsUpdate`, `ejectItem`; `Window/BrowserWindowController :: focusSearch`, `ejectVolume`, `validateMenuItem` (Eject) | not a file change; see above |
| `Transfers/Archiver :: compress`, `extractContents`, `unpack`, `check`, `checkItem`, `clearFlagsAndAccessList`, `checkedPermissions`, `markQuarantined`, `place`, `removeEntry`, `run` (`ditto`) | `MetadataEditTests/compressingAddsOneArchiveAndNeverReplacesOne`, `aLinkIsArchivedAsALink`; `ArchiveSafetyTests/*`; `CacheRemovalTests/removingATreeNeverFollowsALinkOut` |
| `Transfers/ArchiveWriter :: run`, `writeFolder`, `writeLink`, `writeHardLink`, `folder`, `openFolder`, `subfolder`, `finish`, `apply`, `setTimes` (write what Extract's worker sends into the private folder being extracted into) | `ArchiveWriterTests/*`; `ArchiveExtractTests/*`; `ArchiveSafetyTests/*` |
| `Transfers/TransferEngine :: fail`, `renameInPlace`, `replaceExisting`, `copy`, `copyfile`, `rename`, `trash`, `removeIfPresent`, `removeOwned`, `removeOwnedTree`, `removeSource`; `Transfers/TransferSession :: repairOwnedDirectory` | `TransferTests/*` |
| `Queue/TransferQueue :: start`, `renameOnOneDisk` (undo's moves) | `TrashUndoTests/undoingAMoveJobMovesBackOnlyItsOwnItems`, `AcrossDisksTests/*`, `TransferTests/sameDiskUndoStepsNeverAdoptItemsReplacedBeforeRegistration` (captured identity, conflicts, replacements, failed moves and repeated Undo/Redo) |
| `Views/ClickToRename :: clicked` | `InlineRenameTests/*` |
| `Toolbar/BrowserToolbar :: toolbarDidRemoveItem` | `ToolbarCustomizationTests/*`; removes UI references only, not files; see the exemption above. |
| `Window/Workspaces :: rename`, `askToRename` (a workspace's name, saved settings) | `WorkspaceTests/*` |

| `Model/ChosenFile :: remove` | `SecurityReviewTests/deletionKeepsReplacementsAcrossTheConfirmation`, `deletionKeepsAnAncestorReplacedByAnotherDirectoryOrLink`; `DeleteTests/*` |
| `Model/FileInfoEditing :: updated` (local mode decision and the descriptor writes in its caller) | `MetadataEditTests/permissionsChangeOnlyThatAccessOnThatItem`; `SecurityReviewTests/metadataDescriptorsStayWithTheChosenFile` |
| `Remote/RemoteSession :: replaceWithoutExtension` | `SecurityReviewTests/standardSFTP*` |
| `Transfers/Archiver :: checkedPermissions`, `clearFlagsAndAccessList` | `ArchiveSecurityReviewTests/lockedArchiveItemsLoseFlagsPrivilegesAndAccessLists` |
