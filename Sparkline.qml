import QtQuick
import qs.Commons

// A line over time, in one colour: a stroke and a faint wash under it. No
// axes and no grid — the number beside it carries the value; the line only
// has to show which way it is going and how spiky it has been.
//
// The vertical scale floats with the data but never drops below `floor`, so
// an idle machine draws a calm line near the bottom instead of magnifying
// noise into mountains.
Canvas {
  id: root

  property var values: []
  property color color: Color.accent
  property real floor: 10
  property int capacity: 60
  property real lineWidth: Math.max(1, Style.space(1.5))

  readonly property real peak: {
    var m = root.floor
    for (var i = 0; i < (root.values || []).length; i++) m = Math.max(m, Number(root.values[i]) || 0)
    return m
  }

  onValuesChanged: requestPaint()
  onColorChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    var list = root.values || []
    if (list.length < 2 || width <= 0 || height <= 0) return

    var pad = root.lineWidth
    var h = height - pad * 2
    // Right-aligned: the newest sample is always at the right edge, and a
    // short history starts partway in rather than stretching to fill.
    var step = width / Math.max(1, root.capacity - 1)
    var x0 = width - (list.length - 1) * step

    function yOf(v) { return pad + h - Math.max(0, Math.min(1, (Number(v) || 0) / root.peak)) * h }

    ctx.beginPath()
    ctx.moveTo(x0, height)
    for (var i = 0; i < list.length; i++) ctx.lineTo(x0 + i * step, yOf(list[i]))
    ctx.lineTo(width, height)
    ctx.closePath()
    ctx.fillStyle = Qt.rgba(root.color.r, root.color.g, root.color.b, 0.14)
    ctx.fill()

    ctx.beginPath()
    for (var j = 0; j < list.length; j++) {
      if (j === 0) ctx.moveTo(x0, yOf(list[0]))
      else ctx.lineTo(x0 + j * step, yOf(list[j]))
    }
    ctx.lineWidth = root.lineWidth
    ctx.lineJoin = "round"
    ctx.strokeStyle = root.color
    ctx.stroke()

    // The present, marked.
    ctx.beginPath()
    ctx.arc(width - pad, yOf(list[list.length - 1]), root.lineWidth * 1.4, 0, Math.PI * 2)
    ctx.fillStyle = root.color
    ctx.fill()
  }
}
