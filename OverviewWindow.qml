pragma ComponentBehavior: Bound
import "."
import qs.Commons
import qs.Ui
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import "ColorUtils.js" as ColorUtils

Item { // Window
    id: root
    property var toplevel
    property var windowData
    property bool captureActive: true
    property var monitorData
    property var scale
    property real scaleX: scale * widthRatio
    property real scaleY: scale * heightRatio
    property real widthRatio: {
        if (!widgetMonitor || !monitorData) return 1;
        const widgetWidth = widgetMonitor.transform & 1 ? widgetMonitor.height : widgetMonitor.width;
        const monitorWidth = monitorData.transform & 1 ? monitorData.height : monitorData.width;
        return (widgetWidth * monitorData.scale) / (monitorWidth * widgetMonitor.scale);
    }
    property real heightRatio: {
        if (!widgetMonitor || !monitorData) return 1;
        const widgetHeight = widgetMonitor.transform & 1 ? widgetMonitor.width : widgetMonitor.height;
        const monitorHeight = monitorData.transform & 1 ? monitorData.width : monitorData.height;
        return (widgetHeight * monitorData.scale) / (monitorHeight * widgetMonitor.scale);
    }
    property real initX: {
        return xOffset + localX;
    }

    property real initY: {
        return yOffset + localY;
    }
    property real xOffset: 0
    property real yOffset: 0
    property real workspaceWidth: 1
    property real workspaceHeight: 1
    property var widgetMonitor
    property int widgetMonitorId: widgetMonitor?.id ?? -1

    // Monitor logical dimensions (accounting for transforms)
    property real monitorLogicalWidth: {
        if (!monitorData) return 1920;
        const w = monitorData.transform & 1 ? monitorData.height : monitorData.width;
        const scale = Math.max(0.01, monitorData.scale ?? 1);
        return Math.max(1, w / scale
            - (monitorData.reserved?.[0] ?? 0)
            - (monitorData.reserved?.[2] ?? 0));
    }
    property real monitorLogicalHeight: {
        if (!monitorData) return 1080;
        const h = monitorData.transform & 1 ? monitorData.width : monitorData.height;
        const scale = Math.max(0.01, monitorData.scale ?? 1);
        return Math.max(1, h / scale
            - (monitorData.reserved?.[1] ?? 0)
            - (monitorData.reserved?.[3] ?? 0));
    }

    // Raw coordinate relative to the monitor the window claims to be on.
    // These may be stale after a cross-monitor move — Hyprland does not
    // re-tile windows on inactive workspaces.
    property real rawRelX: (windowData?.at[0] ?? 0) - (monitorData?.x ?? 0) - (monitorData?.reserved[0] ?? 0)
    property real rawRelY: (windowData?.at[1] ?? 0) - (monitorData?.y ?? 0) - (monitorData?.reserved[1] ?? 0)
    property real rawW: windowData?.size[0] ?? 800
    property real rawH: windowData?.size[1] ?? 600

    // After scaling and clamping, would this window be too small to see?
    // This happens when stale coordinates place the window near/past the
    // monitor edge, so clamping squishes it to just a few pixels.
    property bool isRenderDegenerate: {
        const clampedX = Math.max(0, Math.min(rawRelX * root.scaleX, Math.max(0, workspaceWidth - 1)));
        const visibleW = Math.min(rawW * root.scaleX, Math.max(1, workspaceWidth - clampedX));
        const clampedY = Math.max(0, Math.min(rawRelY * root.scaleY, Math.max(0, workspaceHeight - 1)));
        const visibleH = Math.min(rawH * root.scaleY, Math.max(1, workspaceHeight - clampedY));
        // If either dimension is less than 10 % of the workspace box, the
        // window is effectively invisible — treat it as degenerate.
        return visibleW < workspaceWidth * 0.10 || visibleH < workspaceHeight * 0.10;
    }

    // When degenerate, center the window inside its workspace box at a
    // reasonable size; otherwise use the real Hyprland coordinates.
    property real effectiveW: isRenderDegenerate ? Math.min(rawW, monitorLogicalWidth) : rawW
    property real effectiveH: isRenderDegenerate ? Math.min(rawH, monitorLogicalHeight) : rawH
    property real effectiveRelX: isRenderDegenerate ? (monitorLogicalWidth - effectiveW) / 2 : rawRelX
    property real effectiveRelY: isRenderDegenerate ? (monitorLogicalHeight - effectiveH) / 2 : rawRelY

    property real rawLocalX: effectiveRelX * root.scaleX
    property real rawLocalY: effectiveRelY * root.scaleY
    property real rawWindowWidth: Math.max(1, effectiveW * root.scaleX)
    property real rawWindowHeight: Math.max(1, effectiveH * root.scaleY)
    property real localX: Math.max(0, Math.min(rawLocalX, Math.max(0, workspaceWidth - 1)))
    property real localY: Math.max(0, Math.min(rawLocalY, Math.max(0, workspaceHeight - 1)))
    property var targetWindowWidth: Math.max(1, Math.min(rawWindowWidth, Math.max(1, workspaceWidth - localX)))
    property var targetWindowHeight: Math.max(1, Math.min(rawWindowHeight, Math.max(1, workspaceHeight - localY)))
    property bool hovered: false
    property bool pressed: false
    property bool centerIcons: Config.options.overview.centerIcons
    property real iconGapRatio: 0.06
    property real iconToWindowRatio: centerIcons ? 0.35 : 0.15
    property real xwaylandIndicatorToIconRatio: 0.35
    property real iconToWindowRatioCompact: 0.6
    // Hyprland can temporarily omit `class` while a client is being moved.
    // initialClass is stable for the lifetime of the window and was the value
    // available in the old overview during those refreshes.
    property string iconClass: windowData?.class || windowData?.initialClass || "application-x-executable"
    property string iconPath: AppSearch.iconSource(AppSearch.guessIcon(root.iconClass))
    property bool compactMode: Appearance.font.pixelSize.smaller * 4 > targetWindowHeight || Appearance.font.pixelSize.smaller * 4 > targetWindowWidth

    property bool holdPosition: false
    property real holdX: 0
    property real holdY: 0

    x: holdPosition ? holdX : (xOffset + localX)
    y: holdPosition ? holdY : (yOffset + localY)
    width: targetWindowWidth
    height: targetWindowHeight
    // ScreencopyView delivers the first frame asynchronously. Fade a window
    // in when that frame arrives instead of making every workspace card flash
    // independently during Overview startup.
    opacity: root.anyPreviewContent || root.showingFreeze || root.captureAttempt >= 8 ? 1 : 0

    Behavior on opacity {
        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
    }

    function holdCurrentPosition() {
        holdX = x;
        holdY = y;
        holdPosition = true;
    }

    function restorePositionBinding() {
        x = Qt.binding(() => root.holdPosition ? root.holdX : root.xOffset + root.localX);
        y = Qt.binding(() => root.holdPosition ? root.holdY : root.yOffset + root.localY);
    }

    function releaseHeldPosition() {
        holdPosition = false;
    }

    property real topLeftRadius: 0
    property real topRightRadius: 0
    property real bottomLeftRadius: 0
    property real bottomRightRadius: 0
    clip: true

    property bool everHadContent: false
    property int captureAttempt: 0
    property int lastWorkspaceId: -1
    property int frontSlot: 0
    property bool slot0Armed: false
    property bool slot1Armed: false
    property url freezeUrl: ""
    property var captureToplevel: null
    readonly property bool anyPreviewContent: preview0.hasContent || preview1.hasContent
    readonly property bool showingFreeze: !root.anyPreviewContent && root.freezeUrl != ""

    function rememberToplevel() {
        if (root.toplevel)
            root.captureToplevel = root.toplevel;
    }

    function armFront() {
        root.rememberToplevel();
        if (!root.captureActive || !root.captureToplevel)
            return;
        if (root.frontSlot === 0)
            root.slot0Armed = true;
        else
            root.slot1Armed = true;
    }

    function recaptureNow() {
        if (!root.captureActive)
            return;
        root.rememberToplevel();
        if (root.frontSlot === 0)
            root.slot1Armed = true;
        else
            root.slot0Armed = true;
    }

    function promoteSlot(slot) {
        root.frontSlot = slot;
        root.captureAttempt = 0;
        root.everHadContent = true;
        if (slot === 0)
            root.slot1Armed = false;
        else
            root.slot0Armed = false;
        root.snapshotPreview();
    }

    function snapshotPreview() {
        // Keep the original grab-to-image behavior. Quickshell may return a
        // non-file image URL, which Image can use while ScreencopyView is
        // being replaced during a drag.
        if (!root.anyPreviewContent)
            return;
        previewHost.grabToImage(result => {
            if (result?.url)
                root.freezeUrl = result.url;
        });
    }

    onToplevelChanged: root.rememberToplevel()

    onWindowDataChanged: {
        const ws = windowData?.workspace?.id ?? -1;
        if (root.holdPosition && ws > 0 && ws !== root.lastWorkspaceId)
            root.releaseHeldPosition();
        if (root.lastWorkspaceId > 0 && ws > 0 && ws !== root.lastWorkspaceId) {
            root.snapshotPreview();
            if (!root.anyPreviewContent)
                root.recaptureNow();
        }
        root.lastWorkspaceId = ws;
    }

    onCaptureActiveChanged: {
        if (root.captureActive) {
            root.armFront();
        } else {
            root.slot0Armed = false;
            root.slot1Armed = false;
            root.captureAttempt = 0;
            root.freezeUrl = "";
            root.everHadContent = false;
        }
    }

    // Keep a recent file-backed frame available while the live capture is
    // replaced. A move can stop both ScreencopyView slots for a short period.
    Timer {
        id: freezeTimer
        interval: 400
        repeat: true
        running: root.captureActive && root.anyPreviewContent
        onTriggered: root.snapshotPreview()
    }

    Timer {
        id: captureWatchdog
        interval: 50
        repeat: true
        running: root.captureActive && !root.anyPreviewContent && root.captureAttempt < 8
        onTriggered: {
            if (root.anyPreviewContent || !root.captureActive)
                return;
            root.captureAttempt += 1;
            root.recaptureNow();
        }
    }

    Component.onCompleted: {
        root.rememberToplevel();
        root.lastWorkspaceId = windowData?.workspace?.id ?? -1;
        if (root.captureActive)
            root.armFront();
    }

    Item {
        id: previewHost
        anchors.fill: parent

        ScreencopyView {
            id: preview0
            anchors.fill: parent
            captureSource: root.slot0Armed && root.captureActive && root.captureToplevel
                ? root.captureToplevel : null
            live: root.slot0Armed && root.captureActive
            visible: hasContent && (root.frontSlot === 0 || !preview1.hasContent)

            onHasContentChanged: {
                if (hasContent)
                    root.promoteSlot(0);
            }
            onStopped: {
                if (root.frontSlot === 0)
                    root.recaptureNow();
            }
        }

        ScreencopyView {
            id: preview1
            anchors.fill: parent
            captureSource: root.slot1Armed && root.captureActive && root.captureToplevel
                ? root.captureToplevel : null
            live: root.slot1Armed && root.captureActive
            visible: hasContent && (root.frontSlot === 1 || !preview0.hasContent)

            onHasContentChanged: {
                if (hasContent)
                    root.promoteSlot(1);
            }
            onStopped: {
                if (root.frontSlot === 1)
                    root.recaptureNow();
            }
        }
    }

    Image {
        id: freezeImage
        anchors.fill: parent
        visible: root.showingFreeze
        source: root.freezeUrl
        fillMode: Image.Stretch
        asynchronous: false
        cache: false
        smooth: true
    }

    Rectangle {
            anchors.fill: parent
            topLeftRadius: root.topLeftRadius
            topRightRadius: root.topRightRadius
            bottomRightRadius: root.bottomRightRadius
            bottomLeftRadius: root.bottomLeftRadius
            color: pressed ? ColorUtils.transparentize(Appearance.colors.colLayer2Active, 0.5) : 
                hovered ? ColorUtils.transparentize(Appearance.colors.colLayer2Hover, 0.7) : 
                ColorUtils.transparentize(Appearance.colors.colLayer2)
    }

    Image {
        id: windowIcon
        z: 3
        visible: root.iconPath !== "" && status !== Image.Error
        asynchronous: false
        property real baseSize: Math.min(root.targetWindowWidth, root.targetWindowHeight)
        anchors {
            top: root.centerIcons ? undefined : parent.top
            left: root.centerIcons ? undefined : parent.left
            centerIn: root.centerIcons ? parent : undefined
            margins: baseSize * root.iconGapRatio
        }
        property var iconSize: {
            return baseSize * (root.compactMode ? root.iconToWindowRatioCompact : root.iconToWindowRatio);
        }
        mipmap: true
        Layout.alignment: Qt.AlignHCenter
        source: root.iconPath
        width: iconSize
        height: iconSize
    }

    Rectangle {
        z: 3
        visible: (root.iconPath === "" || windowIcon.status === Image.Error)
        anchors {
            top: root.centerIcons ? undefined : parent.top
            left: root.centerIcons ? undefined : parent.left
            centerIn: root.centerIcons ? parent : undefined
            margins: Math.min(root.targetWindowWidth, root.targetWindowHeight) * root.iconGapRatio
        }
        width: windowIcon.width
        height: windowIcon.height
        radius: 0
        color: ColorUtils.transparentize(TuiStyle.accent, 0.25)

        NerdIcon {
            anchors.centerIn: parent
            symbol: "apps"
            iconSize: Math.max(16, parent.height * 0.45)
            color: TuiStyle.fg
        }
    }

    // Window previews do not draw their own outline. The workspace card border
    // is the single visual boundary for both the workspace and its previews.
    Rectangle {
        anchors.fill: parent
        color: "transparent"
        topLeftRadius: root.topLeftRadius
        topRightRadius: root.topRightRadius
        bottomRightRadius: root.bottomRightRadius
        bottomLeftRadius: root.bottomLeftRadius
        border.width: 0
    }
}
