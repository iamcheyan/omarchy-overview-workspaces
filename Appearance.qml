pragma Singleton
import QtQuick
import qs.Commons

QtObject {
    readonly property QtObject colors: QtObject {
        // Keep the overview surfaces on Omarchy's active theme palette.
        property color colLayer1: Color.background
        property color colLayer1Hover: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08)
        property color colLayer2: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.04)
        property color colLayer2Hover: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08)
        property color colLayer2Active: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.22)
        property color colOnLayer1: Color.foreground
        property color colSurfaceContainerLow: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.04)
        property color colSurfaceContainer: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08)
    }
    readonly property QtObject font: QtObject {
        readonly property QtObject pixelSize: QtObject {
            property int smaller: 13
            property int small: 14
            property int normal: 16
        }
    }
    readonly property QtObject rounding: QtObject {
        property int small: 0
        property int large: 0
        property int verysmall: 0
    }
}
