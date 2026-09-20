import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import ".." as Local

BarWidget {
    id: root
    moduleName: "hancore.overview-workspaces"

    readonly property bool opened: settingsPanelLoader.item
        ? settingsPanelLoader.item.opened === true
        : false

    readonly property string targetMonitorName: Hyprland.focusedMonitor?.name ?? ""
    readonly property bool mruEnabled: Local.GlobalStates.overviewSortMode === "legacy"
    readonly property int focusedWorkspaceId: {
        // MRU changes the visual order, not the compositor's focused workspace.
        // Depend on the shared refresh serial, but always read the live Hyprland
        // focus object so a stale derived activeWorkspace cannot pin the marker.
        const _dataSerial = Local.HyprlandData.dataSerial;
        void _dataSerial;
        return Hyprland.focusedWorkspace?.id ?? -1;
    }
    readonly property var workspaceIds: {
        // The workspace object collection can keep the same identity while
        // focus moves between existing workspaces. Depend on the data serial
        // so the bar recomputes its MRU order after every focus change.
        const _dataSerial = Local.HyprlandData.dataSerial;
        void _dataSerial;
        const mode = Local.GlobalStates.overviewSortMode;
        const all = Hyprland.workspaces.values
            .map(workspace => Number(workspace.id))
            .filter(id => id > 0 && id <= 100);
        const occupied = all.filter(id => {
            const workspace = Local.HyprlandData.workspaceById[id];
            return workspace && Local.HyprlandData.workspaceHasVisibleWindows(id)
                && (!root.targetMonitorName
                    || Local.HyprlandData.workspaceMonitorName(workspace) === root.targetMonitorName);
        });
        const visual = mode !== "legacy"
            ? Local.HyprlandData.systemWorkspaceIds()
            : Local.WorkspaceOrder.orderIdsForMonitor(root.targetMonitorName, occupied);
        const occupiedSet = ({});
        for (const id of occupied)
            occupiedSet[id] = true;
        const mru = Local.GlobalStates.overviewWorkspaceMru ?? [];
        const ordered = [];
        const added = ({});
        if (root.mruEnabled) {
            for (const id of mru) {
                if (occupiedSet[id] && !added[id]) {
                    ordered.push(id);
                    added[id] = true;
                }
            }
        }
        for (const id of visual) {
            if (!added[id] && (mode !== "legacy" || occupiedSet[id])) {
                ordered.push(id);
                added[id] = true;
            }
        }
        return ordered;
    }

    function applySettings() {
        Local.GlobalStates.overviewSortMode = setting("sortMode", "legacy") === "legacy"
            ? "legacy" : "system";
        // The bar widget is the only place that always runs at shell startup;
        // SettingsPanel only syncs once the panel is instantiated.
        Local.GlobalStates.overviewPerMonitor = setting("perMonitor", true) !== false;
        Local.GlobalStates.overviewVimKeys = setting("vimKeys", true) !== false;
    }
    function open() { if (settingsPanelLoader.item) settingsPanelLoader.item.open(); }
    function close() { if (settingsPanelLoader.item) settingsPanelLoader.item.close(); }
    function toggle() { if (settingsPanelLoader.item) settingsPanelLoader.item.toggle(); }
    function openOverview() { Local.GlobalStates.overviewOpen = true; }
    function focusWorkspace(id) {
        Hyprland.dispatch(`hl.dsp.focus({ workspace = "${id}" })`);
    }
    function injectPanel() {
        if (!settingsPanelLoader.item) return;
        settingsPanelLoader.item.bar = root.bar;
        settingsPanelLoader.item.settings = root.settings;
        settingsPanelLoader.item.anchorItem = button;
        settingsPanelLoader.item.hostWidget = root;
    }

    Timer {
        id: injectPanelTimer
        interval: 0
        repeat: false
        onTriggered: root.injectPanel()
    }

    implicitWidth: (root.mruEnabled ? mruLabel.implicitWidth : workspaceRow.implicitWidth)
        + button.implicitWidth
    implicitHeight: button.implicitHeight
    onBarChanged: injectPanel()
    onSettingsChanged: { applySettings(); injectPanel(); }
    Component.onCompleted: {
        applySettings();
    }

    // Keep the small gaps between workspace buttons useful as a mouse fallback
    // too. The buttons above this area still handle their own left/right clicks.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: root.openOverview()
    }

    Loader {
        id: settingsPanelLoader
        active: true
        source: Qt.resolvedUrl("../SettingsPanel.qml")
        visible: false
        onLoaded: { root.injectPanel(); injectPanelTimer.restart(); }
    }

    WidgetButton {
        id: mruLabel
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        visible: root.mruEnabled
        z: 1
        bar: root.bar
        text: "Workspaces"
        tooltipText: "MRU workspace order"
        onPressed: function(buttonCode) {
            if (buttonCode === Qt.RightButton)
                root.openOverview();
            else if (buttonCode === Qt.LeftButton)
                root.toggle();
        }
    }

    WidgetButton {
        id: button
        anchors.left: root.mruEnabled ? mruLabel.right : workspaceRow.right
        anchors.verticalCenter: parent.verticalCenter
        width: implicitWidth
        height: parent.height
        bar: root.bar
        fontFamily: "JetBrainsMono Nerd Font"
        text: "󰒓"
        tooltipText: "Overview workspace order"
        onPressed: function(buttonCode) {
            if (buttonCode === Qt.RightButton)
                root.openOverview();
            else if (buttonCode === Qt.LeftButton)
                root.toggle();
        }
    }

    Row {
        id: workspaceRow
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        spacing: Style.space(1)
        visible: !root.mruEnabled

        Repeater {
            model: root.workspaceIds

            WidgetButton {
                required property int modelData
                readonly property bool focused: root.focusedWorkspaceId === modelData
                readonly property var workspace: Local.HyprlandData.workspaceById[modelData]
                readonly property bool occupied: !!workspace
                    && Local.HyprlandData.workspaceHasVisibleWindows(modelData)

                bar: root.bar
                fontFamily: "JetBrainsMono Nerd Font"
                // MRU controls the order of the buttons, but the label must
                // remain the real Hyprland workspace ID. Otherwise the focused
                // workspace is always drawn as the first visual slot and looks
                // like workspace 1 after every MRU promotion.
                text: modelData === 10 ? "0" : String(modelData)
                active: focused
                opacity: occupied || focused ? 1 : 0.5
                horizontalMargin: 6
                verticalPadding: 6
                fixedWidth: Style.space(20)
                fixedHeight: root.barSize
                onPressed: function(buttonCode) {
                    if (buttonCode === Qt.RightButton)
                        root.openOverview();
                    else
                        root.focusWorkspace(modelData);
                }
            }
        }
    }
}
