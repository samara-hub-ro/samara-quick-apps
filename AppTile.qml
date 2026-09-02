import QtQuick
import qs.Commons
import qs.Ui

// One application in the grid: icon, optional label, and — only while the
// panel is in edit mode and the pointer is on the tile — the remove and
// reorder affordances. Nothing but the icon shows at rest, which is the
// whole point of the widget.
Item {
  id: root

  property string appId: ""
  property string label: ""
  property url iconUrl: ""
  property int iconSize: 34
  property bool showLabel: true
  property bool selected: false
  property bool editing: false
  property bool missing: false
  property bool canMoveLeft: false
  property bool canMoveRight: false
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  signal activated()
  signal removeRequested()
  signal moveRequested(int direction)
  signal pointerEntered()

  readonly property bool hovered: mouse.containsMouse
  readonly property bool highlighted: hovered || selected
  readonly property int labelHeight: showLabel ? Math.ceil(Style.font.caption * 2.4) : 0

  implicitWidth: Math.max(iconSize + Style.space(18), showLabel ? Style.space(74) : iconSize + Style.space(18))
  implicitHeight: Style.space(8) + iconSize + (showLabel ? Style.space(4) + labelHeight : 0) + Style.space(8)

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(6)
    color: root.highlighted ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, root.selected ? 0.16 : 0.09) : "transparent"

    Behavior on color { ColorAnimation { duration: 110 } }
  }

  Image {
    id: icon
    width: root.iconSize
    height: root.iconSize
    fillMode: Image.PreserveAspectFit
    // Decode at physical pixels, or PNG icons come out soft on HiDPI.
    sourceSize.width: width * Screen.devicePixelRatio
    sourceSize.height: height * Screen.devicePixelRatio
    source: root.iconUrl
    asynchronous: true
    opacity: root.missing ? 0.35 : 1
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.top
    anchors.topMargin: Style.space(8)
  }

  Text {
    visible: root.showLabel
    textFormat: Text.PlainText
    text: root.label
    color: root.missing ? Qt.darker(root.foreground, 1.8) : root.foreground
    opacity: root.highlighted ? 1 : 0.78
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.Wrap
    maximumLineCount: 2
    elide: Text.ElideRight
    height: root.labelHeight
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Style.space(3)
    anchors.rightMargin: Style.space(3)
    anchors.top: icon.bottom
    anchors.topMargin: Style.space(4)
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton
    onEntered: root.pointerEntered()
    onClicked: root.activated()
  }

  // ---- edit affordances ----------------------------------------------------

  PanelActionButton {
    visible: root.editing && root.highlighted
    iconText: "✕"
    tooltipText: "Remove"
    foreground: root.foreground
    hoverColor: Color.urgent
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
    size: Style.space(18)
    anchors.right: parent.right
    anchors.top: parent.top
    onClicked: root.removeRequested()
  }

  Row {
    visible: root.editing && root.highlighted
    spacing: Style.space(2)
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom

    PanelActionButton {
      iconText: "‹"
      tooltipText: "Move left"
      enabled: root.canMoveLeft
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      size: Style.space(18)
      onClicked: root.moveRequested(-1)
    }

    PanelActionButton {
      iconText: "›"
      tooltipText: "Move right"
      enabled: root.canMoveRight
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      size: Style.space(18)
      onClicked: root.moveRequested(1)
    }
  }
}
