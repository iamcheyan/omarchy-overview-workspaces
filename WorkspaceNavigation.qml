pragma Singleton
pragma ComponentBehavior: Bound
import "."

import QtQuick
import Quickshell
import Quickshell.Hyprland

Singleton {
    id: root

    property int pendingDragRefreshes: 0

    Timer {
        id: refreshAfterDragTimer
        interval: 90
        repeat: false
        onTriggered: {
            ServiceManager.workspace.updateAll();
            GlobalStates.refreshOverviewModel();
            root.pendingDragRefreshes -= 1;
            if (root.pendingDragRefreshes > 0)
                refreshAfterDragTimer.restart();
        }
    }
    function overviewModel() {
        if (OverviewSwitchingController.grabbed)
            return switchingModeModel();
        // The keyboard must walk exactly the cards on screen. Without this, in
        // per-monitor mode the arrow keys step onto workspaces belonging to another
        // monitor that this overlay does not draw.
        if (GlobalStates.overviewPerMonitor) {
            const anchor = GlobalStates.overviewAnchorMonitorName
                || Hyprland.focusedMonitor?.name
                || "";
            if (anchor.length > 0) {
                const scoped = ServiceManager.workspace.overviewWorkspaceEntriesForMonitor(anchor, true, {}, false, true);
                if (scoped.length > 0)
                    return scoped;
            }
        }
        return ServiceManager.workspace.overviewWorkspaceEntriesGroupedByMonitor();
    }

    function switchingModeModel() {
        const monitorName = GlobalStates.overviewAnchorMonitorName || Hyprland.focusedMonitor?.name || "";
        // Win+Tab is a transient switcher, so it intentionally keeps MRU order.
        // Normal Overview uses WorkspaceOrder's persistent visual order.
        let model = ServiceManager.workspace.overviewWorkspaceEntriesForMonitor(monitorName, true, {}, true, false);
        if (model.length === 0)
            model = ServiceManager.workspace.overviewWorkspaceEntriesGlobal(true).filter(entry => !entry.isTrailingEmpty);
        return model;
    }

    function gridColumnsForModel(model) {
        return Math.min(Math.max(model.length, 1), Config.options.overview.columns);
    }

    function indexForWorkspace(model, wsId) {
        const idx = model.findIndex(entry => entry.id === wsId);
        return idx >= 0 ? idx : 0;
    }

    function currentWorkspaceId() {
        const anchorName = GlobalStates.overviewOpen ? GlobalStates.overviewAnchorMonitorName : "";
        const monitor = anchorName.length > 0
            ? ServiceManager.workspace.monitors.find(mon => mon.name === anchorName)
            : (Hyprland.focusedMonitor ?? Hyprland.monitors[0]);
        if (!monitor)
            return ServiceManager.workspace.activeWorkspace?.id ?? 1;
        return ServiceManager.workspace.monitorActiveWorkspaceId(monitor) || ServiceManager.workspace.activeWorkspace?.id || 1;
    }

    function focusedWorkspaceId() {
        if (GlobalStates.overviewFocusedWorkspaceId > 0)
            return GlobalStates.overviewFocusedWorkspaceId;
        return root.currentWorkspaceId();
    }

    function selectWorkspace(wsId) {
        if (wsId < 1)
            return;
        GlobalStates.overviewFocusedWorkspaceId = wsId;
    }

    function dispatchFocusWorkspace(wsId) {
        if (wsId < 1)
            return;
        const ws = ServiceManager.workspace.workspaceDataForId(wsId);
        if (ws?.monitor)
            Hyprland.dispatch(`hl.dsp.focus({monitor="${ws.monitor}"})`);
        Hyprland.dispatch(`hl.dsp.focus({ workspace = ${wsId} })`);
    }

    function navigateByIndex(delta, includeTrailing) {
        const allowTrailing = includeTrailing ?? true;
        const model = allowTrailing
            ? root.overviewModel()
            : root.overviewModel().filter(entry => !entry.isTrailingEmpty);
        if (model.length === 0)
            return;

        const ws = root.focusedWorkspaceId();
        let idx = root.indexForWorkspace(model, ws);
        idx = (idx + delta + model.length) % model.length;
        root.selectWorkspace(model[idx].id);
    }

    function navigateGrid(deltaRow, deltaCol) {
        const model = root.overviewModel();
        const n = model.length;
        if (n === 0)
            return;

        const cols = root.gridColumnsForModel(model);
        if (deltaCol !== 0)
            root.navigateByIndex(deltaCol);
        else if (deltaRow !== 0)
            root.navigateByIndex(deltaRow * cols);
    }

    function focusedEntryIsTrailingEmpty() {
        const wsId = root.focusedWorkspaceId();
        if (wsId < 1)
            return false;
        const model = root.overviewModel();
        for (let i = 0; i < model.length; i++) {
            if (model[i].id === wsId)
                return !!model[i].isTrailingEmpty;
        }
        return false;
    }

    function focusedEntry() {
        const wsId = root.focusedWorkspaceId();
        if (wsId < 1)
            return null;
        const model = root.overviewModel();
        for (let i = 0; i < model.length; i++) {
            if (model[i].id === wsId)
                return model[i];
        }
        return null;
    }

    function focusMonitorForEntry(entry) {
        const monitorName = entry?.monitorName ?? "";
        if (monitorName.length > 0)
            Hyprland.dispatch(`hl.dsp.focus({monitor="${monitorName}"})`);
    }

    function commitSelectedWorkspace() {
        if (root.focusedEntryIsTrailingEmpty()) {
            const entry = root.focusedEntry();
            root.focusMonitorForEntry(entry);
            Hyprland.dispatch(`hl.dsp.focus({ workspace = ${entry.id} })`);
            if ((entry?.monitorName ?? "").length > 0)
                Hyprland.dispatch(`hl.dsp.workspace.move({ workspace = "${entry.id}", monitor = "${entry.monitorName}" })`);
            return;
        }

        if (GlobalStates.overviewFocusedWorkspaceId > 0)
            root.dispatchFocusWorkspace(GlobalStates.overviewFocusedWorkspaceId);
    }

    function resetOverviewDragState() {
        GlobalStates.overviewDraggingFromWorkspace = -1;
        GlobalStates.overviewDraggingTargetWorkspace = -1;
        GlobalStates.overviewDraggingTargetIsTrailing = false;
    }

    function beginWindowDrag(fromWorkspaceId) {
        GlobalStates.overviewDraggingFromWorkspace = fromWorkspaceId ?? -1;
    }

    function setDragTarget(workspaceId, isTrailing) {
        GlobalStates.overviewDraggingTargetWorkspace = workspaceId;
        GlobalStates.overviewDraggingTargetIsTrailing = isTrailing;
    }

    function clearDragTarget(workspaceId) {
        if (GlobalStates.overviewDraggingTargetWorkspace === workspaceId) {
            GlobalStates.overviewDraggingTargetWorkspace = -1;
            GlobalStates.overviewDraggingTargetIsTrailing = false;
        }
    }

    function commitWindowDrag(windowAddress, currentWorkspaceId, targetWorkspace, targetIsTrailing) {
        root.resetOverviewDragState();
        if (!windowAddress || targetWorkspace === -1 || targetWorkspace === currentWorkspaceId)
            return false;

        const sourceVisibleWindows = ServiceManager.workspace.hyprlandClientsForWorkspace(currentWorkspaceId)
            .filter(win => win.mapped && !win.hidden);
        const sourceIsEmptyAfterMove = sourceVisibleWindows.length <= 1;

        const model = root.overviewModel();
        const entry = model.find(item => item.id === targetWorkspace);
        const targetMonitorName = entry?.monitorName ?? "";

        GlobalStates.setPendingWindowWorkspace(windowAddress, targetWorkspace);

        if (targetMonitorName.length > 0) {
            const pending = GlobalStates.overviewPendingWorkspaceMonitorById ?? {};
            const nextPending = Object.assign({}, pending);
            nextPending[targetWorkspace] = targetMonitorName;
            GlobalStates.overviewPendingWorkspaceMonitorById = nextPending;
        }

        if (targetIsTrailing) {
            const pendingOccupied = GlobalStates.overviewPendingOccupiedWorkspaces ?? [];
            const filtered = pendingOccupied.filter(entry => entry?.id !== targetWorkspace);
            filtered.push({
                id: targetWorkspace,
                monitorName: targetMonitorName,
                sourceWorkspaceId: currentWorkspaceId
            });
            GlobalStates.overviewPendingOccupiedWorkspaces = filtered;
            Hyprland.dispatch(`hl.dsp.window.move({ workspace = ${targetWorkspace}, follow = false, window = "address:${windowAddress}" })`);
            if (targetMonitorName.length > 0)
                Hyprland.dispatch(`hl.dsp.workspace.move({ workspace = "${targetWorkspace}", monitor = "${targetMonitorName}" })`);
        } else {
            Hyprland.dispatch(`hl.dsp.window.move({ workspace = ${targetWorkspace}, follow = false, window = "address:${windowAddress}" })`);
            if (targetMonitorName.length > 0)
                Hyprland.dispatch(`hl.dsp.workspace.move({ workspace = "${targetWorkspace}", monitor = "${targetMonitorName}" })`);
        }

        if (sourceIsEmptyAfterMove) {
            const suppressed = GlobalStates.overviewSuppressedEmptyWorkspaceIds ?? [];
            if (!suppressed.includes(currentWorkspaceId)) {
                const next = suppressed.slice();
                next.push(currentWorkspaceId);
                GlobalStates.overviewSuppressedEmptyWorkspaceIds = next;
            }
        }

        GlobalStates.refreshOverviewModel();
        root.pendingDragRefreshes = 4;
        refreshAfterDragTimer.restart();
        return true;
    }

    function focusWindow(windowData) {
        if (!windowData?.address)
            return;
        if (windowData?.workspace?.id > 0)
            GlobalStates.promoteWorkspaceMru(windowData.workspace.id);
        Hyprland.dispatch(`hl.dsp.focus({window = "address:${windowData.address}"})`);
    }
}
