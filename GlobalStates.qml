import "."
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Hyprland._GlobalShortcuts 0.0
pragma Singleton
pragma ComponentBehavior: Bound

Singleton {
    id: root
    property bool barOpen: true
    property bool clipboardOpen: false
    property bool osdBrightnessOpen: false
    property bool osdVolumeOpen: false
    property bool osdInputMethodOpen: false
    property real osdBrightnessValue: -1
    // Monitor name the brightness OSD should pin to (empty = focused screen).
    property string osdBrightnessScreen: ""
    property bool overviewOpen: false
    property string overviewAnchorMonitorName: ""
    property bool overviewSearchMode: false
    // The plugin's optimized visual ordering is the default. The persisted
    // setting can still switch to the native Omarchy order explicitly.
    property string overviewSortMode: "legacy"
    // When true, h/j/k/l keep navigating workspaces and search opens on "/" --
    // the vim idiom. When false any printable character opens search, which is
    // quicker but takes those keys away from navigation.
    property bool overviewVimKeys: true
    // Each overlay draws only its own monitor's workspaces. Persisted to the bar
    // widget entry in shell.json, the same way overviewSortMode is.
    property bool overviewPerMonitor: true
    property int overviewFocusedWorkspaceId: -1
    property var overviewWorkspaceMru: []
    property int overviewDraggingFromWorkspace: -1
    property int overviewDraggingTargetWorkspace: -1
    property bool overviewDraggingTargetIsTrailing: false
    // Monitor the target workspace belongs to, which is not the monitor drawing
    // it: with per-monitor preview off, every overlay draws every workspace.
    property string overviewDraggingTargetMonitor: ""
    property var overviewSuppressedEmptyWorkspaceIds: []
    property var overviewPendingWorkspaceMonitorById: ({})
    property var overviewPendingOccupiedWorkspaces: []
    property var overviewPendingWindowWorkspaceByAddress: ({})
    property int overviewRefreshSerial: 0
    property bool regionSelectorOpen: false
    property bool screenshotActive: false
    property bool screenLocked: false
    property bool screenLockContainsCharacters: false
    property bool screenUnlockFailed: false
    property bool superDown: false
    property bool superReleaseMightTrigger: false
    // The overview process is pre-warmed separately from the bar. During its
    // short startup window, a compositor-delivered Super release must not be
    // mistaken for a user request to open Overview.
    property bool overviewWarmStart: Quickshell.env("SUMIKA_OVERVIEW_WARM") === "1"
    // Overview controller, injected by the overview module at load time so the
    // Super-release shortcut can drive switching mode without a core→module
    // import dependency. Null in processes that don't load the overview module.
    property var overviewSwitchingController: null
    property string barPopupType: ""
    // Screen name of the bar that opened the popup (multi-monitor: pin panel + brightness).
    property string barPopupAnchorScreen: ""
    // Ephemeral popups (e.g. volume OSD) auto-close; pinned ones stay until dismissed.
    property bool barPopupEphemeral: false
    property real barPopupDismissedAt: 0
    property bool sessionConfirmOpen: false
    property string sessionConfirmAction: ""
    // Label shown in the confirm dialog (set by requestSessionConfirm).
    property string sessionConfirmLabel: ""
    // Shared "save session on exit" preference (default on). The BarStatusPopup
    // checkbox binds to this; the right-click PowerContextMenu reads it so both
    // entry points honor the same choice.
    property bool sessionSaveOnExit: true

    Timer {
        id: overviewWarmStartTimer
        interval: 3000
        running: root.overviewWarmStart
        onTriggered: root.overviewWarmStart = false
    }

    function requestSessionConfirm(action, label) {
        GlobalStates.barPopupType = "";
        GlobalStates.sessionConfirmAction = action;
        GlobalStates.sessionConfirmLabel = label;
        GlobalStates.sessionConfirmOpen = true;
    }

    function closeSessionConfirm() {
        GlobalStates.sessionConfirmOpen = false;
        GlobalStates.sessionConfirmAction = "";
        GlobalStates.sessionConfirmLabel = "";
    }

    onOverviewOpenChanged: {
        if (GlobalStates.overviewOpen) {
            GlobalStates.clipboardOpen = false;
            GlobalStates.overviewSearchMode = false;
        }
    }

    // MRU (Most Recently Used) workspace list, mirroring Win11 Alt+Tab Z-order.
    // Promote `wsId` to the front of the list (Win11: switched window → top of Z-order).
    // The trailing "New workspace" slot never enters MRU — it is always last.
    function promoteWorkspaceMru(wsId) {
        if (wsId < 1)
            return;
        const next = GlobalStates.overviewWorkspaceMru.filter(id => id !== wsId);
        next.unshift(wsId);
        GlobalStates.overviewWorkspaceMru = next;
    }

    function refreshOverviewModel() {
        GlobalStates.overviewRefreshSerial += 1;
    }

    function setPendingWindowWorkspace(address, workspaceId) {
        const key = String(address ?? "");
        if (key.length === 0)
            return;
        const next = Object.assign({}, root.overviewPendingWindowWorkspaceByAddress ?? {});
        if (workspaceId > 0)
            next[key] = workspaceId;
        else
            delete next[key];
        root.overviewPendingWindowWorkspaceByAddress = next;
    }

    function suppressEmptyWorkspace(wsId) {
        if (wsId < 1)
            return;
        const current = GlobalStates.overviewSuppressedEmptyWorkspaceIds ?? [];
        if (current.includes(wsId))
            return;
        const next = current.slice();
        next.push(wsId);
        GlobalStates.overviewSuppressedEmptyWorkspaceIds = next;
    }

    function unsuppressWorkspace(wsId) {
        if (wsId < 1)
            return;
        GlobalStates.overviewSuppressedEmptyWorkspaceIds =
            (GlobalStates.overviewSuppressedEmptyWorkspaceIds ?? []).filter(id => id !== wsId);
    }

    onBarPopupTypeChanged: {
        if (!GlobalStates.barPopupType)
            GlobalStates.barPopupEphemeral = false;
    }

    GlobalShortcut {
        name: "workspaceNumber"
        description: "Hold to show workspace numbers, release to show icons"

        onPressed: {
            root.superDown = true
            root.superReleaseMightTrigger = true
        }
        onReleased: {
            root.superDown = false
            if (root.overviewWarmStart) {
                root.superReleaseMightTrigger = false
                return
            }
            if (root.overviewSwitchingController && root.overviewSwitchingController.grabbed) {
                root.superReleaseMightTrigger = false
                root.overviewSwitchingController.commitGrabbedMode()
                return
            }
            if (root.superReleaseMightTrigger) {
                root.superReleaseMightTrigger = false
                if (!GlobalStates.overviewOpen)
                    GlobalStates.overviewOpen = true
                else if (GlobalStates.overviewSearchMode)
                    GlobalStates.overviewSearchMode = false
                else if (!(root.overviewSwitchingController && root.overviewSwitchingController.grabbed))
                    GlobalStates.overviewOpen = false
            }
        }
    }

    GlobalShortcut {
        name: "superInterrupt"
        description: "Interrupt Super-alone overview toggle"

        onPressed: {
            root.superReleaseMightTrigger = false
        }
    }
}
