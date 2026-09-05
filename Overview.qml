pragma ComponentBehavior: Bound
import "."
import qs.Commons
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Hyprland._GlobalShortcuts 0.0
import "ColorUtils.js" as ColorUtils

Scope {
    id: overviewScope

    // Omarchy's panel host calls these for `shell summon/hide/toggle`.
    function open(payload) {
        GlobalStates.overviewWarmStart = false;
        GlobalStates.overviewOpen = true;
    }

    function close() {
        GlobalStates.overviewOpen = false;
    }

    function toggle() {
        GlobalStates.overviewOpen = !GlobalStates.overviewOpen;
    }

    property string lockedScreenName: ""
    property string overviewFilterQuery: ""
    property var focusedScreen: Quickshell.screens.find(s => s.name === (overviewScope.lockedScreenName || Hyprland.focusedMonitor?.name))
        ?? Quickshell.screens[0]
        ?? null

    signal requestOverviewFocus()

    function navigateOverviewByIndex(delta) {
        WorkspaceNavigation.navigateByIndex(delta);
    }

    function navigateOverviewGrid(deltaRow, deltaCol) {
        WorkspaceNavigation.navigateGrid(deltaRow, deltaCol);
    }

    function queueGrabbedCycle(dir) {
        OverviewSwitchingController.queueCycle(dir);
    }

    function queueOverviewFocus() {
        OverviewSwitchingController.queueFocus();
    }

    function openGrabbedMode(dir) {
        OverviewSwitchingController.openGrabbedMode(dir);
    }

    function commitGrabbedMode() {
        OverviewSwitchingController.commitGrabbedMode();
    }

    function overviewNavigationActive() {
        return OverviewSwitchingController.navigationOpen();
    }

    function handleOverviewNavigationKey(event) {
        if (!overviewScope.overviewNavigationActive())
            return;

        if (event.key === Qt.Key_Left || event.key === Qt.Key_H) {
            overviewScope.navigateOverviewGrid(0, -1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_L) {
            overviewScope.navigateOverviewGrid(0, 1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
            overviewScope.navigateOverviewGrid(-1, 0);
            event.accepted = true;
        } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
            overviewScope.navigateOverviewGrid(1, 0);
            event.accepted = true;
        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            const backward = (event.key === Qt.Key_Backtab) || ((event.modifiers & Qt.ShiftModifier) !== 0);
            overviewScope.navigateOverviewByIndex(backward ? -1 : 1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            WorkspaceNavigation.commitSelectedWorkspace();
            GlobalStates.overviewOpen = false;
            event.accepted = true;
        }
    }

    function isFocusedScreen(screen) {
        return screen?.name === overviewScope.focusedScreen?.name;
    }

    function currentWorkspaceId() {
        return WorkspaceNavigation.currentWorkspaceId();
    }

    // Numeric workspace shortcuts address global visual slots, not raw
    // Hyprland IDs. Use the same monitor-grouped model rendered by Overview so
    // numbering continues across monitors. The trailing slot's raw ID may
    // recycle an empty workspace, so always relocate it to the target monitor
    // rather than gating on whether it pre-existed.
    function focusWorkspaceSlot(slot) {
        if (slot < 1)
            return;

        let entries = ServiceManager.workspace.overviewWorkspaceEntries ?? [];
        if (entries.length === 0)
            entries = ServiceManager.workspace.overviewWorkspaceEntriesGlobal();

        const entry = entries[slot - 1];
        if (!entry)
            return;

        GlobalStates.superReleaseMightTrigger = false;
        GlobalStates.overviewOpen = false;

        if ((entry.monitorName ?? "").length > 0)
            Hyprland.dispatch(`hl.dsp.focus({monitor="${entry.monitorName}"})`);

        Hyprland.dispatch(`hl.dsp.focus({ workspace = ${entry.id} })`);
        if (entry.isTrailingEmpty && (entry.monitorName ?? "").length > 0)
            Hyprland.dispatch(`hl.dsp.workspace.move({ workspace = "${entry.id}", monitor = "${entry.monitorName}" })`);

        if (!entry.isTrailingEmpty && ServiceManager.workspace.workspaceHasVisibleWindows(entry.id))
            GlobalStates.promoteWorkspaceMru(entry.id);
    }

    Connections {
        target: Hyprland
        function onFocusedMonitorChanged() {
            if (GlobalStates.overviewOpen)
                return;
            overviewScope.queueOverviewFocus();
        }
    }

    Connections {
        target: GlobalStates
        function onOverviewOpenChanged() {
            if (GlobalStates.overviewOpen) {
                const anchor = Hyprland.focusedMonitor?.name ?? "";
                overviewScope.lockedScreenName = anchor;
                GlobalStates.overviewAnchorMonitorName = anchor;
            } else {
                overviewScope.lockedScreenName = "";
                GlobalStates.overviewAnchorMonitorName = "";
                GlobalStates.overviewPendingWorkspaceMonitorById = ({});
                GlobalStates.overviewPendingOccupiedWorkspaces = [];
            }
            overviewScope.setNativeMouseGuard(GlobalStates.overviewOpen);
        }
    }

    // Overview owns the state in this process. Keep Hyprland's native
    // Super+mouse operations out of the preview drag surface only while this
    // UI is active, then restore exactly those two native operations.
    function setNativeMouseGuard(guarded) {
        const commands = [
            'hl.unbind("SUPER + mouse:272")',
            'hl.unbind("SUPER + mouse:273")'
        ];
        if (!guarded) {
            commands.push('hl.bind("SUPER + mouse:272", hl.dsp.window.drag(), { mouse = true, description = "Move window" })');
            commands.push('hl.bind("SUPER + mouse:273", hl.dsp.window.resize(), { mouse = true, description = "Resize window" })');
        }
        Quickshell.execDetached(["hyprctl", "eval", commands.join("; ")]);
    }

    Connections {
        target: OverviewSwitchingController
        function onGrabbedChanged() {
            overviewScope.setNativeMouseGuard(GlobalStates.overviewOpen || OverviewSwitchingController.grabbed);
        }
    }

    Component.onDestruction: overviewScope.setNativeMouseGuard(false)

    // Keep MRU in sync when the user switches workspaces outside of overview
    // (e.g. via Hyprland keybindings). While overview is open the MRU is frozen.
    // Empty workspaces (incl. the trailing "New workspace" slot) are never
    // promoted — only workspaces with windows participate in MRU ordering.
    Connections {
        target: ServiceManager.workspace
        function onActiveWorkspaceChanged() {
            if (GlobalStates.overviewOpen)
                return;
            const wsId = ServiceManager.workspace.activeWorkspace?.id ?? 0;
            if (wsId > 0 && ServiceManager.workspace.workspaceHasVisibleWindows(wsId))
                GlobalStates.promoteWorkspaceMru(wsId);
        }
    }

    Variants {
        model: Quickshell.screens

        LazyLoader {
            id: overviewPanelLoader
            required property ShellScreen modelData
            active: true

            component: PanelWindow {
            id: panelWindow
            screen: overviewPanelLoader.modelData
            readonly property HyprlandMonitor monitor: Hyprland.monitorFor(panelWindow.screen)
            readonly property bool isFocusedOverviewWindow: overviewScope.isFocusedScreen(panelWindow.screen)
            visible: GlobalStates.overviewOpen
                && (!OverviewSwitchingController.grabbed || panelWindow.isFocusedOverviewWindow)

            WlrLayershell.namespace: "quickshell:overview"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: panelWindow.isFocusedOverviewWindow
                ? (GlobalStates.overviewOpen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None)
                : WlrKeyboardFocus.None
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"

            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }

            Connections {
                target: GlobalStates
                function onOverviewOpenChanged() {
                    if (!GlobalStates.overviewOpen) {
                        const settled = GlobalStates.overviewFocusedWorkspaceId > 0
                            ? GlobalStates.overviewFocusedWorkspaceId
                            : overviewScope.currentWorkspaceId();
                        if (settled > 0 && ServiceManager.workspace.workspaceHasVisibleWindows(settled))
                            GlobalStates.promoteWorkspaceMru(settled);
                        OverviewSwitchingController.reset();
                        GlobalStates.overviewFocusedWorkspaceId = -1;
                        WorkspaceNavigation.resetOverviewDragState();
                        GlobalFocusGrab.dismiss();
                    } else {
                        GlobalStates.overviewFocusedWorkspaceId = overviewScope.currentWorkspaceId();
                        if (GlobalStates.overviewWorkspaceMru.length === 0)
                            GlobalStates.promoteWorkspaceMru(overviewScope.currentWorkspaceId());
                        if (!OverviewSwitchingController.grabbed || panelWindow.isFocusedOverviewWindow)
                            GlobalFocusGrab.addDismissable(panelWindow);
                        overviewScope.queueOverviewFocus();
                    }
                }
            }

            Connections {
                target: GlobalFocusGrab
                function onDismissed() {
                    if (!OverviewSwitchingController.grabbed)
                        GlobalStates.overviewOpen = false;
                }
            }

            implicitWidth: panelWindow.width
            implicitHeight: panelWindow.height

            // ── Overview (工作区概览): full-screen scrim + large grid ──
            Rectangle {
                id: scrim
                anchors.fill: parent
                color: ColorUtils.transparentize(Color.background, 0.25)
                visible: GlobalStates.overviewOpen
                opacity: GlobalStates.overviewOpen ? 1 : 0

                Behavior on opacity {
                    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
                }

                // Click scrim to close
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        if (GlobalStates.overviewSearchMode) {
                            GlobalStates.overviewSearchMode = false;
                            overviewScope.overviewFilterQuery = "";
                        } else {
                            GlobalStates.overviewOpen = false;
                        }
                    }
                }
            }

            Item {
                id: overviewKeyHandler
                anchors.fill: parent
                z: 999
                focus: panelWindow.isFocusedOverviewWindow

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) {
                        if (GlobalStates.overviewSearchMode) {
                            GlobalStates.overviewSearchMode = false;
                            overviewScope.overviewFilterQuery = "";
                            event.accepted = true;
                            return;
                        }
                        GlobalStates.overviewOpen = false;
                        event.accepted = true;
                        return;
                    }
                    // Search mode owns Tab (it moves the result selection), so this
                    // workspace-cycling branch has to stand down while it is on --
                    // it returns unconditionally and would otherwise shadow the
                    // search handler further down.
                    if (!GlobalStates.overviewSearchMode
                        && (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)) {
                        const backward = (event.key === Qt.Key_Backtab) || ((event.modifiers & Qt.ShiftModifier) !== 0);
                        if (OverviewSwitchingController.grabbed) {
                            overviewScope.queueGrabbedCycle(backward ? -1 : 1);
                        } else {
                            overviewScope.navigateOverviewByIndex(backward ? -1 : 1);
                        }
                        event.accepted = true;
                        return;
                    }
                    if (OverviewSwitchingController.grabbed) {
                        overviewScope.handleOverviewNavigationKey(event);
                        return;
                    }
                    // ── Search mode keyboard handling ──
                    if (GlobalStates.overviewSearchMode) {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            overviewSearch.activateSelection();
                            event.accepted = true;
                            return;
                        }
                        if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab) {
                            const backward = event.key === Qt.Key_Tab
                                && (event.modifiers & Qt.ShiftModifier) !== 0;
                            overviewSearch.moveSelection(backward ? -1 : 1);
                            event.accepted = true;
                            return;
                        }
                        if (event.key === Qt.Key_Up) {
                            overviewSearch.moveSelection(-1);
                            event.accepted = true;
                            return;
                        }
                        if (event.key === Qt.Key_Backspace) {
                            overviewScope.overviewFilterQuery = overviewScope.overviewFilterQuery.slice(0, -1);
                            event.accepted = true;
                            return;
                        }
                        if (event.key === Qt.Key_Delete) {
                            overviewScope.overviewFilterQuery = "";
                            GlobalStates.overviewSearchMode = false;
                            event.accepted = true;
                            return;
                        }
                        if (event.text.length > 0
                            && !(event.modifiers & Qt.ControlModifier)
                            && !(event.modifiers & Qt.AltModifier)
                            && !(event.modifiers & Qt.MetaModifier)
                            && event.key !== Qt.Key_Tab) {
                            overviewScope.overviewFilterQuery += event.text;
                            event.accepted = true;
                            return;
                        }
                        overviewScope.handleOverviewNavigationKey(event);
                        return;
                    }
                    // Entering search mode. With vim keys on, only "/" does it,
                    // which leaves every letter -- h/j/k/l included -- free to
                    // navigate; with them off the first character typed both opens
                    // search and becomes the query.
                    if (!GlobalStates.overviewSearchMode) {
                        const plainKey = event.text.length > 0
                            && !(event.modifiers & Qt.ControlModifier)
                            && !(event.modifiers & Qt.AltModifier)
                            && !(event.modifiers & Qt.MetaModifier)
                            && event.key !== Qt.Key_Backspace
                            && event.key !== Qt.Key_Delete
                            && event.key !== Qt.Key_Tab
                            && event.key !== Qt.Key_Space;
                        const vim = GlobalStates.overviewVimKeys;
                        if (vim ? (plainKey && event.key === Qt.Key_Slash) : plainKey) {
                            // "/" is the trigger, not the first character of the
                            // query, so it must not land in the text.
                            overviewScope.overviewFilterQuery = vim ? "" : event.text;
                            GlobalStates.overviewSearchMode = true;
                            event.accepted = true;
                            return;
                        }
                    }
                    // Arrow keys navigate workspaces in workspace mode
                    if (!GlobalStates.overviewSearchMode) {
                        overviewScope.handleOverviewNavigationKey(event);
                    }
                }

                Keys.onReleased: event => {
                    if (OverviewSwitchingController.grabbed &&
                        (event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R || event.key === Qt.Key_Meta)) {
                        overviewScope.commitGrabbedMode();
                        event.accepted = true;
                    }
                }

                Connections {
                    target: GlobalStates
                    function onOverviewOpenChanged() {
                        if (!GlobalStates.overviewOpen) {
                            GlobalStates.overviewSearchMode = false;
                            overviewScope.overviewFilterQuery = "";
                        }
                        if (GlobalStates.overviewOpen
                            && panelWindow.isFocusedOverviewWindow
                            && !OverviewSwitchingController.grabbed
                            && !GlobalStates.overviewSearchMode)
                            overviewKeyHandler.forceActiveFocus();
                    }
                    function onOverviewSearchModeChanged() {
                        if (!GlobalStates.overviewSearchMode)
                            overviewScope.overviewFilterQuery = "";
                        if (!GlobalStates.overviewSearchMode
                            && panelWindow.isFocusedOverviewWindow
                            && GlobalStates.overviewOpen
                            && !OverviewSwitchingController.grabbed)
                            Qt.callLater(() => { overviewKeyHandler.forceActiveFocus(); });
                    }
                    function onSuperDownChanged() {
                        if (OverviewSwitchingController.grabbed && !GlobalStates.superDown)
                            overviewScope.commitGrabbedMode();
                    }
                }

                Connections {
                    target: overviewScope
                    function onRequestOverviewFocus() {
                        if (panelWindow.isFocusedOverviewWindow && OverviewSwitchingController.grabbed)
                            overviewKeyHandler.forceActiveFocus();
                    }
                }

                Connections {
                    target: OverviewSwitchingController
                    function onRequestFocus() {
                        overviewScope.requestOverviewFocus();
                    }
                    function onGrabbedChanged() {
                        if (panelWindow.isFocusedOverviewWindow && OverviewSwitchingController.grabbed)
                            overviewKeyHandler.forceActiveFocus();
                    }
                }
            }

            // ── Overview (工作区概览): large workspace grid filling the screen ──
            Item {
                id: overviewContainer
                anchors.fill: parent
                visible: GlobalStates.overviewOpen
                // Do not paint the half-built grid. The loader is synchronous
                // so the workspace geometry is ready before the first frame;
                // the short fade hides the remaining capture startup frame.
                opacity: GlobalStates.overviewOpen && overviewLoader.status === Loader.Ready ? 1 : 0

                Behavior on opacity {
                    NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                }

                Loader {
                    id: overviewLoader
                    anchors.fill: parent
                    // Do not keep the complete OverviewWidget tree alive while
                    // hidden. It contains every workspace/window model and
                    // ScreencopyView; after suspend/resume that hidden tree can
                    // keep the shell's main thread busy and can lose its capture
                    // context. Recreate it when Overview opens instead.
                    // Keep ScreencopyView alive only while Overview is open.
                    // Leaving it mounted behind the panel causes capture
                    // contexts to compete with the desktop and fail during
                    // drag/move operations.
                    asynchronous: false
                    active: (Config?.options.overview.enable ?? true)
                        && GlobalStates.overviewOpen
                    sourceComponent: OverviewWidget {
                        screen: panelWindow.screen
                        visible: GlobalStates.overviewOpen
                    }
                }

                OverviewSearch {
                    id: overviewSearch
                    anchors.fill: parent
                    z: 1200
                    visible: panelWindow.isFocusedOverviewWindow
                        && !OverviewSwitchingController.grabbed
                    searchMode: GlobalStates.overviewSearchMode
                    query: overviewScope.overviewFilterQuery

                    onSearchRequested: {
                        GlobalStates.overviewSearchMode = true;
                        overviewKeyHandler.forceActiveFocus();
                    }
                    onCloseRequested: {
                        GlobalStates.overviewSearchMode = false;
                        overviewScope.overviewFilterQuery = "";
                    }
                }

            }

        }
        }
    }

    GlobalShortcut {
        name: "overviewWorkspacesClose"
        description: "Closes overview on press"

        onPressed: {
            GlobalStates.overviewOpen = false;
        }
    }
    GlobalShortcut {
        name: "overviewWorkspacesToggle"
        description: "Toggles overview on press"

        onPressed: {
            GlobalStates.overviewOpen = !GlobalStates.overviewOpen;
        }
    }
    property real lastWheelShortcut: 0

    GlobalShortcut {
        name: "overviewNext"
        description: "Workspace overview: cycle next (Win+Tab)"
        onPressed: {
            GlobalStates.superReleaseMightTrigger = false;
            const now = Date.now();
            if (now - overviewScope.lastWheelShortcut < 150) return;
            overviewScope.lastWheelShortcut = now;
            overviewScope.openGrabbedMode(1);
        }
    }
    GlobalShortcut {
        name: "overviewPrev"
        description: "Workspace overview: cycle prev (Win+Shift+Tab)"
        onPressed: {
            GlobalStates.superReleaseMightTrigger = false;
            const now = Date.now();
            if (now - overviewScope.lastWheelShortcut < 150) return;
            overviewScope.lastWheelShortcut = now;
            overviewScope.openGrabbedMode(-1);
        }
    }
    GlobalShortcut {
        name: "overviewCommit"
        description: "Workspace overview: commit on Win release"
        onPressed: {
            GlobalStates.superReleaseMightTrigger = false;
            overviewScope.commitGrabbedMode()
        }
    }

    GlobalShortcut {
        name: "workspaceSlot1"
        description: "Focus Overview workspace slot 1"
        onPressed: overviewScope.focusWorkspaceSlot(1)
    }
    GlobalShortcut {
        name: "workspaceSlot2"
        description: "Focus Overview workspace slot 2"
        onPressed: overviewScope.focusWorkspaceSlot(2)
    }
    GlobalShortcut {
        name: "workspaceSlot3"
        description: "Focus Overview workspace slot 3"
        onPressed: overviewScope.focusWorkspaceSlot(3)
    }
    GlobalShortcut {
        name: "workspaceSlot4"
        description: "Focus Overview workspace slot 4"
        onPressed: overviewScope.focusWorkspaceSlot(4)
    }
    GlobalShortcut {
        name: "workspaceSlot5"
        description: "Focus Overview workspace slot 5"
        onPressed: overviewScope.focusWorkspaceSlot(5)
    }
    GlobalShortcut {
        name: "workspaceSlot6"
        description: "Focus Overview workspace slot 6"
        onPressed: overviewScope.focusWorkspaceSlot(6)
    }
    GlobalShortcut {
        name: "workspaceSlot7"
        description: "Focus Overview workspace slot 7"
        onPressed: overviewScope.focusWorkspaceSlot(7)
    }
    GlobalShortcut {
        name: "workspaceSlot8"
        description: "Focus Overview workspace slot 8"
        onPressed: overviewScope.focusWorkspaceSlot(8)
    }
    GlobalShortcut {
        name: "workspaceSlot9"
        description: "Focus Overview workspace slot 9"
        onPressed: overviewScope.focusWorkspaceSlot(9)
    }
    GlobalShortcut {
        name: "workspaceSlot10"
        description: "Focus Overview workspace slot 10"
        onPressed: overviewScope.focusWorkspaceSlot(10)
    }
}
