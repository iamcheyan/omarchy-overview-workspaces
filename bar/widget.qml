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
    readonly property bool legacySort: Local.GlobalStates.overviewSortMode === "legacy"
    readonly property var workspaceIds: {
        const mode = Local.GlobalStates.overviewSortMode;
        const all = Hyprland.workspaces.values
            .map(workspace => Number(workspace.id))
            .filter(id => id > 0 && id <= 100);
        if (mode !== "legacy")
            return Local.HyprlandData.systemWorkspaceIds();

        const occupied = all.filter(id => {
            const workspace = Local.HyprlandData.workspaceById[id];
            return workspace && Local.HyprlandData.workspaceHasVisibleWindows(id)
                && (!root.targetMonitorName
                    || Local.HyprlandData.workspaceMonitorName(workspace) === root.targetMonitorName);
        });
        return Local.WorkspaceOrder.orderIdsForMonitor(root.targetMonitorName, occupied);
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

    implicitWidth: workspaceRow.implicitWidth + button.implicitWidth
    implicitHeight: button.implicitHeight
    onBarChanged: injectPanel()
    onSettingsChanged: { applySettings(); injectPanel(); }
    Component.onCompleted: {
        applySettings();
    }

    Loader {
        id: settingsPanelLoader
        active: true
        source: Qt.resolvedUrl("../SettingsPanel.qml")
        visible: false
        onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel); }
    }

    WidgetButton {
        id: button
        anchors.left: workspaceRow.right
        anchors.verticalCenter: parent.verticalCenter
        width: implicitWidth
        height: parent.height
        bar: root.bar
        fontFamily: "JetBrainsMono Nerd Font"
        text: "󰒓"
        tooltipText: "Overview workspace order"
        onPressed: function(buttonCode) {
            if (buttonCode === Qt.LeftButton) root.toggle();
        }
    }

    Row {
        id: workspaceRow
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        spacing: Style.space(1)

        Repeater {
            model: root.workspaceIds

            WidgetButton {
                required property int modelData
                required property int index
                readonly property bool focused: Hyprland.focusedWorkspace?.id === modelData
                readonly property var workspace: Local.HyprlandData.workspaceById[modelData]
                readonly property bool occupied: !!workspace
                    && Local.HyprlandData.workspaceHasVisibleWindows(modelData)

                bar: root.bar
                fontFamily: "JetBrainsMono Nerd Font"
                // Original mode uses visual slots, while System mode mirrors
                // the native bar's actual workspace numbers.
                text: focused
                    ? "\uDB85\uDCFB"
                    : root.legacySort
                        ? String(index + 1)
                        : (modelData === 10 ? "0" : String(modelData))
                opacity: occupied || focused ? 1 : 0.5
                horizontalMargin: 6
                verticalPadding: 6
                fixedWidth: Style.space(20)
                fixedHeight: root.barSize
                onPressed: root.focusWorkspace(modelData)
            }
        }
    }
}
