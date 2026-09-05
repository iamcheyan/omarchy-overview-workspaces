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
        // This plugin's primary enable/disable switch is its bar entry. The
        // registry removes that entry when a bar-widget is disabled, even if
        // an old top-level plugins[] record remains for the service kind.
        return "";
    }

    // Build one Lua transaction. The old implementation spawned more than a
    // hundred hyprctl children and also reloaded Hyprland during component
    // creation/destruction. Plugin rescans could therefore race the compositor
    // and leave Wayland clients without input.
    function bindingScript(optimized) {
        const commands = [
            'hl.unbind("SUPER_L")',
            'hl.unbind("SUPER_R")',
            'hl.unbind("SUPER + SUPER_L")',
            'hl.unbind("SUPER + SUPER_R")',
            'hl.unbind("SUPER + TAB")',
            'hl.unbind("SUPER + SHIFT + TAB")'
        ];
        for (let slot = 1; slot <= 10; ++slot) {
            const keycode = slot + 9;
            commands.push(`hl.unbind("SUPER + code:${keycode}")`);
        }
        commands.push('hl.bind("SUPER_L", hl.dsp.global("quickshell:workspaceNumber"), { ignore_mods = true, transparent = true, description = "Overview Super state" })');
        commands.push('hl.bind("SUPER_R", hl.dsp.global("quickshell:workspaceNumber"), { ignore_mods = true, transparent = true, description = "Overview Super state" })');
        commands.push('hl.bind("SUPER_L", hl.dsp.global("quickshell:workspaceNumber"), { ignore_mods = true, transparent = true, release = true, description = "Overview Super state" })');
        commands.push('hl.bind("SUPER_R", hl.dsp.global("quickshell:workspaceNumber"), { ignore_mods = true, transparent = true, release = true, description = "Overview Super state" })');
        commands.push('hl.bind("SUPER + TAB", hl.dsp.global("quickshell:overviewNext"), { description = "Overview workspace next" })');
        commands.push('hl.bind("SUPER + SHIFT + TAB", hl.dsp.global("quickshell:overviewPrev"), { description = "Overview workspace previous" })');
        commands.push('hl.bind("SUPER + SUPER_L", hl.dsp.global("quickshell:overviewCommit"), { release = true, description = "Overview workspace commit" })');
        commands.push('hl.bind("SUPER + SUPER_R", hl.dsp.global("quickshell:overviewCommit"), { release = true, description = "Overview workspace commit" })');

        // Both modes need the interrupt guard so Win+application shortcuts do
        // not accidentally toggle Overview when Win is released.
        // keyd presents a remapped CapsLock as a real Ctrl modifier.  Keep an
        // exact Ctrl+Super interrupt ahead of the legacy ignore_mods rule;
        // otherwise the generic Super+X rule can win and open Overview for a
        // shortcut that is meant for another service (for example Voxtype).
        for (const key of root.interruptKeys)
            commands.push(`hl.bind("SUPER + CTRL + ${key}", hl.dsp.global("quickshell:superInterrupt"), { non_consuming = true, transparent = true, description = "Overview Ctrl+Super interrupt" })`);

        for (const key of root.interruptKeys)
            commands.push(`hl.bind("SUPER + ${key}", hl.dsp.global("quickshell:superInterrupt"), { ignore_mods = true, non_consuming = true, transparent = true, description = "Overview Super interrupt" })`);

        if (optimized) {
            for (let slot = 1; slot <= 10; ++slot) {
                const keycode = slot + 9;
                commands.push(`hl.unbind("SUPER + code:${keycode}")`);
                commands.push(`hl.bind("SUPER + code:${keycode}", hl.dsp.global("quickshell:workspaceSlot${slot}"), { description = "Overview workspace slot ${slot}" })`);
            }
        }
        return commands.join("; ");
    }

    function applyBindings() {
        if (!root.shell)
            return;
        // Use the shell's config writer, and only write when an old layout
        // actually contains both widgets. New installs use clonedFrom.
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
        for (let slot = 1; slot <= 10; ++slot)
            commands.push(`hl.unbind("SUPER + code:${slot + 9}")`);
        for (const key of root.interruptKeys) {
            commands.push(`hl.unbind("SUPER + CTRL + ${key}")`);
            commands.push(`hl.unbind("SUPER + ${key}")`);
        }
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

    // These bindings live only in Hyprland's runtime, so anything that makes it
    // re-read its config wipes them: a theme change, `omarchy refresh`, editing a
    // .lua file, or a monitor hotplug (hypr-monitor-arrange reloads to re-detect
    // displays). Until now nothing re-registered them, so Super fell back to
    // Omarchy's own menu until the shell was restarted by hand.
    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (event?.name !== "configreloaded")
                return;
            // The reload already dropped the bindings, but appliedMode still says
            // they are installed and applyBindings() would return early. Clearing
            // it is what makes the re-registration actually run.
            root.appliedMode = "";
            Qt.callLater(root.applyBindings);
        }
    }
}
