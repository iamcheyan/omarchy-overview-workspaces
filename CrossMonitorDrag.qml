pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell

// Transient input state bridging the per-monitor PanelWindow surfaces during a
// window drag, per docs/cross-monitor-drag-contract.md.
//
// Qt's Drag/DropArea pair only works within one window -- its documentation
// states the result is "not specified" once a drag spans two -- and the overview
// is one layer-shell surface per monitor. What does survive that boundary is the
// pointer grab: the surface where the press happened keeps receiving motion
// after the cursor leaves it, with coordinates outside its own bounds. Nothing
// is lost, it is merely discarded. That is enough to bridge the surfaces by
// hand, and both overlays share a Quickshell process, so a singleton carries it.
//
// Scope is deliberately narrow. This binds no shortcut, touches no
// KeybindingService state, starts no capture, and owns the proxy image only for
// the duration of a drag.
Singleton {
    id: root

    property bool active: false
    property string windowAddress: ""
    property int sourceWorkspaceId: -1
    // The surface the drag started on, used to tell a foreign card from a local
    // one -- not to route the drop.
    property string sourceMonitorName: ""

    // Pointer in global logical coordinates. Hyprland reports monitor positions
    // in the same space QML uses inside a surface, so converting is an offset
    // with no scale factor involved.
    property real pointerX: 0
    property real pointerY: 0

    // Bumped on every begin(). Asynchronous work started during a drag carries
    // the generation it belongs to and is discarded if the drag has since ended,
    // so a late callback cannot resurrect state or show a stale image.
    property int generation: 0

    // "<surface>:<workspace>" -> hit box in global coordinates. Two monitor
    // identities are kept apart on purpose:
    //
    //   surfaceMonitorName    the overlay rendering the hit box
    //   workspaceMonitorName  the monitor that owns the workspace
    //
    // With the default all-workspaces preview every overlay renders every card,
    // so the two differ routinely. Hit testing uses the surface and the
    // rectangle; the drop commit must use the workspace's owner, because a
    // workspace id alone never identifies a card -- trailing ids are allocated
    // per monitor and repeat across them.
    property var targets: ({})

    function begin(address, workspaceId, monitorName, w, h, px, py) {
        root.generation += 1;
        root.windowAddress = String(address ?? "");
        root.sourceWorkspaceId = workspaceId ?? -1;
        root.sourceMonitorName = String(monitorName ?? "");
        root.sourceWidth = w ?? 0;
        root.sourceHeight = h ?? 0;
        root.previewGrab = null;
        // Seed the pointer from the press: going active with the previous drag's
        // coordinates would resolve hoveredTarget against a stale position for a
        // frame, flashing the highlight on the wrong card.
        root.pointerX = px ?? 0;
        root.pointerY = py ?? 0;
        root.targets = ({});
        root.active = true;
    }

    function publishTarget(surfaceMonitorName, workspaceMonitorName, workspaceId, isTrailing, x, y, w, h) {
        if (!root.active || workspaceId === undefined || workspaceId === null)
            return;
        const next = Object.assign({}, root.targets);
        next[`${surfaceMonitorName}:${workspaceId}`] = {
            id: workspaceId,
            isTrailing: isTrailing === true,
            surfaceMonitorName: String(surfaceMonitorName ?? ""),
            workspaceMonitorName: String(workspaceMonitorName ?? ""),
            x: x,
            y: y,
            w: w,
            h: h
        };
        root.targets = next;
    }

    function updatePointer(gx, gy) {
        if (!root.active)
            return;
        root.pointerX = gx;
        root.pointerY = gy;
    }

    // The card under the pointer, or null. Reactive, so the destination overlay
    // can highlight and draw the proxy without polling.
    readonly property var hoveredTarget: {
        if (!root.active)
            return null;
        const gx = root.pointerX;
        const gy = root.pointerY;
        const keys = Object.keys(root.targets);
        for (let i = 0; i < keys.length; ++i) {
            const t = root.targets[keys[i]];
            if (gx >= t.x && gx <= t.x + t.w && gy >= t.y && gy <= t.y + t.h)
                return t;
        }
        return null;
    }

    // Snapshot of the dragged window, shown by the destination overlay so the
    // window itself appears to cross rather than a stand-in.
    //
    // The grab result is held, not just its url: grabToImage returns an
    // in-memory url that is valid only while the result object is alive. One
    // grab per drag -- the source monitor already captures this window live, and
    // a second continuous capture would cost GPU for nothing -- and it is
    // released on end().
    property real sourceWidth: 0
    property real sourceHeight: 0
    property var previewGrab: null
    readonly property string previewUrl: root.previewGrab
        ? String(root.previewGrab.url ?? "")
        : ""

    function setPreview(grabResult, forGeneration) {
        // grabToImage answers asynchronously; by then the drag may be over or a
        // new one started. Applying it either way would show the wrong window.
        if (!root.active || forGeneration !== root.generation)
            return;
        root.previewGrab = grabResult ?? null;
    }

    function end() {
        root.active = false;
        root.windowAddress = "";
        root.sourceWorkspaceId = -1;
        root.sourceMonitorName = "";
        // Invalidates any callback still in flight, and lets the image go:
        // nothing displays it once the drag is over.
        root.generation += 1;
        root.previewGrab = null;
        root.targets = ({});
    }
}
