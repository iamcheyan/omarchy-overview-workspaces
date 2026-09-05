pragma Singleton
import QtQuick

QtObject {
    readonly property QtObject options: QtObject {
        readonly property QtObject overview: QtObject {
            property bool enable: true
            property int columns: 5
            property bool centerIcons: true
            property bool orderRightLeft: false
        }
        readonly property QtObject background: QtObject { property string wallpaperPath: ""; property string thumbnailPath: "" }
    }
}
