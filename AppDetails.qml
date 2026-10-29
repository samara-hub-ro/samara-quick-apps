import QtQuick
import qs.Commons
import qs.Ui

// The card that slides out beside the panel while the pointer rests on a
// tile: what the application is, which version is on disk, when it arrived and
// when it last changed, and how you actually use it.
//
// Two colours, like the rest of the panel — the theme's text and its accent —
// and only facts. A row whose value is unknown is left out rather than shown
// as a dash, so the card is as short as what there is to say.
//
// For an application that is open it also shows what it is costing right now
// — CPU, memory, TCP traffic, a short CPU line — and a Force quit button. The
// button is two clicks on purpose: the first arms it, the second ends the
// application, so a stray click on a card you were only reading never closes
// anything.
BorderSurface {
  id: root

  property var app: null
  property url iconUrl: ""
  // From AppInfo; null while the lookup is still running.
  property var info: null
  property bool loading: false
  property int launchCount: 0
  property string lastLaunch: ""
  property string countingSince: ""
  property int windows: 0
  property string category: ""
  property bool focusRunning: true
  // From ProcMonitor, summed over the application's groups; null when it is
  // not open or not sampled yet.
  property var stats: null
  property int sampleCapacity: 60
  // "", "armed" (one more click ends it), "ending" (TERM sent),
  // "stubborn" (still there after TERM; the next click is KILL).
  property string quitState: ""

  signal quitClicked()

  readonly property bool hovered: cardHover.hovered

  property color foreground: Color.popups.text
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property real surfaceOpacity: 1.0

  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color danger: Color.urgent
  readonly property int cardWidth: Style.space(272)

  width: cardWidth
  height: body.implicitHeight + contentTopInset + contentBottomInset
  padding: Style.spacing.popupPadding
  radius: Style.cornerRadius
  color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, root.surfaceOpacity)
  borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

  HoverHandler { id: cardHover }

  // Swallow clicks that miss the button, so they never reach whatever is
  // behind the card.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.AllButtons
  }

  // ---- formatting ----------------------------------------------------------

  function bytes(n) {
    var v = Number(n) || 0
    if (v < 1024) return Math.round(v) + " B"
    var units = ["KB", "MB", "GB", "TB"]
    var i = -1
    do { v /= 1024; i++ } while (v >= 1024 && i < units.length - 1)
    return (v >= 100 ? Math.round(v) : v.toFixed(1)) + " " + units[i]
  }

  function percent(n) {
    var v = Number(n) || 0
    return (v > 0 && v < 0.1 ? "<0.1" : (v >= 10 ? Math.round(v) : v.toFixed(1))) + "%"
  }

  function clock(ms) {
    var d = new Date(Number(ms) || 0)
    return d.toLocaleTimeString(Qt.locale(), "HH:mm")
  }

  function parseDate(iso) {
    var text = String(iso || "")
    if (text.length === 0) return null
    var d = new Date(text)
    return isNaN(d.getTime()) ? null : d
  }

  function ago(iso) {
    var d = root.parseDate(iso)
    if (!d) return ""
    var s = Math.max(0, (Date.now() - d.getTime()) / 1000)
    if (s < 60) return "just now"
    if (s < 3600) return Math.floor(s / 60) + " min ago"
    if (s < 86400) return Math.floor(s / 3600) + " h ago"
    var days = Math.floor(s / 86400)
    if (days === 1) return "yesterday"
    if (days < 45) return days + " days ago"
    if (days < 365) return Math.round(days / 30) + " months ago"
    var years = Math.floor(days / 365)
    return years === 1 ? "a year ago" : years + " years ago"
  }

  function dateOf(iso) {
    var d = root.parseDate(iso)
    return d ? d.toLocaleDateString(Qt.locale(), "d MMM yyyy") : ""
  }

  function dated(iso) {
    var day = root.dateOf(iso)
    if (day.length === 0) return ""
    return day + "  ·  " + root.ago(iso)
  }

  readonly property var facts: info || ({})

  readonly property string sourceLabel: {
    switch (String(facts.source || "")) {
    case "pacman": return "pacman"
    case "flatpak": return "Flatpak"
    case "webapp": return "Web app"
    case "appimage": return "AppImage"
    case "local": return "Local entry"
    default: return ""
    }
  }

  readonly property string versionLabel: {
    var v = String(facts.version || "")
    // pkgrel is packaging noise to anyone reading "which version is this".
    if (String(facts.source || "") === "pacman") v = v.replace(/-[0-9.]+$/, "")
    return v
  }

  readonly property var rows: {
    var out = []
    var a = root.app || {}
    if (a.missing) {
      out.push({ k: "Status", v: "No longer installed" })
      return out
    }
    if (facts.installed) out.push({ k: "Installed", v: root.dated(facts.installed) })
    if (facts.updated && facts.updated !== facts.installed) out.push({ k: "Updated", v: root.dated(facts.updated) })
    if (facts.size) out.push({ k: "Size", v: String(facts.size) })
    if (facts.pkg && facts.source !== "flatpak") out.push({ k: "Package", v: String(facts.pkg) })
    if (facts.source === "flatpak" && facts.pkg) out.push({ k: "App ID", v: String(facts.pkg) })
    if (facts.source === "webapp" && facts.url) out.push({ k: "Opens", v: String(facts.url).replace(/^https?:\/\//, "") })
    if (!a.external) {
      var opened = root.launchCount === 1 ? "once" : root.launchCount + " times"
      if (root.launchCount > 0 && root.lastLaunch.length > 0) opened += "  ·  last " + root.ago(root.lastLaunch)
      out.push({ k: "Opened", v: opened })
    }
    if (root.category.length > 0) out.push({ k: "In", v: root.category })
    return out
  }

  // ---- layout --------------------------------------------------------------

  Column {
    id: body
    x: root.contentLeftInset
    y: root.contentTopInset
    width: root.width - root.contentLeftInset - root.contentRightInset
    spacing: Style.space(8)

    Item {
      width: parent.width
      implicitHeight: Math.max(icon.height, titleColumn.implicitHeight)

      Image {
        id: icon
        width: Style.space(38)
        height: Style.space(38)
        fillMode: Image.PreserveAspectFit
        sourceSize.width: width * Screen.devicePixelRatio
        sourceSize.height: height * Screen.devicePixelRatio
        source: root.iconUrl
        asynchronous: true
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        id: titleColumn
        anchors.left: icon.right
        anchors.leftMargin: Style.space(12)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.app ? root.app.name : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          elide: Text.ElideRight
        }

        Row {
          spacing: Style.space(6)

          Text {
            visible: root.versionLabel.length > 0
            textFormat: Text.PlainText
            text: root.versionLabel
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Text {
            visible: root.sourceLabel.length > 0
            textFormat: Text.PlainText
            text: (root.versionLabel.length > 0 ? "·  " : "") + root.sourceLabel
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: root.loading && !root.info
            textFormat: Text.PlainText
            text: "reading package…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    Text {
      visible: text.length > 0
      width: parent.width
      textFormat: Text.PlainText
      text: root.app ? String(root.app.detail || "") : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
      maximumLineCount: 2
      elide: Text.ElideRight
    }

    PanelSeparator { width: parent.width; visible: factsColumn.visible }

    Column {
      id: factsColumn
      visible: root.rows.length > 0
      width: parent.width
      spacing: Style.space(4)

      Repeater {
        model: root.rows

        delegate: Item {
          required property var modelData
          width: factsColumn.width
          implicitHeight: valueText.implicitHeight

          Text {
            id: keyText
            width: Style.space(70)
            textFormat: Text.PlainText
            text: modelData.k
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.top: parent.top
          }

          Text {
            id: valueText
            anchors.left: keyText.right
            anchors.right: parent.right
            textFormat: Text.PlainText
            text: modelData.v
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }

    // ---- live cost ---------------------------------------------------------

    PanelSeparator { width: parent.width; visible: usageBlock.visible }

    Column {
      id: usageBlock
      visible: root.windows > 0 && root.stats !== null
      width: parent.width
      spacing: Style.space(4)

      Repeater {
        model: [
          { k: "CPU", v: root.stats && root.stats.primed ? root.percent(root.stats.cpu) : "measuring…" },
          { k: "Memory", v: root.stats ? root.bytes(root.stats.mem) : "" },
          { k: "Network", v: root.stats ? "\u2193 " + root.bytes(root.stats.rx) + "    \u2191 " + root.bytes(root.stats.tx) : "" }
        ]

        delegate: Item {
          required property var modelData
          width: usageBlock.width
          implicitHeight: usageValue.implicitHeight

          Text {
            id: usageKey
            width: Style.space(70)
            textFormat: Text.PlainText
            text: modelData.k
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            id: usageValue
            anchors.left: usageKey.right
            anchors.right: parent.right
            textFormat: Text.PlainText
            text: modelData.v
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            elide: Text.ElideRight
          }
        }
      }

      Sparkline {
        width: parent.width
        height: Style.space(30)
        values: root.stats ? root.stats.history : []
        capacity: root.sampleCapacity
        floor: 5
        color: root.accent
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: root.stats ? "CPU over the last 3 min. Network is TCP since " + root.clock(root.stats.since) + "; QUIC/UDP is not counted." : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // The one live fact, set apart: it changes what a click does.
    Item {
      visible: root.windows > 0
      width: parent.width
      implicitHeight: openText.implicitHeight

      Rectangle {
        id: openDot
        width: Style.space(6)
        height: width
        radius: width / 2
        color: root.accent
        anchors.left: parent.left
        y: Math.round((openText.font.pixelSize * 1.3 - height) / 2)
      }

      Text {
        id: openText
        anchors.left: openDot.right
        anchors.leftMargin: Style.space(6)
        anchors.right: parent.right
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: (root.windows === 1 ? "Open in 1 window" : "Open in " + root.windows + " windows")
          + (root.focusRunning ? " — click switches to it, middle-click opens a new one" : "")
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // ---- force quit ----------------------------------------------------------

    Rectangle {
      id: quitButton
      // Only with the monitor's groups in hand: that is what it signals.
      visible: root.windows > 0 && root.stats !== null
      width: parent.width
      height: Style.space(28)
      radius: Style.cornerRadius
      readonly property bool hot: quitMouse.containsMouse
      readonly property bool armed: root.quitState === "armed" || root.quitState === "stubborn"
      color: armed ? Util.alpha(root.danger, 0.85) : (hot ? Util.alpha(root.danger, 0.16) : "transparent")
      border.width: 1
      border.color: Util.alpha(root.danger, armed || hot ? 0.9 : 0.45)

      Behavior on color { ColorAnimation { duration: 110 } }

      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: {
          switch (root.quitState) {
          case "armed": return "Click again to end it"
          case "ending": return "Ending…"
          case "stubborn": return "Still running — click to kill it now"
          default: return "Force quit"
          }
        }
        color: quitButton.armed ? Color.popups.background : root.danger
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      MouseArea {
        id: quitMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: root.quitState === "ending" ? Qt.BusyCursor : Qt.PointingHandCursor
        enabled: root.quitState !== "ending"
        onClicked: root.quitClicked()
      }
    }
  }
}
