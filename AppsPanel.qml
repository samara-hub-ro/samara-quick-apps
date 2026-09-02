import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The popup surface for the Quick Apps widget.
//
// Omarchy ships two popup bases and neither fits a hover launcher on its own:
// Ui/PopupCard has a "hover" trigger mode but is an xdg-popup, so a
// keyboard-summoned open never receives keys; Ui/KeyboardPanel does get keys,
// but it claims the whole screen as its input region, which kills the bar's
// own hover the moment it opens — the cursor would leave the icon as soon as
// the panel appeared. This is KeyboardPanel's geometry and focus handling with
// the input region narrowed to the card, plus a background alpha the widget
// can drive from its settings.
//
// Adapted from omarchy's shell/Ui/KeyboardPanel.qml (MIT).
PanelWindow {
  id: root

  required property Item anchorItem
  required property QtObject bar
  property var owner: null
  property int margin: Style.gapsOut
  property int padding: Style.spacing.popupPadding
  property int gap: Style.gapsOut
  property int contentWidth: Style.space(360)
  property int contentHeight: Style.space(220)
  property color surfaceColor: Color.popups.background
  property real surfaceOpacity: 1.0
  property var borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
  property bool open: false

  // Keyboard focus is claimed only for an open the user asked for by hand —
  // the bar click or the shortcut. A panel that stole the keyboard just
  // because the cursor crossed a bar icon would eat the next keystroke of
  // whatever the user was typing.
  property bool keyboardMode: false
  property Item focusTarget: null
  property bool focusPrimed: false

  readonly property bool hovered: cardHover.hovered

  default property alias contentItem: contentHolder.children

  // The bar paints its "panel open" marker for whichever object holds the
  // popout, and it compares that against the widget item — so the widget, not
  // this window, is the coordinator key.
  readonly property var coordinatorKey: owner || root
  readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
  readonly property string barPos: bar ? bar.position : "top"

  function close() {
    if (owner && "close" in owner) owner.close()
    else root.open = false
  }

  function beginFocusPrime() {
    if (open && keyboardMode && backingWindowVisible) focusPrimeTimer.restart()
  }

  // --- surface --------------------------------------------------------------

  screen: anchorWindow ? anchorWindow.screen : null
  visible: open || card.opacity > 0
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore

  WlrLayershell.namespace: "samara-quick-apps"
  WlrLayershell.layer: WlrLayer.Overlay
  // Prime with Exclusive so a surface summoned from the keyboard actually
  // receives keys, then settle on OnDemand, which releases compositor-wide
  // pointer routing. Mirrors KeyboardPanel; see its comments for the why.
  WlrLayershell.keyboardFocus: (open && keyboardMode)
    ? (focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
    : WlrKeyboardFocus.None

  onBackingWindowVisibleChanged: beginFocusPrime()

  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }

  // Two input regions, one per way of opening.
  //
  // Hover open: only the card takes input, so everything else — the bar
  // included — keeps its own hover. That is what lets the widget tell "the
  // cursor moved from the icon into the panel" from "the cursor left".
  //
  // Keyboard open: the whole screen. Hyprland hands keyboard focus back to
  // whatever sits under the pointer the moment this surface steps down from
  // its Exclusive prime to OnDemand, so a surface that wants to keep the
  // keyboard has to be under the pointer wherever the pointer happens to be.
  // A full region also gives outside clicks something to land on, which is
  // how the panel is dismissed in that mode.
  mask: Region {
    item: root.keyboardMode ? null : card
    width: root.keyboardMode ? root.screenW : 0
    height: root.keyboardMode ? root.screenH : 0
  }

  // Outside-click dismissal, for the keyboard-open region only: in hover mode
  // no click can reach this surface outside the card in the first place.
  MouseArea {
    anchors.fill: parent
    enabled: root.open && root.keyboardMode
    visible: enabled
    acceptedButtons: Qt.AllButtons
    onClicked: root.close()
  }

  // --- geometry -------------------------------------------------------------

  TransformWatcher {
    id: anchorWatcher
    a: anchorWindow ? anchorWindow.contentItem : null
    b: anchorItem
  }

  readonly property point anchorScreenPos: {
    anchorWatcher.transform  // reactive dependency
    if (!anchorItem || !anchorWindow) return Qt.point(0, 0)
    return anchorItem.mapToItem(anchorWindow.contentItem, 0, 0)
  }
  readonly property real anchorW: anchorItem ? anchorItem.width : 0
  readonly property real anchorH: anchorItem ? anchorItem.height : 0
  readonly property real screenW: screen ? screen.width : 0
  readonly property real screenH: screen ? screen.height : 0
  readonly property real barW: anchorWindow ? anchorWindow.width : screenW
  readonly property real barH: anchorWindow ? anchorWindow.height : 0
  readonly property real availableCardWidth: screenW > 0
    ? Math.max(120, screenW - ((barPos === "left" || barPos === "right") ? barW + gap + margin : margin * 2))
    : 0
  readonly property real availableCardHeight: screenH > 0
    ? Math.max(120, screenH - ((barPos === "top" || barPos === "bottom") ? barH + gap + margin : margin * 2))
    : 0
  readonly property real verticalContentInset: padding * 2 + Border.top(borderSpec) + Border.bottom(borderSpec)
  readonly property real horizontalContentInset: padding * 2 + Border.left(borderSpec) + Border.right(borderSpec)

  function fittedContentWidth(width) {
    var desired = Math.max(root.horizontalContentInset, (Number(width) || 0) + root.horizontalContentInset)
    var maxWidth = root.availableCardWidth > 0 ? root.availableCardWidth : desired
    return Math.round(Math.min(desired, maxWidth))
  }

  function fittedContentHeight(height) {
    var desired = Math.max(root.verticalContentInset, (Number(height) || 0) + root.verticalContentInset)
    var maxHeight = root.availableCardHeight > 0 ? root.availableCardHeight : desired
    return Math.round(Math.min(desired, maxHeight))
  }

  // Inner width available to content once padding and borders are taken out.
  readonly property real innerWidth: Math.max(0, contentWidth - horizontalContentInset)
  readonly property real innerHeight: Math.max(0, contentHeight - verticalContentInset)

  readonly property point cardOrigin: {
    if (!anchorItem || !bar) return Qt.point(margin, margin)
    var x = 0, y = 0
    if (barPos === "bottom") {
      x = anchorScreenPos.x + anchorW / 2 - contentWidth / 2
      y = screenH - barH - contentHeight - gap
    } else if (barPos === "left") {
      x = barW + gap
      y = anchorScreenPos.y + anchorH / 2 - contentHeight / 2
    } else if (barPos === "right") {
      x = screenW - barW - contentWidth - gap
      y = anchorScreenPos.y + anchorH / 2 - contentHeight / 2
    } else { // "top"
      x = anchorScreenPos.x + anchorW / 2 - contentWidth / 2
      y = barH + gap
    }
    x = Math.max(margin, Math.min(x, screenW - contentWidth - margin))
    y = Math.max(margin, Math.min(y, screenH - contentHeight - margin))
    return Qt.point(Math.round(x), Math.round(y))
  }

  // --- lifecycle ------------------------------------------------------------

  onOpenChanged: {
    if (open) {
      focusPrimed = false
      beginFocusPrime()
      if (keyboardMode && focusTarget) Qt.callLater(function() {
        if (root.open && root.focusTarget) root.focusTarget.forceActiveFocus()
      })
    } else {
      focusPrimeTimer.stop()
      focusPrimed = false
    }

    // Take part in the bar's single-popout model so opening this panel closes
    // whatever other bar popup was up, and vice versa.
    if (!bar) return
    if (open) bar.requestPopout(coordinatorKey)
    else if (bar.activePopout === coordinatorKey) bar.releasePopout(coordinatorKey)
  }

  // Editing promotes a hover-opened panel to a keyboard one. Hyprland does not
  // hand focus to a surface that is already mapped just because it switched
  // from None to OnDemand, so the prime has to run again here.
  onKeyboardModeChanged: {
    if (!open || !keyboardMode) return
    focusPrimed = false
    beginFocusPrime()
    if (focusTarget) Qt.callLater(function() {
      if (root.open && root.keyboardMode && root.focusTarget) root.focusTarget.forceActiveFocus()
    })
  }

  Timer {
    id: focusPrimeTimer
    interval: 75
    onTriggered: if (root.open) root.focusPrimed = true
  }

  // --- card -----------------------------------------------------------------

  BorderSurface {
    id: card
    x: root.cardOrigin.x
    y: root.cardOrigin.y
    width: root.contentWidth
    height: root.contentHeight
    color: Qt.rgba(root.surfaceColor.r, root.surfaceColor.g, root.surfaceColor.b, root.surfaceOpacity)
    borderSpec: root.borderSpec
    padding: root.padding
    radius: Style.cornerRadius
    opacity: root.open ? 1.0 : 0

    Behavior on opacity {
      NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
    }

    HoverHandler {
      id: cardHover
    }

    // Swallow clicks that land on the card but not on a control, so they never
    // reach whatever is behind the panel.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
    }

    Item {
      id: contentHolder
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
    }
  }
}
