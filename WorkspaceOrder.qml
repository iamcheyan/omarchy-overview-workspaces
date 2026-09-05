pragma Singleton
pragma ComponentBehavior: Bound
import "."

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property int schemaVersion: 1
    readonly property int minimumWorkspaceId: 1
    readonly property int maximumWorkspaceId: 100
    readonly property string statePath: `${Directories.stateHome}/workspace-order.json`
    readonly property string currentInstanceSignature: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") ?? ""
    readonly property bool isWriter: true

    property bool ready: false
    property var monitorOrders: ({})
    property var releasedIds: []
    property var observedUsedIds: ({})
    property int revision: 0
    property bool poolExhaustionWarned: false

    property var pendingMonitorNames: []
    property var pendingOccupiedByMonitor: ({})
    property var pendingUsedIds: ({})
    property bool pendingSnapshotComplete: false

    function validId(value) {
        const id = Number(value);
        return Number.isInteger(id)
            && id >= root.minimumWorkspaceId
            && id <= root.maximumWorkspaceId;
    }

    function uniqueIds(values) {
        const result = [];
        const seen = ({});
        for (const value of values ?? []) {
            const id = Number(value);
            if (!root.validId(id) || seen[id])
                continue;
            seen[id] = true;
            result.push(id);
        }
        return result;
    }

    function idSet(values) {
        const result = ({});
        for (const id of root.uniqueIds(values))
            result[id] = true;
        return result;
    }

    function normalizeMonitorNames(values) {
        const result = [];
        const seen = ({});
        for (const value of values ?? []) {
            const name = String(value ?? "");
            if (name.length === 0 || seen[name])
                continue;
            seen[name] = true;
            result.push(name);
        }
        return result;
    }

    function normalizeOrders(rawOrders, monitorNames) {
        const result = ({});
        const globallySeen = ({});
        for (const name of root.normalizeMonitorNames(monitorNames)) {
            const order = [];
            for (const id of root.uniqueIds(rawOrders?.[name] ?? [])) {
                if (globallySeen[id])
                    continue;
                globallySeen[id] = true;
                order.push(id);
            }
            result[name] = order;
        }
        return result;
    }

    function normalizedStateString(orders, released) {
        return JSON.stringify({
            monitorOrders: orders ?? {},
            releasedIds: root.uniqueIds(released ?? [])
        });
    }

    function applyState(orders, released) {
        const normalizedOrders = root.normalizeOrders(
            orders ?? {}, Object.keys(orders ?? {}));
        const normalizedReleased = root.uniqueIds(released ?? []);
        const before = root.normalizedStateString(root.monitorOrders, root.releasedIds);
        const after = root.normalizedStateString(normalizedOrders, normalizedReleased);
        if (before === after)
            return false;
        root.monitorOrders = normalizedOrders;
        root.releasedIds = normalizedReleased;
        root.revision += 1;
        return true;
    }

    function parseState(text) {
        let parsed = null;
        try {
            parsed = JSON.parse(text || "{}");
        } catch (error) {
            console.warn("[WorkspaceOrder] Invalid state JSON, rebuilding from live workspaces:", error);
        }

        if (!parsed || parsed.schemaVersion !== root.schemaVersion
            || parsed.hyprlandInstanceSignature !== root.currentInstanceSignature) {
            root.applyState({}, []);
            root.ready = true;
            if (root.isWriter)
                persistTimer.restart();
            root.reconcilePendingSnapshot();
            return;
        }

        root.applyState(parsed.monitorOrders ?? {}, parsed.releasedIds ?? []);
        root.ready = true;
        root.revision += 1;
        root.reconcilePendingSnapshot();
    }

    function serializedState() {
        return JSON.stringify({
            schemaVersion: root.schemaVersion,
            hyprlandInstanceSignature: root.currentInstanceSignature,
            monitorOrders: root.monitorOrders,
            releasedIds: root.releasedIds
        }, null, 2) + "\n";
    }

    function schedulePersist() {
        if (root.isWriter && root.ready)
            persistTimer.restart();
    }

    function reconcileOrders(previousOrders, previousReleased, monitorNames,
        occupiedByMonitor, usedIds) {
        const names = root.normalizeMonitorNames(monitorNames);
        const occupiedGlobal = ({});
        const occupiedSets = ({});
        for (const name of names) {
            const ids = root.uniqueIds(occupiedByMonitor?.[name] ?? []);
            occupiedSets[name] = root.idSet(ids);
            for (const id of ids)
                occupiedGlobal[id] = true;
        }

        const nextOrders = ({});
        for (const name of names) {
            const target = occupiedSets[name] ?? {};
            const next = [];
            const added = ({});
            for (const id of root.uniqueIds(previousOrders?.[name] ?? [])) {
                if (!target[id] || added[id])
                    continue;
                next.push(id);
                added[id] = true;
            }
            const unknown = root.uniqueIds(occupiedByMonitor?.[name] ?? [])
                .filter(id => !added[id])
                .sort((a, b) => a - b);
            nextOrders[name] = next.concat(unknown);
        }

        const released = root.uniqueIds(previousReleased ?? [])
            .filter(id => !occupiedGlobal[id]);
        const releasedSet = root.idSet(released);
        for (const oldMonitor of Object.keys(previousOrders ?? {})) {
            for (const id of root.uniqueIds(previousOrders?.[oldMonitor] ?? [])) {
                if (occupiedGlobal[id] || releasedSet[id])
                    continue;
                released.push(id);
                releasedSet[id] = true;
            }
        }

        return {
            monitorOrders: nextOrders,
            // Empty but still-live Hyprland workspaces remain queued, but
            // allocateId filters the complete used set until they disappear.
            releasedIds: root.uniqueIds(released)
        };
    }

    function observe(monitorNames, occupiedByMonitor, usedIds, complete) {
        root.pendingMonitorNames = monitorNames ?? [];
        root.pendingOccupiedByMonitor = occupiedByMonitor ?? {};
        root.pendingUsedIds = usedIds ?? {};
        root.pendingSnapshotComplete = complete === true;
        root.observedUsedIds = usedIds ?? {};
        root.reconcilePendingSnapshot();
    }

    function reconcilePendingSnapshot() {
        if (!root.ready || !root.pendingSnapshotComplete)
            return;
        const reconciled = root.reconcileOrders(
            root.monitorOrders,
            root.releasedIds,
            root.pendingMonitorNames,
            root.pendingOccupiedByMonitor,
            Object.keys(root.pendingUsedIds ?? {}));
        if (root.applyState(reconciled.monitorOrders, reconciled.releasedIds))
            root.schedulePersist();
    }

    function orderIdsForMonitor(monitorName, liveIds) {
        const current = root.uniqueIds(liveIds ?? []);
        const currentSet = root.idSet(current);
        const ordered = [];
        const added = ({});
        for (const id of root.uniqueIds(root.monitorOrders?.[monitorName] ?? [])) {
            if (!currentSet[id] || added[id])
                continue;
            ordered.push(id);
            added[id] = true;
        }
        const unknown = current.filter(id => !added[id]).sort((a, b) => a - b);
        return ordered.concat(unknown);
    }

    function allocateId(usedIds, reservedIds) {
        const unavailable = ({});
        for (const key of Object.keys(usedIds ?? {})) {
            const id = Number(key);
            if (root.validId(id) && usedIds[key])
                unavailable[id] = true;
        }
        for (const key of Object.keys(reservedIds ?? {})) {
            const id = Number(key);
            if (root.validId(id) && reservedIds[key])
                unavailable[id] = true;
        }

        for (const id of root.uniqueIds(root.releasedIds)) {
            if (!unavailable[id]) {
                root.poolExhaustionWarned = false;
                return id;
            }
        }
        for (let id = root.minimumWorkspaceId; id <= root.maximumWorkspaceId; ++id) {
            if (!unavailable[id]) {
                root.poolExhaustionWarned = false;
                return id;
            }
        }
        if (!root.poolExhaustionWarned) {
            console.warn("[WorkspaceOrder] Workspace ID pool exhausted; omitting trailing candidate");
            root.poolExhaustionWarned = true;
        }
        return -1;
    }

    Timer {
        id: reloadTimer
        interval: 80
        repeat: false
        onTriggered: stateFile.reload()
    }

    Timer {
        id: persistTimer
        interval: 120
        repeat: false
        onTriggered: {
            if (root.isWriter)
                stateFile.setText(root.serializedState());
        }
    }

    Process {
        id: ensureStateDirectory
        command: ["mkdir", "-p", Directories.stateHome]
        onExited: stateFile.reload()
    }

    FileView {
        id: stateFile
        path: root.statePath
        watchChanges: true
        onFileChanged: reloadTimer.restart()
        onLoaded: root.parseState(stateFile.text())
        onLoadFailed: error => {
            if (error !== FileViewError.FileNotFound)
                console.warn("[WorkspaceOrder] Failed to load state:", error);
            if (!root.ready) {
                root.ready = true;
                root.revision += 1;
                root.reconcilePendingSnapshot();
                root.schedulePersist();
            }
        }
    }

    Component.onCompleted: ensureStateDirectory.running = true
}
