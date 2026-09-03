import QtQuick
import qs.Commons
import qs.Ui

// One line of the "most used" strip: rank, icon, name, launch count. Sits
// beside the chart and carries the exact numbers the arcs only suggest, and
// launches on click like any tile in the grid below it.
Item {
  id: root

  property int rank: 1
  property string label: ""
  property url iconUrl: ""
  property int count: 0
  property string countIcon: ""
  property bool missing: false
  // The colour of the category this application lives in, which is also the
  // colour of its orbit in the chart — that is what ties the two together.
  property color accent: Color.accent
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property int iconSize: Style.space(18)

  signal activated()

  readonly property bool hovered: mouse.containsMouse

  implicitHeight: Math.max(root.iconSize, Style.font.body) + Style.space(6)

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(6)
    color: root.hovered ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16) : "transparent"

    Behavior on color { ColorAnimation { duration: 110 } }
  }

  Text {
    id: rankLabel
    textFormat: Text.PlainText
    // Zero-padded so the column stays a column past nine.
    text: root.rank < 10 ? "0" + root.rank : String(root.rank)
    color: root.accent
    opacity: root.hovered ? 1 : 0.8
    font.family: root.fontFamily
    font.pixelSize: Math.max(7, Math.round(Style.font.caption * 0.9))
    font.bold: true
    horizontalAlignment: Text.AlignRight
    width: Style.space(15)
    anchors.left: parent.left
    anchors.leftMargin: Style.space(4)
    anchors.verticalCenter: parent.verticalCenter
  }

  Image {
    id: icon
    width: root.iconSize
    height: root.iconSize
    fillMode: Image.PreserveAspectFit
    sourceSize.width: width * Screen.devicePixelRatio
    sourceSize.height: height * Screen.devicePixelRatio
    source: root.iconUrl
    asynchronous: true
    opacity: root.missing ? 0.35 : 1
    anchors.left: rankLabel.right
    anchors.leftMargin: Style.space(7)
    anchors.verticalCenter: parent.verticalCenter
  }

  Text {
    id: name
    textFormat: Text.PlainText
    text: root.label
    color: root.missing ? Qt.darker(root.foreground, 1.8) : root.foreground
    opacity: root.hovered ? 1 : 0.88
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
    // Sized to the name rather than stretched to the badge, so the leader
    // below can start where the word actually ends.
    width: Math.max(0, Math.min(implicitWidth, badge.x - x - Style.space(16)))
    anchors.left: icon.right
    anchors.leftMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
  }

  // A leader between the name and its number. The panel is as wide as the tile
  // grid below it, which leaves far more space here than five short names need
  // — without this the counts read as floating loose in the middle of the card.
  Rectangle {
    height: 1
    color: root.foreground
    opacity: root.hovered ? 0.22 : 0.10
    anchors.left: name.right
    anchors.leftMargin: Style.space(6)
    anchors.right: badge.left
    anchors.rightMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    visible: width > Style.space(8)
  }

  CountBadge {
    id: badge
    count: root.count
    countIcon: root.countIcon
    accent: root.accent
    foreground: root.foreground
    fontFamily: root.fontFamily
    strong: root.hovered
    anchors.right: parent.right
    anchors.rightMargin: Style.space(4)
    anchors.verticalCenter: parent.verticalCenter
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton
    onClicked: root.activated()
  }
}
