import QtQuick
import qs.Commons

Text {
    id: root

    property string symbol: "apps"
    property real iconSize: 18

    function glyphFor(name) {
        switch (String(name || "apps")) {
        case "add": return "\uF067";                // fa-plus
        case "apps": return "\uF00A";                // fa-th-large
        case "select_window": return "\uF24D";       // fa-object-group
        case "terminal": return "\uF120";            // fa-terminal
        case "search": return "\uF002";              // fa-search
        case "menu": return "\uF0C9";                // fa-bars
        default: return "\uF00A";                     // fa-th-large
        }
    }

    text: root.glyphFor(root.symbol)
    renderType: Text.NativeRendering
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    font {
        // Style.fontFamily is not guaranteed to contain private-use Nerd Font
        // glyphs. Keep the icon font explicit; changing this to the text theme
        // font makes every fallback icon render as an empty box.
        family: "JetBrainsMono Nerd Font"
        pixelSize: root.iconSize
    }
}
