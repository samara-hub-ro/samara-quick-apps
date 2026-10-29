import QtQuick
import qs.Commons
import qs.Ui

// One application in the grid. At rest it is an icon and its name, and
// nothing else: the theme's text colour, no badge, no tint. The accent is
// spent on exactly two things — the short bar under an application that is
// already open, and the keyboard cursor — so that whatever carries it is
// worth looking at.
//
// The remove and reorder affordances appear only in edit mode, under the
// pointer.
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
  // False while the grid is sorted by launch count: the tile order is derived
  // then, so a move button would either lie or fight the sort.
  property bool canReorder: true
  // Open windows this application has right now; 0 hides the marker.
  property int windows: 0
  // A key that launches this tile straight away ("1".."9"), shown only while
  // the panel owns the keyboard.
  property string hint: ""
  property color accent: Color.accent
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  // Cascade-in on open: tiles fade up in reading order, a few milliseconds
  // apart. `revealToken` changing is the cue; `revealOrder` is the place in
  // the queue.
  property int revealOrder: 0
  property int revealToken: 0

  signal activated()
  signal newInstanceRequested()
  signal removeRequested()
  signal moveRequested(int direction)
  signal pointerEntered()
  signal pointerExited()

  readonly property bool hovered: mouse.containsMouse
  readonly property bool highlighted: hovered || selected
  readonly property int labelHeight: showLabel ? Math.ceil(Style.font.caption * 2.4) : 0

  implicitWidth: Math.max(iconSize + Style.space(18), showLabel ? Style.space(74) : iconSize + Style.space(18))
  implicitHeight: Style.space(8) + iconSize + Style.space(6) + (showLabel ? labelHeight : 0) + Style.space(4)

  onRevealTokenChanged: {
    reveal.stop()
    content.opacity = 0
    content.shift = Style.space(6)
    reveal.start()
  }

  SequentialAnimation {
    id: reveal
    PauseAnimation { duration: Math.min(root.revealOrder * 12, 240) }
    ParallelAnimation {
      NumberAnimation { target: content; property: "opacity"; to: 1; duration: 180; easing.type: Easing.OutCubic }
      NumberAnimation { target: content; property: "shift"; to: 0; duration: 220; easing.type: Easing.OutCubic }
    }
  }

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(6)
    color: root.selected
      ? Util.alpha(root.accent, 0.14)
      : (root.hovered ? Util.alpha(root.foreground, Style.hoverFillAlpha) : "transparent")
    border.width: root.selected ? 1 : 0
    border.color: Util.alpha(root.accent, 0.7)

    Behavior on color { ColorAnimation { duration: 110 } }
  }

  Item {
    id: content
    property real shift: 0
    width: parent.width
    height: parent.height
    y: shift

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
      scale: root.hovered && !root.editing ? 1.07 : 1
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Style.space(8)

      Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    }

    // Open-window marker. One window is a dot, more is a short bar — enough to
    // tell "open" from "open twice" without a number to read.
    Rectangle {
      visible: root.windows > 0
      width: root.windows > 1 ? Style.space(12) : Style.space(4)
      height: Math.max(2, Style.space(3))
      radius: height / 2
      color: root.accent
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: icon.bottom
      anchors.topMargin: Style.space(2)

      Behavior on width { NumberAnimation { duration: 140 } }
    }

    Text {
      visible: root.showLabel
      textFormat: Text.PlainText
      text: root.label
      color: root.foreground
      opacity: root.missing ? 0.4 : (root.highlighted ? 1 : 0.72)
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
      anchors.topMargin: Style.space(6)

      Behavior on opacity { NumberAnimation { duration: 110 } }
    }

    Text {
      visible: root.hint.length > 0 && !root.editing
      textFormat: Text.PlainText
      text: root.hint
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.leftMargin: Style.space(5)
      anchors.topMargin: Style.space(3)
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    onEntered: root.pointerEntered()
    onExited: root.pointerExited()
    onClicked: function(event) {
      if (event.button === Qt.MiddleButton) root.newInstanceRequested()
      else root.activated()
    }
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
    visible: root.editing && root.highlighted && root.canReorder
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
