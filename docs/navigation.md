# Pointer navigation

Strata uses mouse side buttons 3 and 4 for Back and Forward. They act on the pane under the pointer and give that
pane keyboard focus. Primary, secondary and middle clicks keep their normal behavior. Events stay within the
browser window; the app installs no global event monitor and needs no Accessibility permission for this feature.

Page-swipe gestures use macOS's own swipe tracking and the setting in System Settings. Horizontal scrolling in
Columns and Gallery keeps its existing meaning. Discrete page-swipe events and mouse buttons can still navigate
those views. Swipe directions mirror the window's layout direction.

A fluid swipe captures its pane and navigation revisions. Starting another folder open, changing the location or
view, removing that pane, closing the window, losing key status or cancelling the gesture prevents a late commit.
The gesture commits only once, after AppKit settles the swipe. Editable text keeps its scrolling and editing.

Headless tests send private synthetic mouse events directly to unshown browser windows, never to the system event
queue. They exercise both panes in all five views and control swipe completions to cover stale and cancelled work,
right-to-left layout and teardown. Hardware gesture feel and native animation still need a manual check on a
trackpad or Magic Mouse; these tests do not simulate physical touches.

# The sidebar's sections

In Places, the sidebar shows Favorites, Workspaces, Searches, Frequent, Insights, Locations, Servers and Tags, in that
order; a section with nothing in it is left out. With Settings ▸ General ▸ Coming from Windows ▸ This Mac in the
sidebar on, a This Mac section (your Desktop, Documents, Downloads, Pictures, Music and Movies folders, then the disks)
comes right after Favorites and Frequent, and the disks leave Locations (see docs/coming-from-windows.md).
`SidebarLayout.sectionIDs` gives the order. The Folders sidebar shows its tree either way.
