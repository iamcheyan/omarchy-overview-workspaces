pragma Singleton
pragma ComponentBehavior: Bound
import "."

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

/**
 * Provides access to some Hyprland data not available in Quickshell.Hyprland.
 */
Singleton {
    id: root
    property var windowList: []
    property var addresses: []
    property var windowByAddress: ({})
    property var workspaces: []
    property var workspaceIds: []
    property var workspaceById: ({})
    property bool clientsLoaded: false
    property bool monitorsLoaded: false
    property bool workspacesLoaded: false
    // activeWorkspace: derived from the native Quickshell.Hyprland model so it
    // updates the instant Hyprland reports a focus change — no hyprctl poll.
    // Only `.id` is consumed, which the native HyprlandWorkspace provides.
    readonly property var activeWorkspace: Hyprland.focusedWorkspace ?? null
    property var activeWindow: null
    property var monitors: []
    property int dataSerial: 0
    // labwc sessions have no Hyprland IPC: hyprctl produces empty stdout and
    // every poll logs a JSON.parse error. Disable the poll processes entirely
    // (Quickshell.Hyprland data is already inert there). Hyprland sessions
    // keep HYPRLAND_INSTANCE_SIGNATURE set, so behavior is unchanged.
    readonly property bool hyprlandIpcAvailable: !!Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")
    // Cached overview model recomputed only when the data dirty-flag
    // (dataSerial) or the overview refresh serial changes. Consumers bind to
    // this property instead of calling overviewWorkspaceEntriesGroupedByMonitor()
    // inside a binding (which QML cannot track as a dependency).
    property var overviewWorkspaceEntries: {
        // Re-evaluate when the data dirty-flag or an explicit overview
        // refresh request changes. Reading both properties here registers
        // them as binding dependencies.
        const _serial = root.dataSerial;
        const _refresh = GlobalStates.overviewRefreshSerial;
        const _order = WorkspaceOrder.revision;
        void _serial; void _refresh; void _order;
        return root.overviewWorkspaceEntriesGroupedByMonitor() ?? [];
    }

    // Convenient stuff

    function normalizeAddress(address) {
        const raw = String(address ?? "");
        if (raw.length === 0)
            return "";
        return raw.startsWith("0x") ? raw : `0x${raw}`;
    }

    function clientByAddress(address) {
        const raw = String(address ?? "");
        if (raw.length === 0)
            return null;
        const byAddr = root.windowByAddress ?? {};
        return byAddr[raw]
            ?? byAddr[root.normalizeAddress(raw)]
            ?? byAddr[raw.startsWith("0x") ? raw.slice(2) : raw]
            ?? null;
    }

    function toplevelsForWorkspace(workspace) {
        return ToplevelManager.toplevels.values.filter(toplevel => {
            const win = root.clientByAddress(toplevel.HyprlandToplevel?.address);
            return win?.workspace?.id === workspace;
        })
    }

    function hyprlandClientsForWorkspace(workspace) {
        return root.windowList.filter(win => win.workspace.id === workspace);
    }

    function workspaceHasVisibleWindows(workspaceId) {
        if (workspaceId < 1)
            return false;
        return root.hyprlandClientsForWorkspace(workspaceId).some(
            win => win.mapped && !win.hidden
        );
    }

    function workspaceGroupBase(workspaceId, groupSize) {
        const size = groupSize > 0 ? groupSize : 10;
        return Math.floor((Math.max(workspaceId, 1) - 1) / size) * size;
    }

    function isRegularWorkspace(ws) {
        if (!ws?.name)
            return true;
        return !ws.name.startsWith("special:");
    }

    function suppressedEmptyWorkspaceIds() {
        return GlobalStates.overviewSuppressedEmptyWorkspaceIds ?? [];
    }

    function pendingWorkspaceMonitorName(workspaceId) {
        const pending = GlobalStates.overviewPendingWorkspaceMonitorById ?? {};
        return pending[workspaceId] ?? "";
    }

    function workspaceMonitorName(ws) {
        if (!ws)
            return "";
        const pendingMonitor = root.pendingWorkspaceMonitorName(ws.id);
        return pendingMonitor.length > 0 ? pendingMonitor : (ws.monitor ?? "");
    }

    function pendingWorkspaceSettled(entry) {
        const wsId = entry?.id ?? -1;
        const targetMonitor = entry?.monitorName ?? "";
        if (wsId < 1 || targetMonitor.length === 0)
            return false;
        const ws = root.workspaceById[wsId];
        if (!ws || (ws.monitor ?? "") !== targetMonitor)
            return false;
        return root.windowList.some(win => win.workspace?.id === wsId && win.mapped && !win.hidden);
    }

    function workspaceOrderMonitorName(workspaceId, fallbackMonitorId) {
        const pendingMonitor = root.pendingWorkspaceMonitorName(workspaceId);
        if (pendingMonitor.length > 0)
            return pendingMonitor;
        const workspace = root.workspaceById[workspaceId];
        if ((workspace?.monitor ?? "").length > 0)
            return workspace.monitor;
        return root.monitors.find(mon => mon.id === fallbackMonitorId)?.name ?? "";
    }

    function syncWorkspaceOrder() {
        const sortedMonitors = root.sortedOverviewMonitors();
        const monitorNames = sortedMonitors.map(mon => mon.name ?? "").filter(name => name.length > 0);
        const occupiedByMonitor = ({});
        for (const name of monitorNames)
            occupiedByMonitor[name] = [];
        const occupiedSets = ({});
        const usedIds = ({});

        for (const workspace of root.workspaces) {
            if (workspace?.id >= 1 && workspace.id <= 100)
                usedIds[workspace.id] = true;
        }

        for (const win of root.windowList) {
            const workspaceId = win?.workspace?.id ?? -1;
            if (workspaceId < 1 || workspaceId > 100)
                continue;
            usedIds[workspaceId] = true;
            if (!win.mapped || win.hidden)
                continue;
            const monitorName = root.workspaceOrderMonitorName(workspaceId, win.monitor);
            if (monitorName.length === 0)
                continue;
            if (!occupiedByMonitor[monitorName])
                occupiedByMonitor[monitorName] = [];
            if (!occupiedSets[monitorName])
                occupiedSets[monitorName] = ({});
            if (!occupiedSets[monitorName][workspaceId]) {
                occupiedSets[monitorName][workspaceId] = true;
                occupiedByMonitor[monitorName].push(workspaceId);
            }
        }

        const pendingMonitorMap = GlobalStates.overviewPendingWorkspaceMonitorById ?? {};
        for (const key of Object.keys(pendingMonitorMap)) {
            const workspaceId = Number(key);
            if (workspaceId >= 1 && workspaceId <= 100)
                usedIds[workspaceId] = true;
        }

        for (const pending of GlobalStates.overviewPendingOccupiedWorkspaces ?? []) {
            const workspaceId = pending?.id ?? -1;
            const monitorName = pending?.monitorName ?? root.pendingWorkspaceMonitorName(workspaceId);
            if (workspaceId < 1 || workspaceId > 100 || monitorName.length === 0)
                continue;
            usedIds[workspaceId] = true;
            if (!occupiedByMonitor[monitorName])
                occupiedByMonitor[monitorName] = [];
            if (!occupiedSets[monitorName])
                occupiedSets[monitorName] = ({});
            if (!occupiedSets[monitorName][workspaceId]) {
                occupiedSets[monitorName][workspaceId] = true;
                occupiedByMonitor[monitorName].push(workspaceId);
            }
        }

        WorkspaceOrder.observe(
            monitorNames,
            occupiedByMonitor,
            usedIds,
            root.clientsLoaded && root.monitorsLoaded && root.workspacesLoaded);
    }

    // Keep Omarchy's complete default workspace strip: 1..10 are always
    // available, including empty slots, then show every real positive
    // Hyprland workspace above 10. Hyprland itself has no ten-workspace
    // limit and Overview must not hide windows moved to 11+.
    function systemWorkspaceIds() {
        const ids = [];
        for (let id = 1; id <= 10; ++id)
            ids.push(id);
        for (const workspace of root.workspaces) {
            const id = Number(workspace?.id ?? -1);
            if (id > 0 && id <= 100 && !ids.includes(id))
                ids.push(id);
        }
        ids.sort((a, b) => a - b);
        return ids;
    }

    function overviewWorkspaceEntriesForMonitor(monitorName, appendTrailing, reservedWorkspaceIds, orderByMru) {
        const useMruOrder = orderByMru ?? false;
        const targetMonitor = monitorName ?? "";
        const useSystemOrder = GlobalStates.overviewSortMode !== "legacy";
        const monitorData = targetMonitor
            ? root.monitors.find(mon => (mon.name ?? "") === targetMonitor)
            : null;
        const activeId = Math.max(1, Math.min(100,
            monitorData?.activeWorkspace?.id
                ?? root.activeWorkspace?.id
                ?? 1
        ));

        // Only workspaces with visible windows participate in the grid.
        // Hyprland may keep real empty workspaces around after cross-monitor
        // moves; those are handled as the single trailing slot below.
        const regularWorkspaces = useSystemOrder
            ? root.systemWorkspaceIds().map(id => {
                const live = root.workspaceById[id];
                return live ?? {
                    id,
                    name: String(id),
                    monitor: targetMonitor || root.monitors[0]?.name || ""
                };
            })
            : root.workspaces
                .filter(ws => root.isRegularWorkspace(ws))
                .filter(ws => ws.id >= 1 && ws.id <= 100)
                .filter(ws => !targetMonitor || root.workspaceMonitorName(ws) === targetMonitor)
                .filter(ws => !root.suppressedEmptyWorkspaceIds().includes(ws.id))
                .filter(ws => root.workspaceHasVisibleWindows(ws.id))
                .sort((a, b) => a.id - b.id);

        const seen = {};
        const withWindows = [];
        regularWorkspaces.forEach(ws => {
            if (seen[ws.id])
                return;
            seen[ws.id] = true;
            const monName = root.workspaceMonitorName(ws);
            withWindows.push({
                id: ws.id,
                monitorName: monName,
                monitorIndex: 0,
                monitorLabel: monName,
                isTrailingEmpty: false
            });
        });

        // Fallback: workspaces that have windows (per windowList) but aren't in
        // root.workspaces yet — race when getClients finishes before getWorkspaces.
        // Only add if the workspace is NOT in root.workspaces (avoid duplicates).
        // Use the window's monitor to determine which monitor group it belongs to.
        root.windowList.forEach(win => {
            if (!win?.mapped || win?.hidden) return;
            const wsId = win?.workspace?.id;
            if (wsId < 1 || wsId > 100 || seen[wsId]) return;
            if (root.workspaces.some(w => w.id === wsId)) return;
            if (!root.workspaceHasVisibleWindows(wsId)) return;
            const mon = root.monitors.find(m => m.id === win.monitor);
            const pendingMonitor = root.pendingWorkspaceMonitorName(wsId);
            const monName = pendingMonitor.length > 0 ? pendingMonitor : (mon?.name ?? "");
            if (targetMonitor && monName !== targetMonitor) return;
            seen[wsId] = true;
            withWindows.push({
                id: wsId,
                monitorName: monName,
                monitorIndex: 0,
                monitorLabel: monName,
                isTrailingEmpty: false
            });
        });

        const pendingOccupied = GlobalStates.overviewPendingOccupiedWorkspaces ?? [];
        pendingOccupied.forEach(entry => {
            const wsId = entry?.id ?? -1;
            if (wsId < 1 || wsId > 100 || seen[wsId])
                return;
            const monName = entry?.monitorName ?? root.pendingWorkspaceMonitorName(wsId);
            if (targetMonitor && monName !== targetMonitor)
                return;
            seen[wsId] = true;
            withWindows.push({
                id: wsId,
                monitorName: monName,
                monitorIndex: 0,
                monitorLabel: monName,
                isPendingOccupied: true,
                isTrailingEmpty: false
            });
        });

        // Normal Overview follows the same numeric order as the Omarchy bar.
        // The transient Win+Tab switcher may still opt into MRU ordering.
        const orderedIds = useSystemOrder
            ? withWindows.map(entry => entry.id).sort((a, b) => a - b)
            : (targetMonitor.length > 0
                ? WorkspaceOrder.orderIdsForMonitor(targetMonitor, withWindows.map(entry => entry.id))
                : withWindows.map(entry => entry.id).sort((a, b) => a - b));
        const entriesById = ({});
        for (const entry of withWindows)
            entriesById[entry.id] = entry;
        const visualOrder = orderedIds.map(id => entriesById[id]).filter(entry => !!entry);
        let orderedWindows = visualOrder.slice();
        const mru = GlobalStates.overviewWorkspaceMru;
        if (useMruOrder && mru && mru.length > 0) {
            const byId = {};
            withWindows.forEach(e => { byId[e.id] = e; });
            orderedWindows = [];
            const consumed = {};
            for (const id of mru) {
                if (byId[id] && !consumed[id]) {
                    orderedWindows.push(byId[id]);
                    consumed[id] = true;
                }
            }
            visualOrder.forEach(e => {
                if (!consumed[e.id]) {
                    orderedWindows.push(e);
                    consumed[e.id] = true;
                }
            });
        }

        const ordered = orderedWindows.slice();

        // Keep one creation target at the very end, as in the original
        // Overview. It must not reuse 1..5, because those empty workspaces
        // are intentionally shown to match Omarchy's bar.
        const usedIds = useSystemOrder ? root.systemWorkspaceIds() : [];
        for (const workspace of root.workspaces) {
            const id = Number(workspace?.id ?? -1);
            if (id > 0 && id <= 100 && !usedIds.includes(id))
                usedIds.push(id);
        }
        const pendingIds = Object.keys(GlobalStates.overviewPendingWorkspaceMonitorById ?? {})
            .map(id => Number(id));
        const usedIdSet = ({});
        for (const id of usedIds)
            usedIdSet[id] = true;
        for (const id of pendingIds) {
            if (id > 0 && id <= 100) {
                usedIdSet[id] = true;
                if (!usedIds.includes(id))
                    usedIds.push(id);
            }
        }
        let trailingId = useSystemOrder
            ? root.allocateSystemTrailingWorkspaceId(usedIdSet)
            : WorkspaceOrder.allocateId(usedIdSet, {});
        while (useSystemOrder && trailingId <= 100 && usedIds.includes(trailingId))
            trailingId += 1;
        if (trailingId <= 100) {
            ordered.push({
                id: trailingId,
                monitorName: targetMonitor || monitorData?.name || root.monitors[0]?.name || "",
                monitorIndex: 0,
                monitorLabel: targetMonitor,
                isTrailingEmpty: true
            });
        }

        return ordered;
    }

    // Omarchy's stock bar has room for live ids 6..10. Reuse the first empty
    // one before creating 11+, while still allowing and displaying any
    // already-existing workspace above 10.
    function allocateSystemTrailingWorkspaceId(usedIdSet) {
        for (let id = 6; id <= 10; id++) {
            if (!usedIdSet[id])
                return id;
        }

        let highest = 10;
        for (const key of Object.keys(usedIdSet)) {
            const id = Number(key);
            if (id > highest && id <= 100)
                highest = id;
        }
        return highest + 1;
    }

    function overviewWorkspaceEntriesGlobal(orderByMru) {
        return root.overviewWorkspaceEntriesForMonitor("", true, {}, orderByMru ?? false);
    }

    function sortedOverviewMonitors() {
        return root.monitors.slice().sort((a, b) => {
            // Temporarily disabled while validating cross-monitor drag behavior:
            // keep monitor group order identical on every screen.
            // const anchorName = GlobalStates.overviewOpen
            //     ? (GlobalStates.overviewAnchorMonitorName || Hyprland.focusedMonitor?.name || "")
            //     : (Hyprland.focusedMonitor?.name ?? "");
            // const aAnchor = (a.name ?? "") === anchorName;
            // const bAnchor = (b.name ?? "") === anchorName;
            // if (aAnchor !== bAnchor)
            //     return aAnchor ? -1 : 1;
            if ((a.y ?? 0) !== (b.y ?? 0))
                return (a.y ?? 0) - (b.y ?? 0);
            return (a.x ?? 0) - (b.x ?? 0);
        });
    }

    function overviewWorkspaceEntriesGroupedByMonitor() {
        const monitors = root.sortedOverviewMonitors();
        const all = [];
        const reservedIds = {};
        for (let i = 0; i < monitors.length; ++i) {
            const mon = monitors[i];
            const entries = root.overviewWorkspaceEntriesForMonitor(mon.name, true, reservedIds);
            for (let j = 0; j < entries.length; ++j) {
                entries[j].monitorIndex = i;
                entries[j].monitorLabel = mon.description || mon.name || `Monitor ${i + 1}`;
                entries[j].monitorName = mon.name || entries[j].monitorName || "";
                entries[j].groupStart = j === 0;
                entries[j].groupEnd = j === entries.length - 1;
                all.push(entries[j]);
            }
        }
        if (all.length === 0)
            return root.overviewWorkspaceEntriesGlobal();
        return all;
    }

    function workspaceDataForId(workspaceId) {
        return root.workspaceById[workspaceId] ?? null;
    }

    function clientForToplevel(toplevel) {
        if (!toplevel || !toplevel.HyprlandToplevel) {
            return null;
        }
        return root.clientByAddress(toplevel.HyprlandToplevel.address);
    }

    function monitorActiveWorkspaceId(monitor) {
        if (!monitor)
            return 0;
        const monitorData = root.monitors.find(m => m.id === monitor.id);
        return monitorData?.activeWorkspace?.id ?? monitor.activeWorkspace?.id ?? 0;
    }

    function focusedClientForWorkspace(workspaceId) {
        if (workspaceId < 1)
            return null;

        const active = root.activeWindow;
        if (active?.address && active.workspace?.id == workspaceId && active.mapped && !active.hidden)
            return active;

        const clients = root.hyprlandClientsForWorkspace(workspaceId)
            .filter(win => win.mapped && !win.hidden);
        if (clients.length === 0)
            return null;

        return clients.reduce((best, win) => {
            if (!best)
                return win;
            return win.focusHistoryID < best.focusHistoryID ? win : best;
        }, null);
    }

    // Internals

    function updateWindowList() {
        getClients.running = true;
    }

    function updateMonitors() {
        getMonitors.running = true;
    }

    function updateWorkspaces() {
        getWorkspaces.running = true;
    }

    function updateActiveWindow() {
        getActiveWindow.running = true;
    }

    function updateAll() {
        updateWindowList();
        updateMonitors();
        updateWorkspaces();
        updateActiveWindow();
    }

    Connections {
        target: GlobalStates
        function onOverviewPendingWorkspaceMonitorByIdChanged() {
            root.syncWorkspaceOrder();
        }
        function onOverviewPendingOccupiedWorkspacesChanged() {
            root.syncWorkspaceOrder();
        }
    }

    // Debounce the heavy re-fetch. Hyprland fires many raw events in a burst
    // (e.g. when the overview layer appears: activewindow, focusedmon,
    // movewindow, …). Without coalescing, each event spawned 6 hyprctl
    // children that raced the overview's own render + ScreencopyView capture.
    // Schedule at most one refresh per frame. Do not restart an active timer:
    // sustained event traffic must not keep postponing fresh window data.
    Timer {
        id: dataRefreshTimer
        interval: 16
        repeat: false
        onTriggered: root.updateAll()
    }

    function scheduleRefresh() {
        if (!dataRefreshTimer.running)
            dataRefreshTimer.start()
    }

    function markDataChanged() {
        root.dataSerial += 1;
    }

    function biggestWindowForWorkspace(workspaceId) {
        const windowsInThisWorkspace = HyprlandData.windowList.filter(w => w.workspace.id == workspaceId);
        return windowsInThisWorkspace.reduce((maxWin, win) => {
            const maxArea = (maxWin?.size?.[0] ?? 0) * (maxWin?.size?.[1] ?? 0);
            const winArea = (win?.size?.[0] ?? 0) * (win?.size?.[1] ?? 0);
            return winArea > maxArea ? win : maxWin;
        }, null);
    }

    Component.onCompleted: {
        updateAll();
    }

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            // Layer/screencast events don't change clients/workspaces/monitors.
            if (["openlayer", "closelayer", "screencast"].includes(event.name)) return;
            // activeWindow is cheap (tiny JSON) and feeds focusedClientForWorkspace,
            // so refresh it immediately for responsiveness; coalesce the rest.
            if (["activewindow", "activewindowv2", "windowtitlev2", "focusedmon", "focusedmonv2"].includes(event.name)) {
                updateActiveWindow();
            }
            root.scheduleRefresh()
        }

        // activeWorkspace is now derived from the native focusedWorkspace model
        // (no hyprctl poll). Bump the dirty flag so the overview model
        // re-evaluates when focus moves.
        function onFocusedWorkspaceChanged() {
            root.markDataChanged()
        }
    }

    Process {
        id: getClients
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector {
            id: clientsCollector
            onStreamFinished: {
                // labwc: hyprctl has no IPC to talk to and yields empty
                // stdout; JSON.parse("") would log a SyntaxError per poll.
                if (!root.hyprlandIpcAvailable || !clientsCollector.text.trim())
                    return;
                root.windowList = JSON.parse(clientsCollector.text)
                let tempWinByAddress = {};
                for (var i = 0; i < root.windowList.length; ++i) {
                    var win = root.windowList[i];
                    tempWinByAddress[win.address] = win;
                }
                root.windowByAddress = tempWinByAddress;
                root.addresses = root.windowList.map(win => win.address);
                root.clientsLoaded = true;
                const pendingWindows = GlobalStates.overviewPendingWindowWorkspaceByAddress ?? {};
                const remainingPendingWindows = Object.assign({}, pendingWindows);
                let pendingWindowsChanged = false;
                for (const address of Object.keys(pendingWindows)) {
                    const win = root.clientByAddress(address);
                    if (win?.workspace?.id === pendingWindows[address]) {
                        delete remainingPendingWindows[address];
                        pendingWindowsChanged = true;
                    }
                }
                if (pendingWindowsChanged)
                    GlobalStates.overviewPendingWindowWorkspaceByAddress = remainingPendingWindows;
                const suppressed = root.suppressedEmptyWorkspaceIds();
                if (suppressed.length > 0) {
                    GlobalStates.overviewSuppressedEmptyWorkspaceIds = suppressed.filter(wsId =>
                        !root.windowList.some(win => win.workspace?.id === wsId && win.mapped && !win.hidden)
                    );
                }
                const pendingOccupied = GlobalStates.overviewPendingOccupiedWorkspaces ?? [];
                if (pendingOccupied.length > 0) {
                    GlobalStates.overviewPendingOccupiedWorkspaces = pendingOccupied.filter(entry =>
                        !root.pendingWorkspaceSettled(entry)
                    );
                }
                root.syncWorkspaceOrder();
                root.markDataChanged();
            }
        }
    }

    Process {
        id: getMonitors
        command: ["hyprctl", "monitors", "-j"]
        stdout: StdioCollector {
            id: monitorsCollector
            onStreamFinished: {
                if (!root.hyprlandIpcAvailable || !monitorsCollector.text.trim())
                    return;
                root.monitors = JSON.parse(monitorsCollector.text);
                root.monitorsLoaded = true;
                root.syncWorkspaceOrder();
                root.markDataChanged();
            }
        }
    }


    Process {
        id: getWorkspaces
        command: ["hyprctl", "workspaces", "-j"]
        stdout: StdioCollector {
            id: workspacesCollector
            onStreamFinished: {
                if (!root.hyprlandIpcAvailable || !workspacesCollector.text.trim())
                    return;
                var rawWorkspaces = JSON.parse(workspacesCollector.text);
                // Filter out invalid workspace ids (e.g. lock-screen temp workspace 2147483647 - N)
                root.workspaces = rawWorkspaces.filter(ws => ws.id >= 1 && ws.id <= 100);
                let tempWorkspaceById = {};
                for (var i = 0; i < root.workspaces.length; ++i) {
                    var ws = root.workspaces[i];
                    tempWorkspaceById[ws.id] = ws;
                }
                root.workspaceById = tempWorkspaceById;
                root.workspaceIds = root.workspaces.map(ws => ws.id);
                root.workspacesLoaded = true;
                const pending = GlobalStates.overviewPendingWorkspaceMonitorById ?? {};
                const nextPending = {};
                for (const wsId in pending) {
                    const ws = tempWorkspaceById[wsId];
                    if (!ws || (ws.monitor ?? "") !== pending[wsId])
                        nextPending[wsId] = pending[wsId];
                }
                GlobalStates.overviewPendingWorkspaceMonitorById = nextPending;
                const pendingOccupied = GlobalStates.overviewPendingOccupiedWorkspaces ?? [];
                if (pendingOccupied.length > 0) {
                    GlobalStates.overviewPendingOccupiedWorkspaces = pendingOccupied.filter(entry =>
                        !root.pendingWorkspaceSettled(entry)
                    );
                }
                root.syncWorkspaceOrder();
                root.markDataChanged();
            }
        }
    }

    Process {
        id: getActiveWindow
        command: ["hyprctl", "activewindow", "-j"]
        stdout: StdioCollector {
            id: activeWindowCollector
            onStreamFinished: {
                try {
                    const data = JSON.parse(activeWindowCollector.text.trim());
                    root.activeWindow = data?.address ? data : null;
                } catch (e) {
                    root.activeWindow = null;
                }
                root.markDataChanged();
            }
        }
    }
}
