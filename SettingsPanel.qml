import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "."

Panel {
    id: root
    moduleName: "hancore.overview-workspaces"
    manageIpc: false

    property var anchorItem: null
    property var hostWidget: null
    readonly property string pluginVersion: "0.1.7"
    readonly property color panelForeground: Color.popups.text
    readonly property color panelMuted: Util.alpha(Color.popups.text, 0.58)

    function open() { root.controller.show() }
    function close() { root.controller.hide() }
    function toggle() { root.opened ? root.close() : root.open() }

    // The preview scope is only worth offering with more than one screen: on a
    // single monitor both settings draw exactly the same grid.
    readonly property bool multiMonitor: (ServiceManager.workspace.monitors?.length ?? 0) > 1

    function persistSetting(key, value) {
        var entry = { id: root.moduleName };
        for (var existing in root.settings) {
            if (existing !== "id")
                entry[existing] = root.settings[existing];
        }
        entry[key] = value;
        root.settings = entry;
        if (root.hostWidget && "settings" in root.hostWidget)
            root.hostWidget.settings = entry;
        if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
            root.bar.shell.updateEntryInline(root.moduleName, entry);
    }

    function persistMode(mode) {
        GlobalStates.overviewSortMode = mode === "legacy" ? "legacy" : "system";
        root.persistSetting("sortMode", mode);
    }

    function persistPerMonitor(enabled) {
        GlobalStates.overviewPerMonitor = enabled;
        root.persistSetting("perMonitor", enabled);
    }

    function persistVimKeys(enabled) {
        GlobalStates.overviewVimKeys = enabled;
        root.persistSetting("vimKeys", enabled);
    }

    function syncSettings() {
        const mode = root.setting("sortMode", "legacy") === "legacy" ? "legacy" : "system";
        GlobalStates.overviewSortMode = mode;
        GlobalStates.overviewPerMonitor = root.setting("perMonitor", true) !== false;
        GlobalStates.overviewVimKeys = root.setting("vimKeys", true) !== false;
    }

    Component.onCompleted: {
        root.syncSettings();
    }

    onSettingsChanged: root.syncSettings()

    // Both settings below are a labelled row with an ON/OFF pill, so the shape
    // lives here once instead of being spelled out twice.
    component ToggleRow: Rectangle {
        id: row
        required property string title
        required property string detail
        required property bool checked
        signal toggled()

        height: rowText.implicitHeight + Style.space(16)
        color: row.checked
            ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
            : Util.alpha(Color.popups.text, 0.06)
        border.width: 1
        border.color: row.checked ? Color.accent : Color.popups.border

        Column {
            id: rowText
            anchors.left: parent.left
            anchors.right: pill.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            spacing: Style.space(2)

            Text {
                text: row.title
                width: parent.width
                wrapMode: Text.WordWrap
                color: root.panelForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
            }
            Text {
                text: row.detail
                width: parent.width
                wrapMode: Text.WordWrap
                color: root.panelMuted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
            }
        }

        Rectangle {
            id: pill
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.rightMargin: Style.space(8)
            width: pillLabel.implicitWidth + Style.space(16)
            height: pillLabel.implicitHeight + Style.space(6)
            radius: height / 2
            color: row.checked ? Color.accent : Util.alpha(Color.popups.text, 0.14)

            Text {
                id: pillLabel
                anchors.centerIn: parent
                text: row.checked ? "ON" : "OFF"
                color: row.checked ? Color.popups.background : root.panelMuted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
            }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: row.toggled()
        }
    }

    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        owner: root.hostWidget || root
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: panel.fittedContentWidth(Style.space(360))
        contentHeight: panel.fittedContentHeight(content.implicitHeight)

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onCloseRequested: root.close()

            Item {
                id: content
                anchors.fill: parent
                implicitWidth: Math.max(menuColumn.implicitWidth, versionLabel.implicitWidth)
                implicitHeight: menuColumn.implicitHeight + versionLabel.implicitHeight + Style.space(12)

                Flickable {
                    id: menuScroller
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: versionLabel.top
                    anchors.bottomMargin: Style.space(8)
                    contentWidth: width
                    contentHeight: menuColumn.implicitHeight
                    clip: true
                    interactive: contentHeight > height
                    boundsBehavior: Flickable.StopAtBounds

                    Column {
                        id: menuColumn
                        width: menuScroller.width
                        spacing: Style.space(10)

                        Text {
                            text: "Overview workspace ordering"
                            width: parent.width
                            wrapMode: Text.WordWrap
                            color: root.panelForeground
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.title
                            font.bold: true
                        }

                        Text {
                            text: "Choose the plugin's optimized order or Omarchy's native order."
                            width: parent.width
                            wrapMode: Text.WordWrap
                            color: root.panelMuted
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.body
                        }

                        Repeater {
                            model: [
                                { key: "legacy", title: "Optimized order (recommended)", detail: "Plugin-managed dynamic order; Win+number follows slots 1, 2, 3... and New workspace stays last." },
                                { key: "system", title: "System native order", detail: "Matches Omarchy's native slots 1–10, including empty slots, plus real 11+ workspaces." }
                            ]

                            delegate: Rectangle {
                                required property var modelData
                                width: menuColumn.width
                                height: optionColumn.implicitHeight + Style.space(16)
                                color: GlobalStates.overviewSortMode === modelData.key
                                    ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
                                    : Util.alpha(Color.popups.text, 0.06)
                                border.width: 1
                                border.color: GlobalStates.overviewSortMode === modelData.key ? Color.accent : Color.popups.border

                                Column {
                                    id: optionColumn
                                    anchors.fill: parent
                                    anchors.margins: Style.space(8)
                                    spacing: Style.space(2)
                                    Text {
                                        text: modelData.title
                                        width: parent.width
                                        wrapMode: Text.WordWrap
                                        color: root.panelForeground
                                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                        font.pixelSize: Style.font.body
                                        font.bold: true
                                    }
                                    Text {
                                        text: modelData.detail
                                        width: parent.width
                                        wrapMode: Text.WordWrap
                                        color: root.panelMuted
                                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                        font.pixelSize: Style.font.caption
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: root.persistMode(modelData.key)
                                }
                            }
                        }

                        Rectangle {
                            width: menuColumn.width
                            height: 1
                            color: Util.alpha(Color.popups.text, 0.12)
                        }

                        Text {
                            text: "Overview search"
                            width: parent.width
                            wrapMode: Text.WordWrap
                            color: root.panelForeground
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.title
                            font.bold: true
                        }

                        ToggleRow {
                            width: menuColumn.width
                            title: "Keep h/j/k/l for navigation"
                            detail: GlobalStates.overviewVimKeys
                                ? "Press / to open search."
                                : "Any letter opens search."
                            checked: GlobalStates.overviewVimKeys
                            onToggled: root.persistVimKeys(!GlobalStates.overviewVimKeys)
                        }

                        Rectangle {
                            width: menuColumn.width
                            height: 1
                            visible: root.multiMonitor
                            color: Util.alpha(Color.popups.text, 0.12)
                        }

                        Text {
                            visible: root.multiMonitor
                            text: "Multi-monitor preview"
                            width: parent.width
                            wrapMode: Text.WordWrap
                            color: root.panelForeground
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.title
                            font.bold: true
                        }

                        ToggleRow {
                            width: menuColumn.width
                            visible: root.multiMonitor
                            title: "Show only this monitor's workspaces"
                            detail: GlobalStates.overviewPerMonitor
                                ? "Each screen draws its own workspaces."
                                : "Every screen draws all workspaces, including the other monitors'."
                            checked: GlobalStates.overviewPerMonitor
                            onToggled: root.persistPerMonitor(!GlobalStates.overviewPerMonitor)
                        }
                    }
                }

                Text {
                    id: versionLabel
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    text: `v${root.pluginVersion}`
                    color: root.panelMuted
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    horizontalAlignment: Text.AlignRight
                }
            }
        }
    }
}
