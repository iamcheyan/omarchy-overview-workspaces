pragma ComponentBehavior: Bound
import "."

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland

Item {
    id: root

    property string query: ""
    property bool searchMode: false
    property int selectedIndex: 0
    property int maxAppResults: 5
    property int maxWindowResults: 7
    property int maxMenuResults: 6

    readonly property string normalizedQuery: query.trim()
    readonly property bool commandMode: normalizedQuery.startsWith(">")
    readonly property string commandText: commandMode ? normalizedQuery.slice(1).trim() : ""
    readonly property bool hasQuery: normalizedQuery.length > 0
    readonly property var appResults: hasQuery && !commandMode
        ? AppSearch.fuzzyQuery(normalizedQuery).slice(0, maxAppResults)
        : []
    readonly property var windowResults: hasQuery && !commandMode
        ? root.filterWindows(normalizedQuery).slice(0, maxWindowResults)
        : []
    readonly property var menuResults: hasQuery && !commandMode
        ? MenuSearch.query(normalizedQuery, maxMenuResults)
        : []
    readonly property int commandResultCount: commandMode && commandText.length > 0 ? 1 : 0
    readonly property int totalResults: commandResultCount + appResults.length
        + windowResults.length + menuResults.length
    readonly property int popupWidth: Math.min(760, Math.max(520, width - 80))

    signal searchRequested()
    signal closeRequested()

    function windowHaystack(win) {
        const workspace = win?.workspace || {};
        return [
            win?.title || "",
            win?.initialTitle || "",
            win?.class || "",
            win?.initialClass || "",
            workspace.name || "",
            workspace.id || "",
            win?.monitor || ""
        ].join(" ").toLowerCase();
    }

    function filterWindows(text) {
        const needle = String(text || "").toLowerCase().trim();
        if (needle.length === 0)
            return [];
        return (ServiceManager.workspace.windowList || []).filter(win =>
            win && win.mapped && !win.hidden && win.address
                && root.windowHaystack(win).indexOf(needle) >= 0);
    }

    function clampSelection() {
        selectedIndex = Math.max(0, Math.min(selectedIndex, Math.max(0, totalResults - 1)));
    }

    function moveSelection(delta) {
        if (totalResults <= 0)
            return;
        selectedIndex = (selectedIndex + delta + totalResults) % totalResults;
        resultsFlickable.ensureVisible(selectedIndex);
    }

    function launchApp(app) {
        if (!app)
            return;
        Hyprland.dispatch('hl.dsp.focus({ workspace = "empty" })');
        Qt.callLater(() => {
            AppSearch.launchApp(app);
            GlobalStates.overviewOpen = false;
        });
    }

    function focusWindow(win) {
        if (!win)
            return;
        WorkspaceNavigation.focusWindow(win);
        GlobalStates.overviewOpen = false;
    }

    function executeCommand() {
        if (commandText.length === 0)
            return;
        // xdg-terminal-exec is the freedesktop terminal dispatcher present on
        // Omarchy; execDetached keeps the terminal alive after the overview
        // closes without a vendor-specific wrapper binary.
        Quickshell.execDetached([
            "xdg-terminal-exec",
            "--app-id=hancore.overview-workspaces.command",
            "--title=Overview Command",
            "--hold",
            "-e",
            "bash",
            "-lc",
            commandText
        ]);
        GlobalStates.overviewOpen = false;
    }

    function runMenuAction(row) {
        if (!row)
            return;
        MenuSearch.runAction(row.action);
        GlobalStates.overviewOpen = false;
    }

    function activateSelection() {
        if (commandResultCount > 0) {
            executeCommand();
            return;
        }
        if (selectedIndex < appResults.length) {
            launchApp(appResults[selectedIndex]);
            return;
        }
        const windowIndex = selectedIndex - appResults.length;
        if (windowIndex >= 0 && windowIndex < windowResults.length) {
            focusWindow(windowResults[windowIndex]);
            return;
        }
        const menuIndex = windowIndex - windowResults.length;
        if (menuIndex >= 0 && menuIndex < menuResults.length)
            runMenuAction(menuResults[menuIndex]);
    }

    function windowTitle(win) {
        return win?.title || win?.initialTitle || "Untitled window";
    }

    function windowProgram(win) {
        return win?.class || win?.initialClass || "Window";
    }

    function workspaceLabel(win) {
        const workspace = win?.workspace || {};
        const wsId = workspace.id > 0 ? workspace.id : -1;
        const entries = ServiceManager.workspace.overviewWorkspaceEntries ?? [];
        let slot = 0;
        for (let i = 0; i < entries.length; ++i) {
            if (entries[i].id === wsId) {
                slot = i + 1;
                break;
            }
        }
        const monitor = win?.monitor ? `  ${win.monitor}` : "";
        return slot > 0 ? `Slot ${slot}${monitor}` : `Workspace${monitor}`;
    }

    onTotalResultsChanged: clampSelection()
    onQueryChanged: selectedIndex = 0


    // Query bar: shows what is being typed, above the workspace cards. It appears
    // as soon as search mode starts, even before any text, so it is clear the
    // keyboard no longer navigates workspaces.
    // Where the query bar will appear. With vim keys on, search is otherwise
    // invisible: nothing on screen says the key exists.
    Rectangle {
        id: searchHint
        anchors {
            top: parent.top
            topMargin: 24
            horizontalCenter: parent.horizontalCenter
        }
        width: hintRow.implicitWidth + 24
        height: 30
        visible: root.searchMode === false
            && GlobalStates.overviewVimKeys
        radius: 6
        color: TuiStyle.surfaceSubtle
        border.width: 1
        border.color: TuiStyle.inactiveBorder
        opacity: 0.75

        RowLayout {
            id: hintRow
            anchors.centerIn: parent
            spacing: 7

            NerdIcon {
                symbol: "search"
                iconSize: 13
                color: TuiStyle.dim
            }

            StyledText {
                text: "Press  /  to search"
                color: TuiStyle.dim
                font.pixelSize: 12
            }
        }
    }

    Rectangle {
        id: queryBar
        property bool cursorOn: true

        anchors {
            top: parent.top
            topMargin: 24
            horizontalCenter: parent.horizontalCenter
        }
        width: root.popupWidth
        height: 46
        visible: root.searchMode
        radius: 8
        color: TuiStyle.bg
        border.width: 1
        border.color: root.commandMode ? TuiStyle.accent : TuiStyle.menuBorder

        Timer {
            running: queryBar.visible
            interval: 530
            repeat: true
            onTriggered: queryBar.cursorOn = !queryBar.cursorOn
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 14
            anchors.rightMargin: 14
            spacing: 10

            NerdIcon {
                symbol: root.commandMode ? "terminal" : "search"
                iconSize: 18
                color: root.commandMode ? TuiStyle.accent : TuiStyle.dim
            }

            StyledText {
                Layout.fillWidth: true
                text: root.hasQuery
                    ? root.query
                    : "Search apps, windows and the menu    >  shell command"
                color: root.hasQuery ? TuiStyle.fg : TuiStyle.dim
                font.pixelSize: 15
                elide: Text.ElideLeft
            }

            Rectangle {
                Layout.preferredWidth: 2
                Layout.preferredHeight: 19
                color: TuiStyle.accent
                opacity: queryBar.cursorOn ? 1 : 0
                visible: root.hasQuery
            }

            StyledText {
                visible: root.totalResults > 0
                text: `${root.selectedIndex + 1}/${root.totalResults}`
                color: TuiStyle.dim
                font.pixelSize: 11
            }
        }
    }

    Rectangle {
        id: resultsPopup
        anchors {
            top: queryBar.bottom
            topMargin: 8
            horizontalCenter: parent.horizontalCenter
        }
        width: root.popupWidth
        height: Math.min(resultsColumn.implicitHeight + 20, Math.max(180, root.height - y - 32))
        visible: root.searchMode && root.hasQuery
        radius: 8
        color: TuiStyle.bg
        border.width: 1
        border.color: TuiStyle.menuBorder
        clip: true

        Flickable {
            id: resultsFlickable
            anchors.fill: parent
            anchors.margins: 10
            contentWidth: width
            contentHeight: resultsColumn.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            function ensureVisible(index) {
                const rowHeight = 54;
                const targetY = Math.max(0, index * rowHeight - 28);
                if (targetY < contentY)
                    contentY = targetY;
                else if (targetY + rowHeight > contentY + height)
                    contentY = Math.min(contentHeight - height, targetY + rowHeight - height);
            }

            ColumnLayout {
                id: resultsColumn
                width: resultsFlickable.width
                spacing: 6

                SearchResultRow {
                    Layout.fillWidth: true
                    visible: root.commandResultCount > 0
                    resultIndex: 0
                    title: root.commandText
                    subtitle: "Open an independent terminal and run this command"
                    meta: "Terminal command"
                    symbol: "terminal"
                    selected: root.selectedIndex === resultIndex
                    onActivated: root.executeCommand()
                }

                SearchSectionHeader {
                    Layout.fillWidth: true
                    visible: root.appResults.length > 0
                    label: "Applications"
                    count: root.appResults.length
                }

                Repeater {
                    model: root.appResults

                    SearchResultRow {
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        resultIndex: index
                        title: modelData?.name || ""
                        subtitle: modelData?.comment || modelData?.genericName || modelData?.id || ""
                        meta: "New workspace"
                        iconSource: AppSearch.iconSource(modelData?.icon || "")
                        selected: root.selectedIndex === resultIndex
                        onActivated: root.launchApp(modelData)
                    }
                }

                SearchSectionHeader {
                    Layout.fillWidth: true
                    visible: root.windowResults.length > 0
                    label: "Open Windows"
                    count: root.windowResults.length
                }

                Repeater {
                    model: root.windowResults

                    SearchResultRow {
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        resultIndex: root.appResults.length + index
                        title: root.windowTitle(modelData)
                        subtitle: root.windowProgram(modelData)
                        meta: root.workspaceLabel(modelData)
                        iconSource: AppSearch.iconSource(AppSearch.guessIcon(root.windowProgram(modelData)))
                        selected: root.selectedIndex === resultIndex
                        onActivated: root.focusWindow(modelData)
                    }
                }

                SearchSectionHeader {
                    Layout.fillWidth: true
                    visible: root.menuResults.length > 0
                    label: "Command Menu"
                    count: root.menuResults.length
                }

                Repeater {
                    model: root.menuResults

                    SearchResultRow {
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        resultIndex: root.appResults.length + root.windowResults.length + index
                        title: modelData?.label || ""
                        subtitle: modelData?.description || modelData?.action || ""
                        meta: modelData?.path || "Omarchy menu"
                        symbol: "menu"
                        selected: root.selectedIndex === resultIndex
                        onActivated: root.runMenuAction(modelData)
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 48
                    visible: root.totalResults === 0
                    text: root.commandMode
                        ? "Type a command after >"
                        : "No matching applications, windows or menu actions"
                    color: TuiStyle.dim
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    font.pixelSize: 13
                }
            }
        }
    }

    component SearchSectionHeader: Item {
        required property string label
        property int count: 0
        implicitHeight: 26

        StyledText {
            anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
                leftMargin: 8
                rightMargin: 8
            }
            height: 20
            text: `${parent.label}  ${parent.count}`
            color: TuiStyle.dim
            font.pixelSize: 11
            font.weight: Font.DemiBold
        }
    }


    component SearchResultRow: Rectangle {
        id: row
        required property int resultIndex
        required property string title
        property string subtitle: ""
        property string meta: ""
        property string iconSource: ""
        property string symbol: "apps"
        property bool selected: false
        signal activated()

        implicitHeight: 54
        radius: 6
        color: selected ? TuiStyle.selection : "transparent"

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 12
            spacing: 11

            Rectangle {
                Layout.preferredWidth: 34
                Layout.preferredHeight: 34
                radius: 6
                color: row.selected ? TuiStyle.accentWash(TuiStyle.accent) : TuiStyle.surfaceSubtle

                Image {
                    anchors.centerIn: parent
                    width: 24
                    height: 24
                    source: row.iconSource
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    visible: status === Image.Ready
                }

                NerdIcon {
                    anchors.centerIn: parent
                    symbol: row.symbol
                    iconSize: 21
                    color: row.selected ? TuiStyle.accent : TuiStyle.dim
                    visible: row.iconSource.length === 0
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1

                StyledText {
                    Layout.fillWidth: true
                    text: row.title
                    color: TuiStyle.fg
                    font.pixelSize: 14
                    elide: Text.ElideRight
                }

                StyledText {
                    Layout.fillWidth: true
                    visible: text.length > 0
                    text: row.subtitle
                    color: TuiStyle.dim
                    font.pixelSize: 12
                    elide: Text.ElideRight
                }
            }

            StyledText {
                Layout.maximumWidth: 210
                text: row.meta
                color: row.selected ? TuiStyle.fg : TuiStyle.dim
                font.pixelSize: 11
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideRight
            }
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: root.selectedIndex = row.resultIndex
            onClicked: row.activated()
        }
    }
}
