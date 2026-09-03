import QtQuick

// The Quick Apps bar mark: a downward-pointing triangle with an S carved out
// of it. The triangle says "this drops a panel"; the S is the samara mark.
//
// Drawn rather than shipped as an SVG so it takes the bar's own colour — the
// active tint included — without a graphical-effects dependency, and so it
// stays crisp at whatever size the bar's icon slot happens to be.
//
// Every number below was tuned against renders at 14, 16, 18, 20, 26 and 40
// pixels, which is the range a bar icon actually lands in. Two of them matter
// more than they look: the S is carved rather than painted on, so the mark is
// a single silhouette that works on any bar background; and it is kept well
// inside the triangle's widest third, because an S that reaches the sloped
// edges breaks the silhouette at small sizes and the whole thing turns to mush.
Item {
  id: root

  property color color: "white"
  // Fractions of the shorter side throughout, so the mark scales with its slot
  // rather than being pinned to one bar height.
  property real weight: 0.105
  property real corner: 0.085

  onColorChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true
    renderStrategy: Canvas.Cooperative

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()

      var size = Math.min(width, height)
      if (size < 5) return
      var ox = (width - size) / 2
      var oy = (height - size) / 2
      function px(v) { return ox + v * size }
      function py(v) { return oy + v * size }

      // ---- the triangle ----------------------------------------------------
      // Filled and stroked with a round join: the stroke is what softens the
      // three corners, and in particular keeps the bottom point a nib rather
      // than a needle that disappears into one pixel.
      var left = 0.07, right = 0.93, top = 0.15, bottom = 0.93
      var mid = (left + right) / 2

      ctx.beginPath()
      ctx.moveTo(px(mid), py(top))
      ctx.lineTo(px(right), py(top))
      ctx.lineTo(px(mid), py(bottom))
      ctx.lineTo(px(left), py(top))
      ctx.closePath()

      ctx.fillStyle = root.color
      ctx.strokeStyle = root.color
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      ctx.lineWidth = root.corner * size
      ctx.fill()
      ctx.stroke()

      // ---- the S, cut straight out of it -----------------------------------
      ctx.globalCompositeOperation = "destination-out"
      ctx.strokeStyle = "#000000"
      ctx.lineWidth = Math.max(1.1, root.weight * size)
      ctx.lineCap = "round"
      ctx.lineJoin = "round"

      ctx.beginPath()
      ctx.moveTo(px(0.618), py(0.352))
      ctx.bezierCurveTo(px(0.618), py(0.272), px(0.404), py(0.272), px(0.404), py(0.362))
      ctx.bezierCurveTo(px(0.404), py(0.442), px(0.606), py(0.432), px(0.606), py(0.527))
      ctx.bezierCurveTo(px(0.606), py(0.617), px(0.428), py(0.622), px(0.415), py(0.557))
      ctx.stroke()

      ctx.globalCompositeOperation = "source-over"
    }
  }
}
