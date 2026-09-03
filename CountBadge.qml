import QtQuick
import qs.Commons

// The launch counter: a small glyph and a number, in the colour of the
// application's category. It sits on tiles and on the most-used rows, and it
// is meant to be read only when looked for — dim at rest, full strength under
// the pointer — because a launcher covered in numbers stops being a launcher.
Item {
  id: root

  property int count: 0
  property string countIcon: ""
  property color accent: Color.accent
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  // Set while the thing the badge belongs to is hovered or selected.
  property bool strong: false
  // Whether a count of zero still draws. Tiles pass true: a launcher where the
  // badges only appear once you have used it is a launcher whose counter
  // nobody can find on the day they install it.
  property bool showZero: false

  visible: root.count > 0 || root.showZero
  implicitWidth: plate.implicitWidth
  implicitHeight: plate.implicitHeight
  width: implicitWidth
  height: implicitHeight
  opacity: root.strong ? 1.0 : (root.count > 0 ? 0.62 : 0.34)

  Behavior on opacity { NumberAnimation { duration: 110 } }

  Rectangle {
    id: plate
    anchors.centerIn: parent
    implicitWidth: content.implicitWidth + Style.space(8)
    implicitHeight: content.implicitHeight + Style.space(3)
    width: implicitWidth
    height: implicitHeight
    radius: height / 2
    color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, root.strong ? 0.30 : 0.20)

    Row {
      id: content
      anchors.centerIn: parent
      spacing: Style.space(3)

      Text {
        textFormat: Text.PlainText
        text: root.countIcon
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: Math.max(7, Math.round(Style.font.caption * 0.92))
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: String(root.count)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Math.max(7, Math.round(Style.font.caption * 0.92))
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }
}
