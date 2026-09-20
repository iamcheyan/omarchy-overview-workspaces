pragma Singleton
pragma ComponentBehavior: Bound
import "."
import QtQuick
import Quickshell
import Quickshell.Io
import "MenuIndex.js" as MenuIndex

// Search inside Omarchy's command menu (the Super+Space one, id omarchy.menu).
//
// The model lives in MenuIndex.js, written here and self-contained. Omarchy's
// MenuModel.js is deliberately not imported: QML resolves JS imports statically
// while Omarchy's prefix comes from $OMARCHY_PATH, which is not
// /usr/share/omarchy on NixOS. A fixed path would fail to load the whole plugin
// rather than degrade this one feature.
//
// The guards are what matter: 144 of the menu's 263 actions carry a `when:`
// shell condition. Without evaluating them we would offer things like Hibernate
// on a machine that cannot hibernate. guardScript() resolves them all in a
// single batched bash run.
Singleton {
    id: root

    // Same reason as above: Omarchy's prefix comes from the environment rather
    // than being hardcoded. The fallback covers an unset variable.
    readonly property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"
    readonly property string defaultPath: `${root.omarchyPath}/default/omarchy/omarchy-menu.jsonc`
    readonly property string userPath: `${Quickshell.env("HOME")}/.config/omarchy/extensions/omarchy-menu.jsonc`

    property var defaultItems: []
    property var userItems: []
    property var items: ({})
    property var itemOrder: []
    property var whenResults: ({})

    function rebuild() {
        const merged = MenuIndex.mergeMenuSources(root.defaultItems, root.userItems);
        root.items = merged.items;
        root.itemOrder = merged.itemOrder;
        root.evaluateGuards();
    }

    // A reload landing mid-run would otherwise be dropped, leaving whenResults
    // describing the previous set of items. Remember that it happened and run
    // again once the current batch exits.
    property bool guardsPending: false

    // Owned by this singleton so a plugin hot reload cannot leave a deferred
    // retry holding a dead QML function/context alive.
    Timer {
        id: guardRetryTimer
        interval: 0
        repeat: false
        onTriggered: root.evaluateGuards()
    }

    function evaluateGuards() {
        // The running check comes first: clearing whenResults for an item set with
        // no guards while a batch is still in flight would let that batch write
        // the previous set's answers back, with nothing queued to correct it.
        if (guardProc.running) {
            root.guardsPending = true;
            return;
        }
        const script = MenuIndex.guardScript(root.items);
        if (!script) {
            root.whenResults = ({});
            return;
        }
        root.guardsPending = false;
        guardProc.collected = "";
        guardProc.command = ["bash", "-lc", script];
        guardProc.running = true;
    }

    // Executable rows only. A `menu` opens a submenu and a `link` navigates;
    // neither makes sense as a standalone result inside the overview.
    function query(text, limit) {
        const needle = String(text || "").trim();
        if (needle.length === 0)
            return [];

        const order = root.itemOrder || [];
        const out = [];
        for (let i = 0; i < order.length; ++i) {
            const entry = MenuIndex.item(root.items, order[i]);
            if (!entry || entry.kind !== "action" || !entry.action)
                continue;
            // For an `action`, visibility is just its own guard: Omarchy does not
            // consult ancestors either when resolving an executable row.
            if (entry.when && root.whenResults[entry.id] === false)
                continue;
            if (!MenuIndex.matchesQuery(entry, needle))
                continue;
            out.push({
                id: entry.id,
                label: entry.label,
                action: entry.action,
                description: entry.description || "",
                path: MenuIndex.parentPathFor(root.items, entry.id),
                score: MenuIndex.searchScore(root.items, entry, needle)
            });
        }
        out.sort((a, b) => a.score - b.score);
        return out.slice(0, limit || 6);
    }

    function runAction(action) {
        const command = String(action || "");
        if (command.length === 0)
            return false;
        Quickshell.execDetached(["bash", "-lc", command]);
        return true;
    }

    // Guards answer questions about live state -- whether a recording is running,
    // whether a toggle is off -- so answers frozen at shell start go stale. Omarchy
    // re-evaluates every time its menu opens; the equivalent moment here is the
    // overview entering search mode.
    Connections {
        target: GlobalStates
        function onOverviewSearchModeChanged() {
            if (GlobalStates.overviewSearchMode)
                root.evaluateGuards();
        }
    }

    FileView {
        path: root.defaultPath
        watchChanges: true
        printErrors: false
        onLoaded: { root.defaultItems = MenuIndex.parseMenuJsonc(text()); root.rebuild(); }
        onFileChanged: reload()
        // Without this the menu section would simply come up empty and give no
        // reason why. The likely cause is OMARCHY_PATH not reaching the shell
        // process, which matters on any install that is not under /usr/share.
        onLoadFailed: {
            console.warn("hancore.overview-workspaces: no menu definition at "
                + root.defaultPath + " (OMARCHY_PATH="
                + (Quickshell.env("OMARCHY_PATH") || "unset")
                + ") -- command menu results will be unavailable");
            root.defaultItems = [];
            root.rebuild();
        }
    }

    FileView {
        path: root.userPath
        watchChanges: true
        printErrors: false
        onLoaded: { root.userItems = MenuIndex.parseMenuJsonc(text()); root.rebuild(); }
        onLoadFailed: { root.userItems = []; root.rebuild(); }
        onFileChanged: reload()
    }

    // The reply is read back by MenuIndex.parseGuardReply, which lives there with
    // guardScript so the two halves of the protocol stay together and testable.
    Process {
        id: guardProc
        property string collected: ""

        stdout: SplitParser {
            onRead: data => { guardProc.collected += data + "\n"; }
        }

        onExited: (exitCode, exitStatus) => {
            // A batch that was killed rather than finished only reported the rows
            // it reached, so the last complete set is kept instead of a partial
            // one. Clearing it here would be worse than stale: with no answers at
            // all every guarded action passes, which is exactly what evaluating
            // guards is meant to prevent. A signal leaves the exit code at 0, so
            // the status is what tells us.
            if (exitCode !== 0 || exitStatus !== 0) {
                if (root.guardsPending)
                    guardRetryTimer.restart();
                return;
            }
            root.whenResults = MenuIndex.parseGuardReply(guardProc.collected);
            if (root.guardsPending)
                guardRetryTimer.restart();
        }
    }
}
