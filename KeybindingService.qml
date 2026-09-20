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
    property bool destroying: false
    property string bindingOwner: ""

    // Never queue a callback that captures this service. The host destroys and
    // recreates all plugin entry points during a hot reload; an owned Timer is
    // cancelled with this object, while a queued method callback can
    // survive long enough to call into an invalid QML context.
    Timer {
        id: applyBindingsTimer
        interval: 0
        repeat: false
        onTriggered: {
            if (!root.destroying)
                root.applyBindings();
        }
    }

    // Hyprland removes runtime bindings while processing `configreloaded`.
    // Reinstall after the reload has settled, otherwise the service can keep
    // its old appliedMode while all plugin-owned bindings are gone.
    Timer {
        id: reapplyAfterReload
        interval: 250
        repeat: false
        onTriggered: root.applyBindings()
    }

    // A runtime binding transaction can produce a configreloaded event on some
    // Hyprland versions. Ignore that event while our own binding transaction
    // is settling; otherwise the service can repeatedly apply the same script
    // and starve the Quickshell event loop. Events arriving after the guard
    // expires are genuine external reloads and still trigger reinstallation.
    Timer {
        id: bindingApplyGuard
        interval: 750
        repeat: false
    }

    // The only key expressions installed below belong to this plugin. Never
    // add a generic SUPER+key observer: it cannot distinguish a standalone
    // Super release from a user shortcut such as Ctrl+Super+V.
    function configuredMode() {
        return WorkspaceBarConfig.configuredOverviewMode(root.shell);
    }

    function migrateLegacyDuplicateWidget() {
        const legacyConfig = WorkspaceBarConfig.legacyShellConfig(root.shell);
        if (!legacyConfig || typeof root.shell.mutateShellConfig !== "function")
            return;
        const configCopy = JSON.parse(JSON.stringify(legacyConfig));
        if (WorkspaceBarConfig.removeDuplicateNativeWidget(configCopy)) {
            root.shell.mutateShellConfig(function(config) {
                WorkspaceBarConfig.removeDuplicateNativeWidget(config);
            });
        }
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

    function bindingScript(optimized, ownerToken) {
        const commands = [
            'hl.layer_rule({ name = "overview-instant", match = { namespace = "^quickshell:overview$" }, no_anim = true, animation = "none" })',
            // These are the plugin's own expressions. Do not add unrelated
            // user shortcuts here; unbind has no owner information.
            'hl.unbind("SUPER_L")',
            'hl.unbind("SUPER_R")',
            'hl.unbind("SUPER + SUPER_L")',
            'hl.unbind("SUPER + SUPER_R")',
            'hl.unbind("SUPER + TAB")',
            'hl.unbind("SUPER + SHIFT + TAB")'
        ];
        commands.push('if _G.hancoreOverviewSuperListener then _G.hancoreOverviewSuperListener:remove() end');
        commands.push('_G.hancoreOverviewSuperDown = _G.hancoreOverviewSuperDown or {}');
        // Keep the speculative Super-down open while Win+Tab is being
        // recognized. Tab (23) and Shift (50/62) are the two navigation chord
        // keys; interrupting before the GlobalShortcut sees them makes the
        // first Win+Tab press get consumed by the speculative-open cleanup.
        commands.push('_G.hancoreOverviewSuperListener = hl.on("input.keyboard.key", function(code, time, state) local isSuper = code == 133 or code == 134; local isOverviewNavigationKey = code == 23 or code == 50 or code == 62; if state == 1 then if isSuper then _G.hancoreOverviewSuperDown[code] = true; local other = false; for k,v in pairs(_G.hancoreOverviewSuperDown) do if k ~= code and v then other = true end end; hl.dispatch(hl.dsp.event("hancore-overview-super," .. (other and "interrupt" or "down"))) else local any = false; for k,v in pairs(_G.hancoreOverviewSuperDown) do if v then any = true end end; if any and not isOverviewNavigationKey then hl.dispatch(hl.dsp.event("hancore-overview-super,interrupt")) end end else if isSuper and _G.hancoreOverviewSuperDown[code] then _G.hancoreOverviewSuperDown[code] = nil; local any = false; for k,v in pairs(_G.hancoreOverviewSuperDown) do if v then any = true end end; hl.dispatch(hl.dsp.event("hancore-overview-super," .. (any and "up" or "tap"))) end end end)');
        commands.push('hl.bind("SUPER_L", hl.dsp.global("quickshell:workspaceNumber"), { non_consuming = true, transparent = true, description = "Overview Super state" })');
        commands.push('hl.bind("SUPER_R", hl.dsp.global("quickshell:workspaceNumber"), { non_consuming = true, transparent = true, description = "Overview Super state" })');
        commands.push('hl.bind("SUPER_L", hl.dsp.global("quickshell:workspaceNumber"), { non_consuming = true, transparent = true, release = true, description = "Overview Super state" })');
        commands.push('hl.bind("SUPER_R", hl.dsp.global("quickshell:workspaceNumber"), { non_consuming = true, transparent = true, release = true, description = "Overview Super state" })');
        commands.push('hl.bind("SUPER + TAB", hl.dsp.global("quickshell:overviewNext"), { description = "Overview workspace next" })');
        commands.push('hl.bind("SUPER + SHIFT + TAB", hl.dsp.global("quickshell:overviewPrev"), { description = "Overview workspace previous" })');
        commands.push('hl.bind("SUPER + SUPER_L", hl.dsp.global("quickshell:overviewCommit"), { release = true, description = "Overview workspace commit" })');
        commands.push('hl.bind("SUPER + SUPER_R", hl.dsp.global("quickshell:overviewCommit"), { release = true, description = "Overview workspace commit" })');
        commands.push(`_G.hancoreOverviewBindingOwner = "${ownerToken}"`);
        // Native mode does not own Win+number. Never unbind or recreate those
        // keys there; they may be user-defined rather than Omarchy defaults.
        return optimized
            ? commands.concat(root.workspaceNumberCommands(true)).join("; ")
            : commands.join("; ");
    }

    function transitionScript(previousMode, nextMode, ownerToken) {
        const commands = [root.bindingScript(nextMode === "legacy", ownerToken)];
        // Only a live legacy -> system transition proves that these number
        // bindings belong to this service. Restore the native mappings during
        // that handoff; a fresh system-mode start must leave user mappings alone.
        if (WorkspaceBarConfig.requiresNativeWorkspaceNumberRestore(previousMode, nextMode))
            for (const command of root.nativeWorkspaceNumberCommands())
                commands.push(command);
        return commands.join("; ");
    }

    function applyBindings() {
        if (root.destroying || !root.shell)
            return;
        root.migrateLegacyDuplicateWidget();
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
        root.bindingOwner = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
        bindingApplyGuard.restart();
        Quickshell.execDetached(["hyprctl", "eval", root.transitionScript(root.appliedMode, mode, root.bindingOwner)]);
        root.appliedMode = mode;
    }

    function scheduleApplyBindings() {
        if (!root.destroying)
            applyBindingsTimer.restart();
    }

    function restoreBindings() {
        if (root.restoring)
            return;
        root.restoring = true;
        const ownerToken = root.bindingOwner;
        const commands = [
            `if _G.hancoreOverviewBindingOwner == "${ownerToken}" then _G.hancoreOverviewBindingOwner = nil; if _G.hancoreOverviewSuperListener then _G.hancoreOverviewSuperListener:remove(); _G.hancoreOverviewSuperListener = nil end`,
            '_G.hancoreOverviewSuperDown = nil',
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
        commands.push('end');
        Quickshell.execDetached(["hyprctl", "eval", commands.join("; ")]);
    }

    Component.onCompleted: root.scheduleApplyBindings()
    onShellChanged: root.scheduleApplyBindings()

    Connections {
        target: root.shell
        ignoreUnknownSignals: true
        function onBarConfigChanged() {
            root.scheduleApplyBindings();
        }
        function onShellConfigChanged() {
            root.scheduleApplyBindings();
        }
    }

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (event?.name !== "configreloaded")
                return;
            if (bindingApplyGuard.running)
                return;
            root.appliedMode = "";
            root.restoring = false;
            reapplyAfterReload.restart();
        }
    }

    Component.onDestruction: {
        root.destroying = true;
        applyBindingsTimer.stop();
        reapplyAfterReload.stop();
        bindingApplyGuard.stop();
        root.restoreBindings();
    }
}
