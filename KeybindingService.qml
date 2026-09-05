import QtQuick
import Quickshell
import Quickshell.Hyprland
import "WorkspaceBarConfig.js" as WorkspaceBarConfig

Item {
    id: root

    // Injected by Omarchy's service loader.
    property var shell: null
    property string appliedMode: ""
    property bool restoring: false

    // Hyprland removes runtime bindings while processing `configreloaded`.
    // Reinstall after the reload has settled, otherwise the service can keep
    // its old appliedMode while all plugin-owned bindings are gone.
    Timer {
        id: reapplyAfterReload
        interval: 250
        repeat: false
        onTriggered: root.applyBindings()
    }

    // These bindings only notify the shell that Super is being used with
    // another key. They are deliberately non-consuming, so the native
    // application binding (Win+Space, Win+Enter, etc.) still runs.
    function configuredMode() {
        const config = root.shell?.shellConfig;
        const bar = config?.bar;
        const layout = bar?.layout;
        for (const section of ["left", "center", "right"]) {
            for (const entry of layout?.[section] ?? []) {
                if (entry?.id === "hancore.overview-workspaces")
                    return entry.sortMode === "system" ? "system" : "legacy";
            }
        }
        return "";
    }

    // Workspace numbers and the overview navigation chords are the only normal
    // bindings this plugin owns. Do not install generic SUPER+key observers:
    // Hyprland cannot associate an unbind with its original owner, so those
    // observers can interfere with user-defined shortcuts.
    function workspaceNumberCommands(optimized) {
        const commands = [];
        for (let slot = 1; slot <= 10; ++slot) {
            const keycode = slot + 9;
            commands.push(`hl.unbind("SUPER + code:${keycode}")`);
            if (optimized) {
                commands.push(`hl.bind("SUPER + code:${keycode}", hl.dsp.global("quickshell:workspaceSlot${slot}"), { description = "Overview workspace slot ${slot}" })`);
            } else {
                commands.push(`hl.bind("SUPER + code:${keycode}", hl.dsp.focus({ workspace = "${slot}" }), { description = "Switch to workspace ${slot}" })`);
            }
        }
        return commands;
    }

    function nativeWorkspaceNumberCommands() {
        return root.workspaceNumberCommands(false);
    }

    function bindingScript(optimized) {
        const commands = [
            'hl.layer_rule({ name = "overview-instant", match = { namespace = "^quickshell:overview$" }, no_anim = true, animation = "none" })',
            'hl.unbind("SUPER_L")',
            'hl.unbind("SUPER_R")',
            'hl.unbind("SUPER + SUPER_L")',
            'hl.unbind("SUPER + SUPER_R")',
            'hl.unbind("SUPER + TAB")',
            'hl.unbind("SUPER + SHIFT + TAB")'
        ];
        commands.push('hl.bind("SUPER_L", hl.dsp.global("quickshell:workspaceNumber"), { non_consuming = true, transparent = true, description = "Overview Super state" })');
        commands.push('hl.bind("SUPER_R", hl.dsp.global("quickshell:workspaceNumber"), { non_consuming = true, transparent = true, description = "Overview Super state" })');
        commands.push('hl.bind("SUPER_L", hl.dsp.global("quickshell:workspaceNumber"), { non_consuming = true, transparent = true, release = true, description = "Overview Super state" })');
        commands.push('hl.bind("SUPER_R", hl.dsp.global("quickshell:workspaceNumber"), { non_consuming = true, transparent = true, release = true, description = "Overview Super state" })');
        commands.push('hl.bind("SUPER + TAB", hl.dsp.global("quickshell:overviewNext"), { description = "Overview workspace next" })');
        commands.push('hl.bind("SUPER + SHIFT + TAB", hl.dsp.global("quickshell:overviewPrev"), { description = "Overview workspace previous" })');
        commands.push('hl.bind("SUPER + SUPER_L", hl.dsp.global("quickshell:overviewCommit"), { release = true, description = "Overview workspace commit" })');
        commands.push('hl.bind("SUPER + SUPER_R", hl.dsp.global("quickshell:overviewCommit"), { release = true, description = "Overview workspace commit" })');
        // Native mode does not own Win+number. Never unbind or recreate those
        // keys there; they may be user-defined rather than Omarchy defaults.
        return optimized
            ? commands.concat(root.workspaceNumberCommands(true)).join("; ")
            : commands.join("; ");
    }

    function applyBindings() {
        if (!root.shell)
            return;
        const configCopy = JSON.parse(JSON.stringify(root.shell.shellConfig ?? {}));
        if (WorkspaceBarConfig.removeDuplicateNativeWidget(configCopy)
                && typeof root.shell.mutateShellConfig === "function") {
            root.shell.mutateShellConfig(function(config) {
                WorkspaceBarConfig.removeDuplicateNativeWidget(config);
            });
        }
        const mode = root.configuredMode();
        if (mode === "") {
            if (root.appliedMode !== "") {
                root.restoreBindings();
                root.appliedMode = "";
            }
            return;
        }
        if (root.appliedMode === mode)
            return;
        root.restoring = false;
        Quickshell.execDetached(["hyprctl", "eval", root.bindingScript(mode === "legacy")]);
        root.appliedMode = mode;
    }

    function restoreBindings() {
        if (root.restoring)
            return;
        root.restoring = true;
        const commands = [
            'hl.unbind("SUPER_L")',
            'hl.unbind("SUPER_R")',
            'hl.unbind("SUPER + SUPER_L")',
            'hl.unbind("SUPER + SUPER_R")',
            'hl.unbind("SUPER + TAB")',
            'hl.unbind("SUPER + SHIFT + TAB")'
        ];
        if (root.appliedMode === "legacy")
            for (const command of root.nativeWorkspaceNumberCommands())
                commands.push(command);
        commands.push('hl.bind("SUPER + TAB", hl.dsp.focus({ workspace = "e+1" }), { description = "Next workspace" })');
        commands.push('hl.bind("SUPER + SHIFT + TAB", hl.dsp.focus({ workspace = "e-1" }), { description = "Previous workspace" })');
        Quickshell.execDetached(["hyprctl", "eval", commands.join("; ")]);
    }

    Component.onCompleted: Qt.callLater(root.applyBindings)
    onShellChanged: Qt.callLater(root.applyBindings)

    Connections {
        target: root.shell
        function onShellConfigChanged() {
            Qt.callLater(root.applyBindings);
        }
    }

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (event?.name !== "configreloaded")
                return;
            root.appliedMode = "";
            root.restoring = false;
            reapplyAfterReload.restart();
        }
    }

    Component.onDestruction: root.restoreBindings()
}
