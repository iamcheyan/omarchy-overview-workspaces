// Upgrade layouts created before the manifest declared its native replacement.
// Return false for clean/disabled layouts so config notifications never loop.
function removeDuplicateNativeWidget(config) {
    const layout = config?.bar?.layout;
    const sections = ["left", "center", "right"];
    const id = entry => typeof entry === "string" ? entry : entry?.id;
    if (!sections.some(section => (layout?.[section] ?? []).some(
            entry => id(entry) === "hancore.overview-workspaces")))
        return false;

    let changed = false;
    for (const section of sections) {
        const entries = layout[section];
        if (!Array.isArray(entries)) continue;
        const filtered = entries.filter(entry => id(entry) !== "omarchy.workspaces");
        if (filtered.length !== entries.length) {
            layout[section] = filtered;
            changed = true;
        }
    }
    return changed;
}
