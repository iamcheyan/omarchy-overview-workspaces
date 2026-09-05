# Cross-monitor drag contract

This document defines the integration boundary for cross-monitor window dragging.
It is intentionally separate from keybinding ownership, thumbnail capture, icon
lookup, and workspace model refreshes.

## Responsibility boundary

`CrossMonitorDrag` may provide only the transient input state needed to bridge
the per-monitor `PanelWindow` surfaces:

- whether a cross-monitor drag is active;
- the dragged window address and source workspace;
- the pointer position in global logical coordinates;
- hit boxes published by the currently rendered workspace cards;
- an optional drag proxy image, owned only for the duration of the drag.

It must not bind, unbind, reload, or dispatch any keyboard shortcut. It must not
change `KeybindingService.qml`, the Super-key guard, or native Hyprland mouse
bindings.

## Two monitor identities

Every published target must keep these identities separate:

```text
surfaceMonitorName   the monitor whose overlay renders the hit box
workspaceMonitorName the monitor to which the workspace belongs
```

Global hit testing uses `surfaceMonitorName` and the hit box coordinates. The
drop commit uses `workspaceMonitorName` when routing the workspace or a new
workspace card. A workspace ID alone is never sufficient because trailing
workspace IDs can be allocated independently per monitor.

## Drag lifecycle

1. On a left-button press, the existing window-drag path remains responsible
   for snapshot/freeze behavior and position holding.
2. The bridge is started with a monotonically increasing drag generation.
3. All rendered overlays publish their current card rectangles. The registry
   must be refreshed when the active drag or card geometry changes.
4. Pointer updates are converted from the source surface to global logical
   coordinates. The destination proxy and highlight are derived from the
   registry; they do not create a second live window capture.
5. On release, read the target before tearing down `Drag.active`, resolve the
   workspace and its monitor, then call the existing
   `WorkspaceNavigation.commitWindowDrag` path.
6. End the bridge and release the existing held-position state on every exit
   path, including invalid targets and canceled drags.
7. An asynchronous preview callback may update state only if its generation is
   still active. Ending a drag must invalidate that generation.

## Existing behavior that must remain unchanged

- Same-monitor drag/drop behavior and trailing-workspace allocation.
- The current freeze-frame and thumbnail recapture logic.
- Application icon lookup and the program icon fallback.
- Workspace model refresh suppression while a window is being moved.
- Plugin shortcut isolation and restoration of native user shortcuts.
- The overview-time Super-key/native mouse protection.

## Acceptance criteria

- Dragging between workspaces on one monitor behaves exactly as before.
- Dragging to a workspace card on another monitor lands on that card's owning
  monitor, including duplicate trailing IDs.
- The destination monitor shows a proxy/highlight while the pointer is over it.
- A canceled drag leaves thumbnails, icons, focus, and drag state intact.
- Installing or uninstalling the plugin does not alter unrelated user
  keybindings.
- The change is based on the current `main`, passes plugin validation and
  existing tests, and is manually verified with two monitors using both
  horizontal and vertical layouts when available.

