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

    // These bindings only notify the shell that Super is being used with
    // another key. They are deliberately non-consuming, so the native
    // application binding (Win+Space, Win+Enter, etc.) still runs.
    readonly property var interruptKeys: [
        "RETURN", "TAB", "SPACE", "BACKSPACE", "ESCAPE",
        "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
        "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
        "LEFT", "RIGHT", "UP", "DOWN", "GRAVE", "MINUS", "EQUAL",
        "COMMA", "PERIOD", "SLASH", "F1", "F2", "F3", "F4", "F5", "F6",
        "F7", "F8", "F9", "F10", "F11", "F12"
    ]

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

    // Workspace number keys are the only normal bindings this plugin owns.
    // The interrupt bindings below are non-consuming observers: they preserve
    // the native SUPER+letter/SPACE/RETURN action while cancelling the
    // Super-alone Overview release action.
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
        commands.push('hl.bind("SUPER_L", hl.dsp.global("quickshell:workspaceNumber"), { transparent = true, description = "Overview Super state" })');
        commands.push('hl.bind("SUPER_R", hl.dsp.global("quickshell:workspaceNumber"), { transparent = true, description = "Overview Super state" })');
        commands.push('hl.bind("SUPER_L", hl.dsp.global("quickshell:workspaceNumber"), { transparent = true, release = true, description = "Overview Super state" })');
        commands.push('hl.bind("SUPER_R", hl.dsp.global("quickshell:workspaceNumber"), { transparent = true, release = true, description = "Overview Super state" })');
        commands.push('hl.bind("SUPER + TAB", hl.dsp.global("quickshell:overviewNext"), { description = "Overview workspace next" })');
        commands.push('hl.bind("SUPER + SHIFT + TAB", hl.dsp.global("quickshell:overviewPrev"), { description = "Overview workspace previous" })');
        commands.push('hl.bind("SUPER + SUPER_L", hl.dsp.global("quickshell:overviewCommit"), { release = true, description = "Overview workspace commit" })');
        commands.push('hl.bind("SUPER + SUPER_R", hl.dsp.global("quickshell:overviewCommit"), { release = true, description = "Overview workspace commit" })');
        for (const key of root.interruptKeys) {
            commands.push(`hl.bind("SUPER + CTRL + ${key}", hl.dsp.global("quickshell:superInterrupt"), { non_consuming = true, transparent = true, description = "Overview Ctrl+Super interrupt" })`);
            commands.push(`hl.bind("SUPER + ${key}", hl.dsp.global("quickshell:superInterrupt"), { ignore_mods = true, non_consuming = true, transparent = true, description = "Overview Super interrupt" })`);
        }
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
        for (const key of root.interruptKeys) {
            commands.push(`hl.unbind("SUPER + CTRL + ${key}")`);
            commands.push(`hl.unbind("SUPER + ${key}")`);
        }
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
            Qt.callLater(root.applyBindings);
        }
    }

    Component.onDestruction: root.restoreBindings()
}
