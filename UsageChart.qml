import QtQuick
import qs.Commons

// The launch-count readout for the "most used" strip.
//
// One glowing arc per application, on its own orbit, its length the share of
// that application's count against the busiest one — read outward-in, top ring
// is the most-opened. Around it a HUD frame: corner brackets, twelve faint
// spokes, and a core carrying the total.
//
// Deliberately not a bar chart, a pie, or a donut. Those all spend their ink
// on comparing every slice against every other, which is not the question here
// — the rows beside the chart already carry the exact numbers, so what this
// has to do is give the shape of the habit at a glance and look like an
// instrument while doing it.
Item {
  id: root

  // [{ count, color }] in the same order as the rows beside it. Colours are
  // hex strings, the category colour each application inherits.
  property var series: []
  property int maxCount: 1
  property int total: 0
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  // Swept from 0 to 1 when the panel opens, so the arcs draw themselves in
  // rather than snapping into place fully formed.
  property real progress: 0

  // At most this many orbits fit before the rings are too thin to read.
  readonly property int maxRings: 6
  // How many empty tracks to draw when there is nothing to show yet, so the
  // instrument reads as idle rather than broken on the day it is installed.
  property int placeholderRings: 5

  implicitWidth: Style.space(88)
  implicitHeight: Style.space(88)

  function replay() {
    root.progress = 0
    sweep.restart()
  }

  NumberAnimation {
    id: sweep
    target: root
    property: "progress"
    from: 0
    to: 1
    duration: 620
    easing.type: Easing.OutCubic
  }

  onSeriesChanged: canvas.requestPaint()
  onMaxCountChanged: canvas.requestPaint()
  onProgressChanged: canvas.requestPaint()
  onForegroundChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true
    renderStrategy: Canvas.Cooperative

    // Category colours arrive as hex strings — they come out of a plain JS
    // model, so they are never QColor by the time they get here.
    function tone(value, a) {
      var text = String(value || "").replace(/^#/, "")
      if (text.length === 3)
        text = text.charAt(0) + text.charAt(0) + text.charAt(1) + text.charAt(1) + text.charAt(2) + text.charAt(2)
      var r = parseInt(text.substring(0, 2), 16)
      var g = parseInt(text.substring(2, 4), 16)
      var b = parseInt(text.substring(4, 6), 16)
      if (!isFinite(r) || !isFinite(g) || !isFinite(b))
        return Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, a)
      return Qt.rgba(r / 255, g / 255, b / 255, a)
    }

    function shade(a) {
      return Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, a)
    }

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()

      var size = Math.min(width, height)
      if (size < 24) return

      var cx = width / 2
      var cy = height / 2
      var outer = size / 2 - 1
      var inner = outer * 0.40

      // ---- frame: corner brackets ------------------------------------------
      var arm = size * 0.20
      var l = 1, t = 1, r = width - 1, b = height - 1
      ctx.strokeStyle = shade(0.26)
      ctx.lineWidth = 1
      ctx.lineCap = "butt"
      ctx.beginPath()
      ctx.moveTo(l, t + arm); ctx.lineTo(l, t); ctx.lineTo(l + arm, t)
      ctx.moveTo(r - arm, t); ctx.lineTo(r, t); ctx.lineTo(r, t + arm)
      ctx.moveTo(r, b - arm); ctx.lineTo(r, b); ctx.lineTo(r - arm, b)
      ctx.moveTo(l + arm, b); ctx.lineTo(l, b); ctx.lineTo(l, b - arm)
      ctx.stroke()

      // ---- spokes ----------------------------------------------------------
      ctx.strokeStyle = shade(0.09)
      for (var s = 0; s < 12; s++) {
        var ang = (Math.PI * 2 / 12) * s - Math.PI / 2
        ctx.beginPath()
        ctx.moveTo(cx + Math.cos(ang) * (inner + 2), cy + Math.sin(ang) * (inner + 2))
        ctx.lineTo(cx + Math.cos(ang) * outer, cy + Math.sin(ang) * outer)
        ctx.stroke()
      }

      // ---- orbits ----------------------------------------------------------
      var list = (root.series || []).slice(0, root.maxRings)
      var rings = Math.max(1, list.length > 0 ? list.length : Math.min(root.maxRings, root.placeholderRings))
      var band = (outer - inner - 2) / rings
      var stroke = Math.max(1.5, band * 0.56)
      // A notch at the top keeps a full-length arc from closing into a plain
      // ring, where the start and the end would be indistinguishable.
      var notch = Math.PI * 0.16
      var start = -Math.PI / 2 + notch / 2
      var span = Math.PI * 2 - notch
      var ceiling = Math.max(1, root.maxCount)

      ctx.lineCap = "round"

      // Idle: the tracks, and nothing on them.
      if (list.length === 0) {
        for (var e = 0; e < rings; e++) {
          var idleRadius = outer - 1 - band * e - band / 2
          if (idleRadius <= stroke) continue
          ctx.beginPath()
          ctx.strokeStyle = shade(0.11)
          ctx.lineWidth = stroke
          ctx.arc(cx, cy, idleRadius, start, start + span, false)
          ctx.stroke()
        }
      }

      for (var i = 0; i < list.length; i++) {
        var item = list[i] || {}
        var radius = outer - 1 - band * i - band / 2
        if (radius <= stroke) continue

        ctx.beginPath()
        ctx.strokeStyle = shade(0.07)
        ctx.lineWidth = stroke
        ctx.arc(cx, cy, radius, start, start + span, false)
        ctx.stroke()

        var ratio = Math.max(0, Math.min(1, (Number(item.count) || 0) / ceiling))
        var end = start + span * ratio * root.progress
        if (end - start < 0.004) continue

        ctx.beginPath()
        ctx.strokeStyle = tone(item.color, 0.15)
        ctx.lineWidth = stroke * 2.4
        ctx.arc(cx, cy, radius, start, end, false)
        ctx.stroke()

        ctx.beginPath()
        ctx.strokeStyle = tone(item.color, 0.95)
        ctx.lineWidth = stroke
        ctx.arc(cx, cy, radius, start, end, false)
        ctx.stroke()

        // Leading head, so the eye lands on where each orbit got to.
        var hx = cx + Math.cos(end) * radius
        var hy = cy + Math.sin(end) * radius
        ctx.beginPath()
        ctx.fillStyle = tone(item.color, 0.22)
        ctx.arc(hx, hy, stroke * 1.35, 0, Math.PI * 2)
        ctx.fill()
        ctx.beginPath()
        ctx.fillStyle = tone(item.color, 1.0)
        ctx.arc(hx, hy, stroke * 0.52, 0, Math.PI * 2)
        ctx.fill()
      }

      // ---- core ------------------------------------------------------------
      ctx.beginPath()
      ctx.fillStyle = shade(0.05)
      ctx.arc(cx, cy, inner, 0, Math.PI * 2)
      ctx.fill()
      ctx.beginPath()
      ctx.strokeStyle = shade(0.20)
      ctx.lineWidth = 1
      ctx.arc(cx, cy, inner, 0, Math.PI * 2)
      ctx.stroke()
    }
  }

  Column {
    anchors.centerIn: parent
    spacing: 0

    Text {
      textFormat: Text.PlainText
      text: root.total > 0 ? String(root.total) : "—"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
      anchors.horizontalCenter: parent.horizontalCenter
    }

    Text {
      textFormat: Text.PlainText
      text: "OPENS"
      color: root.foreground
      opacity: 0.45
      font.family: root.fontFamily
      font.pixelSize: Math.max(6, Math.round(Style.font.caption * 0.72))
      font.letterSpacing: 0.5
      horizontalAlignment: Text.AlignHCenter
      anchors.horizontalCenter: parent.horizontalCenter
    }
  }
}
