pragma ComponentBehavior: Bound
import "."
import qs.Commons
import qs.Ui
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "ColorUtils.js" as ColorUtils
import "WheelUtils.js" as WheelUtils

Item {
    id: root
    required property var screen
    property real wheelAccum: 0
    readonly property string configuredWallpaperPath: FileUtils.expandHomePath(Config.options.background.wallpaperPath)
    // The overview process's keepalive window owns the preloader. readyUrl
    // changes only after the requested revision has decoded.
    readonly property url displayedWallpaperUrl: Wallpaper.readyUrl != ""
        ? Wallpaper.readyUrl
        : Wallpaper.requestedUrl
    readonly property HyprlandMonitor monitor: Hyprland.monitorFor(screen)
    // Re-evaluate the model only when the HyprlandData dirty-flag, an
    // explicit overview refresh, or the toplevel count changes. The
    // dependencies are read explicitly so QML registers them; the actual
    // data comes from cached/computed sources.
    readonly property int modelRevision: ServiceManager.workspace.dataSerial
        + GlobalStates.overviewRefreshSerial
        + (ToplevelManager.toplevels.values?.length ?? 0)
    // Clamp to avoid lock-screen temp workspace (2147483647 - N) leaking into UI
    readonly property int effectiveActiveWorkspaceId: Math.max(1, Math.min(100, monitor?.activeWorkspace?.id ?? 1))
    readonly property var overviewEntries: {
        // Register the revision as a dependency without the comma-operator hack.
        const _rev = root.modelRevision;
        void _rev;
        if (OverviewSwitchingController.grabbed)
            return WorkspaceNavigation.switchingModeModel() ?? [];
        return root.scopedOverviewEntries();
    }

    // In per-monitor mode each overlay asks for its own screen's entries instead
    // of the global list. Scoping here rather than in the renderer leaves the
    // grid, height and aspect maths untouched: monitorGroups is derived from this
    // list, so it collapses to a single group on its own.
    function scopedOverviewEntries() {
        const all = ServiceManager.workspace.overviewWorkspaceEntries ?? [];
        if (!GlobalStates.overviewPerMonitor)
            return all;
        const name = root.monitor?.name ?? "";
        if (name.length === 0)
            return all;
        const own = ServiceManager.workspace.overviewWorkspaceEntriesForMonitor(name, true, {}, false, true) ?? [];
        // If Hyprland has not reported this monitor yet, showing everything beats
        // leaving the screen blank.
        return own.length > 0 ? own : all;
    }
    readonly property var overviewEntryIds: (root.overviewEntries ?? []).map(entry => entry.id)
    readonly property var monitorGroups: {
        const groups = [];
        const byKey = {};
        for (let i = 0; i < root.overviewEntries.length; ++i) {
            const entry = root.overviewEntries[i];
            const key = entry.monitorName || "unknown";
            if (!byKey[key]) {
                byKey[key] = {
                    key,
                    label: entry.monitorLabel || entry.monitorName || "Hidden monitor",
                    start: i,
                    end: i,
                    monitorIndex: entry.monitorIndex ?? groups.length
                };
                groups.push(byKey[key]);
            }
            byKey[key].end = i;
        }
        return groups;
    }
    readonly property var localMonitorGroup: {
        const monitorName = root.monitor?.name ?? "";
        for (let i = 0; i < root.monitorGroups.length; ++i) {
            if (root.monitorGroups[i].key === monitorName)
                return root.monitorGroups[i];
        }
        return root.monitorGroups[0] ?? null;
    }
    readonly property int highlightedWorkspaceId: {
        // Keyboard navigation takes priority, then hover, then the active ws.
        if (GlobalStates.overviewFocusedWorkspaceId > 0
            && root.overviewEntryIds.includes(GlobalStates.overviewFocusedWorkspaceId))
            return GlobalStates.overviewFocusedWorkspaceId;
        if (root.hoveredWorkspaceEntry?.id > 0)
            return root.hoveredWorkspaceEntry.id;
        const group = root.localMonitorGroup;
        const entry = group ? root.overviewEntries[group.start] : null;
        return entry?.id ?? root.effectiveActiveWorkspaceId;
    }
    property var windowByAddress: ServiceManager.workspace.windowByAddress
    property var monitorData: ServiceManager.workspace.monitors.find(m => m.id === root.monitor?.id)

    // ── Adaptive scaling ──
    // Overview (工作区概览): full-screen grid, auto-select optimal columns
    // Overview switching mode (Win+Tab): current-monitor preview, use config scale value
    // Hyprland reports monitor width/height in physical pixels, while its
    // position, reserved area, and client geometry use logical coordinates.
    // Convert pixels first, then subtract the logical reserved margins.
    readonly property real screenW: root.usableLogicalWidth(monitorData, monitor)
    readonly property real screenH: root.usableLogicalHeight(monitorData, monitor)

    readonly property real gridPadding: 24
    readonly property real containerMargin: 64

    // Usable area for the grid (after margins)
    readonly property real availW: root.width - containerMargin * 2
    readonly property real availH: root.height - containerMargin * 2 - 72

    // Overview: try every column count, pick the one that gives the largest thumbnail
    readonly property int overviewGridColumns: {
        let n = Math.max(root.overviewEntries.length, 1);
        let bestCols = 1;
        let bestThumb = 0;
        for (let c = 1; c <= n; c++) {
            let rows = root.groupedRowsForColumns(c);
            let verticalOverhead = root.groupedVerticalOverheadForRows(rows);
            let tw = (availW - root.monitorSectionPaddingX * 2 - gridPadding * (c - 1)) / c;
            let th = (availH - verticalOverhead) / rows;
            let constrained = Math.min(tw, th / root.maxWorkspaceAspect);
            if (constrained > bestThumb) {
                bestThumb = constrained;
                bestCols = c;
            }
        }
        return bestCols;
    }
    readonly property int overviewGridRows: Math.max(
        1,
        Math.ceil(root.overviewEntries.length / root.overviewGridColumns))
    readonly property int monitorSectionGap: 24
    readonly property int monitorSectionPaddingX: 14
    readonly property int monitorSectionPaddingTop: 34
    readonly property int monitorSectionPaddingBottom: 14
    readonly property int groupedGridRows: root.groupedRowsForColumns(root.overviewGridColumns)
    readonly property real groupedVerticalOverhead: root.groupedVerticalOverheadForRows(root.groupedGridRows)
    readonly property real maxWorkspaceAspect: {
        if (root.monitorGroups.length === 0)
            return screenH / screenW;
        let aspect = screenH / screenW;
        for (let i = 0; i < root.monitorGroups.length; ++i)
            aspect = Math.max(aspect, root.monitorAspect(root.monitorGroups[i].key));
        return aspect;
    }

    // How big would each thumbnail be if we fill width vs height?
    // Workspaces keep the real screen aspect ratio (screenW : screenH).
    readonly property real thumbByWidth: (availW - gridPadding * (overviewGridColumns - 1)) / overviewGridColumns
    readonly property real thumbByHeight: (availH - groupedVerticalOverhead) / groupedGridRows

    // Pick the smaller so the aspect ratio is preserved — thumbnails shrink
    // when there are many workspaces, grow when there are few.
    readonly property real workspaceImplicitWidth: Math.floor(Math.min(thumbByWidth, thumbByHeight / maxWorkspaceAspect))
    readonly property real workspaceImplicitHeight: Math.floor(workspaceImplicitWidth * (screenH / screenW))

    property real scale: workspaceImplicitWidth / screenW

    // Omarchy's current decoration:rounding is 0; keep the overview flat too.
    property real largeWorkspaceRadius: 0
    property real smallWorkspaceRadius: 0

    property int workspaceZ: 0
    property int windowZ: 1
    property int windowDraggingZ: 99999
    property real workspaceSpacing: gridPadding

    implicitWidth: root.width
    implicitHeight: root.height

    function pendingWorkspaceIdForAddress(address) {
        const pending = GlobalStates.overviewPendingWindowWorkspaceByAddress ?? {};
        return Number(pending[address] ?? pending[ServiceManager.workspace.normalizeAddress(address)] ?? 0);
    }

    function effectiveWorkspaceId(win, address) {
        const pendingId = root.pendingWorkspaceIdForAddress(address || win?.address);
        if (pendingId > 0)
            return pendingId;
        return win?.workspace?.id ?? -1;
    }

    function groupedRowsForColumns(columns) {
        const cols = Math.max(1, columns);
        if (root.monitorGroups.length <= 1)
            return Math.max(1, Math.ceil(root.overviewEntries.length / cols));

        let rows = 0;
        for (let i = 0; i < root.monitorGroups.length; ++i) {
            const length = root.groupLength(root.monitorGroups[i]);
            const groupCols = Math.max(1, Math.min(length, cols));
            rows += Math.max(1, Math.ceil(length / groupCols));
        }
        return Math.max(1, rows);
    }

    function groupedVerticalOverheadForRows(rows) {
        const groupCount = Math.max(1, root.monitorGroups.length);
        return groupCount * (root.monitorSectionPaddingTop + root.monitorSectionPaddingBottom)
            + Math.max(0, groupCount - 1) * root.monitorSectionGap
            + Math.max(0, rows - groupCount) * root.workspaceSpacing;
    }

    function indexForWorkspaceId(wsId) {
        for (let i = 0; i < root.overviewEntries.length; ++i) {
            if (root.overviewEntries[i].id === wsId)
                return i;
        }
        return -1;
    }

    function globalSlotForWorkspaceId(wsId) {
        const entries = ServiceManager.workspace.overviewWorkspaceEntries ?? [];
        for (let i = 0; i < entries.length; ++i) {
            if (entries[i].id === wsId)
                return i + 1;
        }
        return 0;
    }

    function groupLength(group) {
        if (!group)
            return 0;
        return Math.max(0, group.end - group.start + 1);
    }

    function groupColumns(group) {
        if (!group)
            return Math.max(1, root.overviewGridColumns);
        return Math.max(1, Math.min(root.groupLength(group), root.overviewGridColumns));
    }

    function monitorDataForName(monitorName) {
        return ServiceManager.workspace.monitors.find(mon => (mon.name ?? "") === monitorName)
            ?? root.monitorData;
    }

    function usableLogicalWidth(mon, fallbackMonitor) {
        const transform = mon?.transform ?? fallbackMonitor?.transform ?? 0;
        const physicalWidth = (transform & 1)
            ? (mon?.height ?? fallbackMonitor?.height ?? 1)
            : (mon?.width ?? fallbackMonitor?.width ?? 1);
        const scale = Math.max(0.01, mon?.scale ?? fallbackMonitor?.scale ?? 1);
        const reservedLeft = mon?.reserved?.[0] ?? 0;
        const reservedRight = mon?.reserved?.[2] ?? 0;
        return Math.max(1, physicalWidth / scale - reservedLeft - reservedRight);
    }

    function usableLogicalHeight(mon, fallbackMonitor) {
        const transform = mon?.transform ?? fallbackMonitor?.transform ?? 0;
        const physicalHeight = (transform & 1)
            ? (mon?.width ?? fallbackMonitor?.width ?? 1)
            : (mon?.height ?? fallbackMonitor?.height ?? 1);
        const scale = Math.max(0.01, mon?.scale ?? fallbackMonitor?.scale ?? 1);
        const reservedTop = mon?.reserved?.[1] ?? 0;
        const reservedBottom = mon?.reserved?.[3] ?? 0;
        return Math.max(1, physicalHeight / scale - reservedTop - reservedBottom);
    }

    function monitorLogicalWidth(monitorName) {
        const mon = root.monitorDataForName(monitorName);
        if (!mon)
            return root.screenW;
        return root.usableLogicalWidth(mon, root.monitor);
    }

    function monitorLogicalHeight(monitorName) {
        const mon = root.monitorDataForName(monitorName);
        if (!mon)
            return root.screenH;
        return root.usableLogicalHeight(mon, root.monitor);
    }

    function monitorAspect(monitorName) {
        return root.monitorLogicalHeight(monitorName) / root.monitorLogicalWidth(monitorName);
    }

    function entryWidth(entryIndex) {
        return root.workspaceImplicitWidth;
    }

    function entryHeight(entryIndex) {
        const group = root.groupForEntry(entryIndex);
        return Math.floor(root.entryWidth(entryIndex) * root.monitorAspect(group?.key ?? ""));
    }

    function groupWorkspaceHeight(group) {
        return Math.floor(root.workspaceImplicitWidth * root.monitorAspect(group?.key ?? ""));
    }

    function groupRows(group) {
        return Math.max(1, Math.ceil(root.groupLength(group) / root.groupColumns(group)));
    }

    function groupWidth(group) {
        if (!group)
            return root.workspaceImplicitWidth;
        const cols = root.groupColumns(group);
        return root.workspaceImplicitWidth * cols
            + root.workspaceSpacing * (cols - 1)
            + root.monitorSectionPaddingX * 2;
    }

    function groupHeight(group) {
        if (!group)
            return root.workspaceImplicitHeight;
        const rows = root.groupRows(group);
        return root.groupWorkspaceHeight(group) * rows
            + root.workspaceSpacing * (rows - 1)
            + root.monitorSectionPaddingTop
            + root.monitorSectionPaddingBottom;
    }

    function groupsTotalHeight() {
        if (root.monitorGroups.length === 0)
            return root.overviewGridRows * root.workspaceImplicitHeight
                + (root.overviewGridRows - 1) * root.workspaceSpacing;

        let height = 0;
        for (let i = 0; i < root.monitorGroups.length; ++i) {
            if (i > 0)
                height += root.monitorSectionGap;
            height += root.groupHeight(root.monitorGroups[i]);
        }
        return height;
    }

    function groupForEntry(entryIndex) {
        for (let i = 0; i < root.monitorGroups.length; ++i) {
            const group = root.monitorGroups[i];
            if (entryIndex >= group.start && entryIndex <= group.end)
                return group;
        }
        return null;
    }

    function groupX(group) {
        if (!group)
            return root.containerMargin;
        return Math.max(root.containerMargin, (root.width - root.groupWidth(group)) / 2);
    }

    function groupY(group) {
        if (!group)
            return root.containerMargin;

        let y = Math.max(root.containerMargin, (root.height - root.groupsTotalHeight()) / 2);
        for (let i = 0; i < root.monitorGroups.length; ++i) {
            const current = root.monitorGroups[i];
            if (current.key === group.key)
                return y;
            y += root.groupHeight(current) + root.monitorSectionGap;
        }
        return y;
    }

    function entryLocalIndex(entryIndex) {
        const group = root.groupForEntry(entryIndex);
        return group ? entryIndex - group.start : entryIndex;
    }

    function entryLocalRow(entryIndex) {
        const group = root.groupForEntry(entryIndex);
        const localIndex = root.entryLocalIndex(entryIndex);
        return Math.floor(localIndex / root.groupColumns(group));
    }

    function entryLocalColumn(entryIndex) {
        const group = root.groupForEntry(entryIndex);
        const cols = root.groupColumns(group);
        const normalCol = root.entryLocalIndex(entryIndex) % cols;
        return Config.options.overview.orderRightLeft ? cols - normalCol - 1 : normalCol;
    }

    function entryX(entryIndex) {
        const group = root.groupForEntry(entryIndex);
        return root.groupX(group)
            + root.monitorSectionPaddingX
            + (root.workspaceImplicitWidth + root.workspaceSpacing) * root.entryLocalColumn(entryIndex);
    }

    function entryY(entryIndex) {
        const group = root.groupForEntry(entryIndex);
        return root.groupY(group)
            + root.monitorSectionPaddingTop
            + (root.groupWorkspaceHeight(group) + root.workspaceSpacing) * root.entryLocalRow(entryIndex);
    }

    function dispatchFocusWorkspace(wsId) {
        WorkspaceNavigation.dispatchFocusWorkspace(wsId);
    }

    property color activeBorderColor: TuiStyle.controlActiveBorder

    property Component windowComponent: OverviewWindow {}
    property var hoveredWindowData: null
    property var hoveredWorkspaceEntry: null

    function groupContainsWorkspaceId(group, workspaceId) {
        if (!group || !workspaceId)
            return false;
        for (let i = group.start; i <= group.end; ++i) {
            if (root.overviewEntries[i]?.id === workspaceId)
                return true;
        }
        return false;
    }

    function firstEntryForGroup(group) {
        if (!group)
            return null;
        return root.overviewEntries[group.start] ?? null;
    }

    function entryForWorkspaceId(workspaceId) {
        if (workspaceId < 1)
            return null;
        return root.overviewEntries.find(entry => entry?.id === workspaceId) ?? null;
    }

    function hoveredWorkspaceForGroup(group) {
        const workspaceId = root.hoveredWorkspaceEntry?.id ?? -1;
        if (workspaceId < 1)
            return null;
        // Resolve through the current model so title/monitor/trailing state
        // cannot remain stale after a workspace refresh.
        return root.entryForWorkspaceId(workspaceId);
    }

    function hoveredWindowForGroup(group) {
        const address = root.hoveredWindowData?.address ?? "";
        if (address.length === 0)
            return null;
        // windowByAddress is replaced on each Hyprland refresh. Looking up the
        // current object keeps changing titles live and drops closed windows.
        const win = root.windowByAddress[address] ?? null;
        if (!win || !root.entryForWorkspaceId(win.workspace?.id ?? -1))
            return null;
        return win;
    }

    function keyboardSelectedEntry() {
        return root.entryForWorkspaceId(GlobalStates.overviewFocusedWorkspaceId);
    }

    function infoEntryForGroup(group) {
        return root.hoveredWorkspaceForGroup(group)
            ?? root.keyboardSelectedEntry()
            ?? root.firstEntryForGroup(group)
            ?? root.overviewEntries[0]
            ?? null;
    }

    function infoWindowForGroup(group) {
        const hoveredWindow = root.hoveredWindowForGroup(group);
        if (hoveredWindow)
            return hoveredWindow;
        // Hovering workspace background intentionally shows workspace info,
        // not that workspace's previously focused client.
        if (root.hoveredWorkspaceForGroup(group))
            return null;

        const entry = root.infoEntryForGroup(group);
        if (!entry || entry.isTrailingEmpty)
            return null;
        return ServiceManager.workspace.focusedClientForWorkspace(entry.id);
    }

    function showingWorkspaceInfoForGroup(group) {
        return root.infoWindowForGroup(group) === null;
    }

    function reconcileFocusedWorkspace() {
        if (!GlobalStates.overviewOpen || root.overviewEntries.length === 0)
            return;
        if (root.keyboardSelectedEntry())
            return;

        const fallback = root.firstEntryForGroup(root.localMonitorGroup)
            ?? root.overviewEntries[0]
            ?? null;
        if (fallback?.id > 0)
            GlobalStates.overviewFocusedWorkspaceId = fallback.id;
    }

    function infoTitleForGroup(group) {
        const win = root.infoWindowForGroup(group);
        if (win)
            return win.title || win.initialTitle || win.class || "No active window";

        const entry = root.infoEntryForGroup(group);
        if (!entry)
            return "";
        return entry.isTrailingEmpty
            ? "New workspace"
            : `${entry.monitorName || "Hidden"} · Workspace ${entry.id ?? ""}`;
    }

    function infoSubtitleForGroup(group) {
        const win = root.infoWindowForGroup(group);
        if (win)
            return win.class || "";

        const entry = root.infoEntryForGroup(group);
        if (!entry)
            return "";
        return entry.isTrailingEmpty
            ? "Create a workspace on this monitor"
            : "Workspace";
    }

    function infoIconSourceForGroup(group) {
        const win = root.infoWindowForGroup(group);
        return win ? AppSearch.iconSource(AppSearch.guessIcon(win.class || "")) : "";
    }

    Connections {
        target: GlobalStates
        function onOverviewFocusedWorkspaceIdChanged() {
            // Any keyboard-driven selection (Tab, arrows, H/J/K/L, Win+Tab,
            // wheel shortcuts) must take over from a stale pointer target.
            root.hoveredWindowData = null;
            root.hoveredWorkspaceEntry = null;
        }
    }

    onOverviewEntriesChanged: Qt.callLater(root.reconcileFocusedWorkspace)

    // ── Wheel scroll anywhere cycles workspaces ──
    MouseArea {
        anchors.fill: parent
        z: -1
        visible: true
        acceptedButtons: Qt.NoButton
        onWheel: wheel => {
            const r = WheelUtils.getSteps(wheel.angleDelta.y, root.wheelAccum)
            root.wheelAccum = r.accumulator
            if (r.steps > 0)
                Hyprland.dispatch("hl.dsp.global('quickshell:overviewPrev')")
            else if (r.steps < 0)
                Hyprland.dispatch("hl.dsp.global('quickshell:overviewNext')")
            wheel.accepted = true
        }
    }

    // Workspace grid — grouped by physical monitor in overview mode.
    Item {
        id: monitorGroupUnderlay
        anchors.fill: parent
        visible: true
        z: root.workspaceZ - 1

        Repeater {
            model: root.monitorGroups
            delegate: Rectangle {
                required property var modelData
                readonly property bool focusedGroup: modelData.key === (root.monitor?.name ?? "")

                x: root.groupX(modelData)
                y: root.groupY(modelData)
                width: root.groupWidth(modelData)
                height: root.groupHeight(modelData)
                radius: 0
                color: TuiStyle.bg
                border.width: focusedGroup ? 2 : 1
                border.color: focusedGroup
                    ? TuiStyle.controlActiveBorder
                    : TuiStyle.inactiveBorder

                StyledText {
                    anchors {
                        left: parent.left
                        top: parent.top
                        leftMargin: 14
                        topMargin: 8
                    }
                    text: modelData.label
                    color: parent.focusedGroup
                        ? TuiStyle.accent
                        : ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.18)
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                    width: parent.width - 28
                }
            }
        }
    }

    Item { // Workspaces
        id: workspaceColumnLayout

        z: root.workspaceZ
        anchors.fill: parent
        implicitWidth: root.overviewGridColumns * root.workspaceImplicitWidth
            + (root.overviewGridColumns - 1) * root.workspaceSpacing
        implicitHeight: root.overviewGridRows * root.workspaceImplicitHeight
            + (root.overviewGridRows - 1) * root.workspaceSpacing
        width: root.width
        height: root.height

            Repeater {
                model: root.overviewEntries
                delegate: Rectangle { // Workspace
                    id: workspace
                    required property var modelData
                    required property int index
                    property int workspaceValue: modelData.id
                    property string monitorName: modelData.monitorName ?? ""
                    property bool isTrailingEmpty: modelData.isTrailingEmpty ?? false
                    property bool isPendingOccupied: modelData.isPendingOccupied ?? false
                    property int colIndex: root.entryLocalColumn(index)
                    property int rowIndex: root.entryLocalRow(index)
                    property color defaultWorkspaceColor: {
                        if (!root.configuredWallpaperPath || root.displayedWallpaperUrl == "") {
                            return OmarchyTheme.tintedBackground;
                        }
                        return Appearance.colors.colSurfaceContainerLow;
                    }
                    property color hoveredWorkspaceColor: ColorUtils.mix(defaultWorkspaceColor, Appearance.colors.colLayer1Hover, 0.1)
                    property color hoveredBorderColor: Appearance.colors.colLayer2Hover
                    property bool hoveredWhileDragging: false

                    readonly property bool isFocused: workspaceValue === root.highlightedWorkspaceId
                    // In Original mode the Hyprland ID is only an internal
                    // transport key. The original Overview displayed the
                    // workspace's visual slot (1, 2, 3, ...). System mode
                    // keeps the real IDs so its empty slots remain aligned
                    // with Omarchy's native workspace bar.
                    readonly property int globalSlot: GlobalStates.overviewSortMode === "legacy"
                        ? root.globalSlotForWorkspaceId(workspace.workspaceValue)
                        : workspace.workspaceValue

                    x: root.entryX(index)
                    y: root.entryY(index)
                    width: root.entryWidth(index)
                    height: root.entryHeight(index)
                    color: hoveredWhileDragging ? hoveredWorkspaceColor : defaultWorkspaceColor
                    topLeftRadius: root.largeWorkspaceRadius
                    topRightRadius: root.largeWorkspaceRadius
                    bottomLeftRadius: root.largeWorkspaceRadius
                    bottomRightRadius: root.largeWorkspaceRadius
                    border.width: 0
                    clip: true

                    Item {
                        id: workspaceContent
                        anchors.fill: parent

                        // Wallpaper background for all workspaces (including trailing empty)
                        Rectangle {
                            anchors.fill: parent
                            color: workspace.isTrailingEmpty
                                ? OmarchyTheme.tintedBackground
                                : Appearance.colors.colSurfaceContainer
                        }

                        Image {
                            id: workspaceWallpaper

                            anchors.fill: parent
                            source: root.displayedWallpaperUrl
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: false
                            cache: true
                            mipmap: true
                            // The empty/new workspace has no window thumbnail
                            // behind it, so keep its wallpaper fully opaque.
                            opacity: workspace.isTrailingEmpty ? 1 : 0.26
                        }

                        StyledText {
                            anchors {
                                top: parent.top
                                left: parent.left
                                margins: 8
                            }
                            text: workspace.isTrailingEmpty
                                ? "New workspace"
                                : workspace.isPendingOccupied
                                    ? "Moving…"
                                    : String(workspace.globalSlot)
                            font {
                                pixelSize: Appearance.font.pixelSize.smaller
                                weight: Font.Medium
                            }
                            color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.22)
                        }
                    }

                    MouseArea {
                        id: workspaceArea
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton
                        onEntered: {
                            if (!GlobalStates.overviewDraggingTargetWorkspace || GlobalStates.overviewDraggingTargetWorkspace === -1) {
                                root.hoveredWorkspaceEntry = workspace.modelData;
                                root.hoveredWindowData = null;
                            }
                        }
                        onExited: {
                            if (root.hoveredWorkspaceEntry?.id === workspace.workspaceValue)
                                root.hoveredWorkspaceEntry = null;
                        }
                        onPressed: {
                            if (GlobalStates.overviewDraggingTargetWorkspace === -1) {
                                if (workspace.isTrailingEmpty) {
                                    if (workspace.monitorName.length > 0)
                                        Hyprland.dispatch(`hl.dsp.focus({monitor="${workspace.monitorName}"})`);
                                    Hyprland.dispatch(`hl.dsp.focus({ workspace = ${workspace.workspaceValue} })`);
                                    if (workspace.monitorName.length > 0)
                                        Hyprland.dispatch(`hl.dsp.workspace.move({ workspace = "${workspace.workspaceValue}", monitor = "${workspace.monitorName}" })`);
                                    GlobalStates.overviewOpen = false;
                                } else {
                                    if (ServiceManager.workspace.workspaceHasVisibleWindows(workspace.workspaceValue))
                                        GlobalStates.promoteWorkspaceMru(workspace.workspaceValue);
                                    root.dispatchFocusWorkspace(workspace.workspaceValue);
                                    GlobalStates.overviewOpen = false;
                                }
                            }
                        }
                    }

                    DropArea {
                        anchors.fill: parent
                        onEntered: {
                            WorkspaceNavigation.setDragTarget(workspace.workspaceValue, workspace.isTrailingEmpty)
                            if (GlobalStates.overviewDraggingFromWorkspace == GlobalStates.overviewDraggingTargetWorkspace) return;
                            hoveredWhileDragging = true
                        }
                        onExited: {
                            hoveredWhileDragging = false
                            WorkspaceNavigation.clearDragTarget(workspace.workspaceValue)
                        }
                    }
                }
            }
        }

    Item { // Windows & focused workspace indicator
        id: windowSpace
        anchors.fill: parent
        implicitWidth: workspaceColumnLayout.implicitWidth
        implicitHeight: workspaceColumnLayout.implicitHeight
        width: root.width
        height: root.height

            Repeater { // Window repeater
                model: ScriptModel {
                    values: {
                        // Register modelRevision as a dependency.
                        const _rev = root.modelRevision;
                        const _pending = GlobalStates.overviewPendingWindowWorkspaceByAddress;
                        void _rev;
                        void _pending;
                        return ToplevelManager.toplevels.values.map((toplevel) => {
                            const address = ServiceManager.workspace.normalizeAddress(toplevel.HyprlandToplevel?.address);
                            const win = ServiceManager.workspace.clientByAddress(address);
                            if (!win?.mapped || win?.hidden)
                                return "";
                            const wsId = root.effectiveWorkspaceId(win, address);
                            if (wsId < 1)
                                return "";
                            if (!root.overviewEntryIds.includes(wsId)
                                && !root.overviewEntryIds.includes(win.workspace?.id))
                                return "";
                            return address;
                        }).filter(key => key.length > 0)
                    }
                }
                delegate: OverviewWindow {
                    id: window
                    required property string modelData
                    property int monitorId: windowData?.monitor
                    property var monitor: ServiceManager.workspace.monitors.find(m => m.id == monitorId)
                    property string address: modelData
                    property var modelToplevel: {
                        const values = ToplevelManager.toplevels.values;
                        for (let i = 0; i < values.length; ++i) {
                            if (ServiceManager.workspace.normalizeAddress(values[i].HyprlandToplevel?.address) === address)
                                return values[i];
                        }
                        return null;
                    }
                    toplevel: modelToplevel
                    captureActive: GlobalStates.overviewOpen
                    monitorData: this.monitor
                    scale: root.scale
                    scaleX: {
                        const mon = window.monitor;
                        if (!mon)
                            return root.scale;
                        const logicalWidth = root.usableLogicalWidth(mon, null);
                        return root.entryWidth(workspaceEntryIndex) / logicalWidth;
                    }
                    scaleY: {
                        const mon = window.monitor;
                        if (!mon)
                            return root.scale;
                        const logicalHeight = root.usableLogicalHeight(mon, null);
                        return root.entryHeight(workspaceEntryIndex) / logicalHeight;
                    }
                    widgetMonitor: ServiceManager.workspace.monitors.find(m => m.id == root.monitor.id)
                    property var liveWindowData: ServiceManager.workspace.clientByAddress(address)
                    property var cachedWindowData: null
                    windowData: liveWindowData ?? cachedWindowData
                    onLiveWindowDataChanged: {
                        if (liveWindowData)
                            cachedWindowData = liveWindowData;
                    }

                    readonly property int liveWorkspaceId: root.effectiveWorkspaceId(window.windowData, address)
                    property int stickyWorkspaceIndex: -1
                    readonly property int resolvedWorkspaceIndex: root.indexForWorkspaceId(liveWorkspaceId)
                    property int workspaceEntryIndex: resolvedWorkspaceIndex >= 0
                        ? resolvedWorkspaceIndex
                        : stickyWorkspaceIndex
                    Binding {
                        target: window
                        property: "stickyWorkspaceIndex"
                        value: window.resolvedWorkspaceIndex
                        when: window.resolvedWorkspaceIndex >= 0
                    }
                    visible: workspaceEntryIndex >= 0
                    xOffset: root.entryX(Math.max(0, workspaceEntryIndex))
                    yOffset: root.entryY(Math.max(0, workspaceEntryIndex))
                    workspaceWidth: root.entryWidth(Math.max(0, workspaceEntryIndex))
                    workspaceHeight: root.entryHeight(Math.max(0, workspaceEntryIndex))
                    property real xWithinWorkspaceWidget: window.localX
                    property real yWithinWorkspaceWidget: window.localY

                    // Radius
                    property real minRadius: Appearance.rounding.small
                    property bool workspaceAtTopLeft: true
                    property bool workspaceAtTopRight: true
                    property bool workspaceAtBottomLeft: true
                    property bool workspaceAtBottomRight: true 
                    property real distanceFromLeftEdge: xWithinWorkspaceWidget
                    property real distanceFromRightEdge: root.entryWidth(workspaceEntryIndex) - (xWithinWorkspaceWidget + targetWindowWidth)
                    property real distanceFromTopEdge: yWithinWorkspaceWidget
                    property real distanceFromBottomEdge: root.entryHeight(workspaceEntryIndex) - (yWithinWorkspaceWidget + targetWindowHeight)
                    property real distanceFromTopLeftCorner: Math.max(distanceFromLeftEdge, distanceFromTopEdge)
                    property real distanceFromTopRightCorner: Math.max(distanceFromRightEdge, distanceFromTopEdge)
                    property real distanceFromBottomLeftCorner: Math.max(distanceFromLeftEdge, distanceFromBottomEdge)
                    property real distanceFromBottomRightCorner: Math.max(distanceFromRightEdge, distanceFromBottomEdge)
                    topLeftRadius: Math.max((workspaceAtTopLeft ? root.largeWorkspaceRadius : root.smallWorkspaceRadius) - distanceFromTopLeftCorner, minRadius)
                    topRightRadius: Math.max((workspaceAtTopRight ? root.largeWorkspaceRadius : root.smallWorkspaceRadius) - distanceFromTopRightCorner, minRadius)
                    bottomLeftRadius: Math.max((workspaceAtBottomLeft ? root.largeWorkspaceRadius : root.smallWorkspaceRadius) - distanceFromBottomLeftCorner, minRadius)
                    bottomRightRadius: Math.max((workspaceAtBottomRight ? root.largeWorkspaceRadius : root.smallWorkspaceRadius) - distanceFromBottomRightCorner, minRadius)

                    z: Drag.active ? root.windowDraggingZ : (root.windowZ + window.windowData?.floating + window.windowData?.fullscreen * 2)
                    Drag.hotSpot.x: width / 2
                    Drag.hotSpot.y: height / 2
                    MouseArea {
                        id: dragArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: {
                            window.hovered = true
                            root.hoveredWindowData = window.windowData
                            // Highlight the workspace this window belongs to so
                            // the workspace border tracks the mouse too.
                            const wsId = window.windowData?.workspace?.id
                            if (wsId > 0) {
                                const entry = root.overviewEntries.find(e => e.id === wsId)
                                if (entry)
                                    root.hoveredWorkspaceEntry = entry
                            } else {
                                root.hoveredWorkspaceEntry = null
                            }
                        }
                        onExited: {
                            window.hovered = false
                            if (root.hoveredWindowData?.address === window.windowData?.address)
                                root.hoveredWindowData = null
                            if (root.hoveredWorkspaceEntry?.id === window.windowData?.workspace?.id)
                                root.hoveredWorkspaceEntry = null
                        }
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                        drag.target: parent
                        onPressed: (mouse) => {
                            window.snapshotPreview()
                            WorkspaceNavigation.beginWindowDrag(window.windowData?.workspace.id)
                            window.pressed = true
                            window.Drag.active = true
                            window.Drag.source = window
                            window.Drag.hotSpot.x = mouse.x
                            window.Drag.hotSpot.y = mouse.y
                        }
                        onReleased: {
                            const targetWorkspace = GlobalStates.overviewDraggingTargetWorkspace
                            const targetIsTrailing = GlobalStates.overviewDraggingTargetIsTrailing
                            window.pressed = false
                            window.holdCurrentPosition()
                            window.Drag.active = false
                            window.restorePositionBinding()
                            if (WorkspaceNavigation.commitWindowDrag(window.windowData?.address, window.windowData?.workspace.id, targetWorkspace, targetIsTrailing)) {
                                window.releaseHeldPosition()
                                return
                            }
                            window.releaseHeldPosition()
                            if (window.windowData.floating) {
                                const percentageX = (window.x - xOffset) / root.entryWidth(workspaceEntryIndex)
                                const percentageY = (window.y - yOffset) / root.entryHeight(workspaceEntryIndex)
                                Hyprland.dispatch(`hl.dsp.window.move({ x = "${percentageX * (monitor?.width ?? root.screen.width)}", y = "${percentageY * (monitor?.height ?? root.screen.height)}", window = "address:${window.windowData?.address}" })`)
                            }
                        }
                        onClicked: (event) => {
                            if (!window.windowData) return;

                            if (event.button === Qt.LeftButton) {
                                // Dispatch before dismissing. Closing the layer
                                // surface first hands focus back to whatever was
                                // active, and that restore races the focus we are
                                // about to ask for -- when it wins, the click
                                // appears to do nothing and the previous window
                                // stays. OverviewSearch already ordered it this way.
                                WorkspaceNavigation.focusWindow(window.windowData);
                                GlobalStates.overviewOpen = false;
                                event.accepted = true;
                            } else if (event.button === Qt.MiddleButton) {
                                Hyprland.dispatch(`hl.dsp.window.close({window = "address:${window.windowData.address}"})`)
                                event.accepted = true
                            }
                        }
                    }
                }
            }

            Repeater { // Workspace entry borders (on top of windows)
                model: root.overviewEntries
                delegate: Rectangle {
                    id: workspaceBorder
                    required property var modelData
                    required property int index
                    readonly property int entryIndex: root.indexForWorkspaceId(modelData.id)
                    readonly property bool isFocusedEntry: modelData.id === root.highlightedWorkspaceId
                    visible: entryIndex >= 0
                    x: root.entryX(entryIndex)
                    y: root.entryY(entryIndex)
                    z: root.windowZ
                    width: root.entryWidth(entryIndex)
                    height: root.entryHeight(entryIndex)
                    color: "transparent"
                    topLeftRadius: root.largeWorkspaceRadius
                    topRightRadius: root.largeWorkspaceRadius
                    bottomLeftRadius: root.largeWorkspaceRadius
                    bottomRightRadius: root.largeWorkspaceRadius
                    border.width: isFocusedEntry ? 3 : 2
                    border.color: isFocusedEntry ? root.activeBorderColor : TuiStyle.inactiveBorder
                }
            }
        }

    Repeater {
        model: root.localMonitorGroup ? [root.localMonitorGroup] : []

        delegate: Item {
            id: selectionInfoBar
            required property var modelData
            readonly property bool showingWorkspaceInfo: root.showingWorkspaceInfoForGroup(modelData)
            readonly property var infoEntry: root.infoEntryForGroup(modelData)
            readonly property string infoTitle: root.infoTitleForGroup(modelData)
            readonly property string infoSubtitle: root.infoSubtitleForGroup(modelData)
            readonly property string infoIconSource: root.infoIconSourceForGroup(modelData)
            readonly property real maxBarWidth: Math.min(620, Math.max(280, root.groupWidth(modelData) * 0.56))
            readonly property real targetWidth: Math.min(maxBarWidth, Math.max(96, infoRow.implicitWidth))
            readonly property real targetX: (root.width - targetWidth) / 2
            readonly property real targetY: {
                if (root.monitorGroups.length > 0) {
                    const lastGroup = root.monitorGroups[root.monitorGroups.length - 1];
                    return root.groupY(lastGroup) + root.groupHeight(lastGroup) + 20;
                }
                return root.height - height - 52;
            }

            x: Math.max(24, Math.min(root.width - width - 24, targetX))
            y: Math.max(24, Math.min(root.height - height - 24, targetY))
            z: root.windowDraggingZ + 1
            width: targetWidth
            height: 54
            visible: GlobalStates.overviewOpen && infoTitle.length > 0
            opacity: visible ? 1 : 0


            Rectangle {
                anchors.fill: parent
                color: "transparent"
            }

            RowLayout {
                id: infoRow
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 16
                spacing: 12

                Item {
                    Layout.preferredWidth: 30
                    Layout.preferredHeight: 30
                    Layout.alignment: Qt.AlignVCenter

                    StyledImage {
                        anchors.fill: parent
                        visible: !selectionInfoBar.showingWorkspaceInfo && selectionInfoBar.infoIconSource.length > 0
                        source: selectionInfoBar.infoIconSource
                        mipmap: true
                    }

                    NerdIcon {
                        anchors.centerIn: parent
                        visible: (!selectionInfoBar.showingWorkspaceInfo
                            || !selectionInfoBar.infoEntry?.isTrailingEmpty)
                            && (selectionInfoBar.showingWorkspaceInfo || selectionInfoBar.infoIconSource.length === 0)
                        symbol: selectionInfoBar.showingWorkspaceInfo ? "select_window" : "apps"
                        iconSize: 26
                        color: selectionInfoBar.showingWorkspaceInfo && selectionInfoBar.infoEntry?.isTrailingEmpty
                            ? TuiStyle.accent
                            : Appearance.colors.colOnLayer1
                    }

                    // Omarchy's Nerd Font plus glyph for workspace creation.
                    NerdIcon {
                        anchors.centerIn: parent
                        visible: selectionInfoBar.showingWorkspaceInfo
                            && selectionInfoBar.infoEntry?.isTrailingEmpty
                        symbol: "add"
                        color: TuiStyle.accent
                        iconSize: 26
                    }
                }

                ColumnLayout {
                    Layout.maximumWidth: selectionInfoBar.maxBarWidth - 42
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 1

                    StyledText {
                        Layout.preferredWidth: Math.min(implicitWidth, selectionInfoBar.maxBarWidth - 42)
                        text: selectionInfoBar.infoTitle
                        color: Appearance.colors.colOnLayer1
                        font.pixelSize: Appearance.font.pixelSize.normal
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }

                    StyledText {
                        Layout.preferredWidth: Math.min(implicitWidth, selectionInfoBar.maxBarWidth - 42)
                        visible: selectionInfoBar.infoSubtitle.length > 0
                        text: selectionInfoBar.infoSubtitle
                        color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.36)
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }
                }
            }
        }
    }
}
