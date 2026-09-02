import QtQuick
import qs.Commons
import qs.Ui
import "AppsModel.js" as Model

// Add-an-app overlay. Takes over the card while the user is picking, so the
// panel never has to grow a second window: type to narrow the list, Enter or
// click to add, Esc to go back.
Item {
  id: root

  property string categoryName: ""
  // Every installed application as { id, name, detail, icon }, already
  // stripped of hidden entries by the caller.
  property var entries: []
  // Ids already in the target category — shown, but marked and inert.
  property var takenIds: []
  property var iconFor: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property int rowHeight: Style.space(34)

  signal picked(string appId)
  signal cancelled()

  readonly property var matches: {
    var query = search.text
    var list = []
    for (var i = 0; i < root.entries.length; i++) {
      if (Model.matchesQuery(root.entries[i], query)) list.push(root.entries[i])
    }
    return list
  }

  function focusSearch() {
    search.forceActiveFocus()
    search.selectAll()
  }

  function commit(index) {
    var row = root.matches[index]
    if (!row) return
    if (root.takenIds.indexOf(row.id) !== -1) return
    root.picked(row.id)
  }

  function step(delta) {
    if (list.count === 0) return
    var next = list.currentIndex + delta
    list.currentIndex = Math.max(0, Math.min(list.count - 1, next))
    list.positionViewAtIndex(list.currentIndex, ListView.Contain)
  }

  onMatchesChanged: list.currentIndex = 0

  Text {
    id: title
    textFormat: Text.PlainText
    text: "Add to " + root.categoryName
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.subtitle
    font.bold: true
    anchors.left: parent.left
    anchors.top: parent.top
  }

  PanelActionButton {
    id: back
    iconText: "✕"
    tooltipText: "Back"
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
    size: Style.space(20)
    anchors.right: parent.right
    anchors.verticalCenter: title.verticalCenter
    onClicked: root.cancelled()
  }

  TextField {
    id: search
    placeholderText: "Search applications"
    foreground: root.foreground
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: title.bottom
    anchors.topMargin: Style.space(10)

    Keys.onEscapePressed: root.cancelled()
    Keys.onDownPressed: root.step(1)
    Keys.onUpPressed: root.step(-1)
    Keys.onReturnPressed: root.commit(list.currentIndex)
    Keys.onEnterPressed: root.commit(list.currentIndex)
  }

  ListView {
    id: list
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: search.bottom
    anchors.bottom: parent.bottom
    anchors.topMargin: Style.space(10)
    clip: true
    model: root.matches
    currentIndex: 0
    boundsBehavior: Flickable.StopAtBounds

    delegate: Rectangle {
      id: row
      required property var modelData
      required property int index

      readonly property bool taken: root.takenIds.indexOf(modelData.id) !== -1
      readonly property bool hot: rowMouse.containsMouse || list.currentIndex === row.index

      width: ListView.view.width
      height: root.rowHeight
      radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(6)
      color: row.hot ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.09) : "transparent"

      Image {
        id: rowIcon
        width: Style.space(20)
        height: Style.space(20)
        fillMode: Image.PreserveAspectFit
        sourceSize.width: width * Screen.devicePixelRatio
        sourceSize.height: height * Screen.devicePixelRatio
        source: root.iconFor ? root.iconFor(row.modelData.icon) : ""
        asynchronous: true
        opacity: row.taken ? 0.4 : 1
        anchors.left: parent.left
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: row.modelData.name + (row.taken ? "  ·  added" : "")
        color: root.foreground
        opacity: row.taken ? 0.45 : 1
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: rowIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }

      MouseArea {
        id: rowMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: row.taken ? Qt.ArrowCursor : Qt.PointingHandCursor
        onEntered: list.currentIndex = row.index
        onClicked: root.commit(row.index)
      }
    }
  }

  Text {
    visible: list.count === 0
    textFormat: Text.PlainText
    text: "No application matches “" + search.text + "”"
    color: Qt.darker(root.foreground, 1.5)
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: search.bottom
    anchors.topMargin: Style.space(24)
  }
}
