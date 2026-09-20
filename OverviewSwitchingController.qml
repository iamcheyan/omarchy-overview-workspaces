pragma Singleton
pragma ComponentBehavior: Bound
import "."

import QtQuick
import Quickshell

Singleton {
    id: root

    property bool grabbed: false
    property bool focusQueued: false
    property bool cycleQueued: false
    property int cycleDelta: 0

    Timer {
        id: cycleTimer
        interval: 0
        repeat: false
        onTriggered: {
            const delta = root.cycleDelta;
            root.cycleDelta = 0;
            root.cycleQueued = false;
            if (!GlobalStates.overviewOpen || !root.grabbed || delta === 0)
                return;
            WorkspaceNavigation.navigateByIndex(delta);
        }
    }

    Timer {
        id: focusTimer
        interval: 0
        repeat: false
        onTriggered: {
            root.focusQueued = false;
            if (GlobalStates.overviewOpen)
                root.requestFocus();
        }
    }

    // Self-register into GlobalStates so the Super-release shortcut (owned by
    // the core qs root singleton) can drive switching mode without a core→module
    // import. Runs only in processes that load this overview module.
    Component.onCompleted: GlobalStates.overviewSwitchingController = root

    signal requestFocus()

    function navigationOpen() {
        return GlobalStates.overviewOpen;
    }

    function queueCycle(dir) {
        root.cycleDelta += dir;
        if (root.cycleQueued)
            return;

        root.cycleQueued = true;
        cycleTimer.restart();
    }

    function queueFocus() {
        if (root.focusQueued)
            return;

        root.focusQueued = true;
        focusTimer.restart();
    }

    function openGrabbedMode(dir) {
        GlobalStates.superReleaseMightTrigger = false;
        if (GlobalStates.overviewOpen && root.grabbed) {
            root.queueCycle(dir);
        } else {
            root.grabbed = true;
            GlobalStates.overviewOpen = true;
            root.queueCycle(dir);
            root.queueFocus();
        }
    }

    function commitGrabbedMode() {
        if (!root.grabbed)
            return;
        GlobalStates.superReleaseMightTrigger = false;
        root.grabbed = false;
        WorkspaceNavigation.commitSelectedWorkspace();
        GlobalStates.overviewOpen = false;
    }

    function reset() {
        root.grabbed = false;
        root.focusQueued = false;
        root.cycleQueued = false;
        root.cycleDelta = 0;
        cycleTimer.stop();
        focusTimer.stop();
    }
}
