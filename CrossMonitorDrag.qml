pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell

// Dragging a window from one monitor to another.
//
// Qt's Drag/DropArea pair only works within a single window -- the docs state
// the result is "not specified" once a drag spans two -- and the overview is one
// layer-shell surface per monitor. That is why a window dragged toward another
// screen just clips at the edge: it reached the boundary of its own surface.
//
// What does survive that boundary is the pointer grab. The surface where the
// press happened keeps receiving motion events after the cursor leaves it, with
// coordinates outside its own bounds. Nothing is lost, it was only discarded.
// That is enough to do the rest by hand:
//
//   * every overlay publishes its workspace cards here, in global coordinates
//   * the dragging overlay converts the pointer to global coordinates too
//   * on release the target is resolved by hit-testing this registry, instead of
//     relying on a DropArea in another window, which Qt does not guarantee
//
// Both overlays run inside the same Quickshell process, so a singleton is all
// the shared state required.
//
// On coordinates: Hyprland reports monitor positions in logical units (a 3840px
// screen at scale 1.6 occupies 2400 units, and the next monitor starts at
// x=2400), which is the same space QML uses inside the surface. Converting is
// therefore a plain offset -- no scale factor enters into it.
Singleton {
    id: root

    property bool active: false
    property string windowAddress: ""
    property int sourceWorkspaceId: -1
    property string sourceMonitorName: ""
    // Size of the card being dragged, so the proxy on the destination monitor
    // matches what left the source instead of guessing a size.
    property real sourceWidth: 0
    property real sourceHeight: 0

    // Snapshot of the dragged window's contents, so the destination monitor shows
    // the window itself rather than a stand-in.
    //
    // The grab result is held, not just its url. grabToImage returns an in-memory
    // url that stays valid only while the result object is alive, so dropping the
    // object would leave the proxy pointing at nothing. Holding it is also what
    // makes this independent of freezeUrl, which only accepts file: urls and is
    // therefore empty for an in-memory grab.
    //
    // One grab per drag, and released on end(): the source monitor is already
    // capturing this window live, and a second continuous capture would be paid
    // for on the GPU for no benefit.
    property var previewGrab: null
    readonly property string previewUrl: root.previewGrab
        ? String(root.previewGrab.url ?? "")
        : ""

    // Pointer in global coordinates, updated while the drag runs.
    property real pointerX: 0
    property real pointerY: 0

    // "<monitor>:<workspace>" -> { id, isTrailing, monitorName, x, y, w, h },
    // the rect in global coordinates. Rewritten on every drag, so a card that
    // moved or vanished cannot leave a stale target behind for long.
    property var targets: ({})

    function begin(address, workspaceId, monitorName, w, h, px, py) {
        root.windowAddress = String(address ?? "");
        root.sourceWorkspaceId = workspaceId ?? -1;
        root.sourceMonitorName = String(monitorName ?? "");
        root.sourceWidth = w ?? 0;
        root.sourceHeight = h ?? 0;
        root.previewGrab = null;
        // Seed the pointer from the press. Going active with the previous drag's
        // coordinates still in place would resolve hoveredTarget against a stale
        // position for one frame -- long enough to flash the highlight on the
        // wrong card, or the proxy at the destination's top-left corner.
        root.pointerX = px ?? 0;
        root.pointerY = py ?? 0;
        root.targets = ({});
        root.active = true;
    }

    function publishTarget(monitorName, workspaceId, isTrailing, x, y, w, h) {
        if (!root.active || workspaceId === undefined || workspaceId === null)
            return;
        const next = Object.assign({}, root.targets);
        next[`${monitorName}:${workspaceId}`] = {
            id: workspaceId,
            isTrailing: isTrailing === true,
            monitorName: String(monitorName ?? ""),
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

    // The card under the pointer, or null. Reactive so the destination overlay
    // can highlight it and draw the proxy without polling.
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

    function setPreview(grabResult) {
        root.previewGrab = grabResult ?? null;
    }

    function end() {
        root.active = false;
        // Let the grabbed image go; nothing displays it once the drag is over.
        root.previewGrab = null;
        root.windowAddress = "";
        root.sourceWorkspaceId = -1;
        root.sourceMonitorName = "";
    }
}
