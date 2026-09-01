import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons

// Mission Control for Hyprland: four fingers up lifts every window of the
// current workspace off the desktop and lays them out in a grid, four fingers
// down puts them back.
//
// Nothing is moved. The windows keep their real geometry the whole time; what
// flies around is a live screencopy of each one, drawn on a layer above them
// over a scrim. That matters here because the layout is `scrolling` — a real
// "arrange into a grid, then restore" would trash the column state, and there
// is no way to ask Hyprland to put it back exactly.
//
// The shell's overlay contract is open(payload) / close() / `opened`, so
// `omarchy-shell shell toggle hooji.expose` works as well as the gesture.
Item {
  id: root

  // Injected by the shell on load.
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  // ------------------------------------------------------------------ state

  // 0 = desktop, 1 = full overview. Everything on screen is a function of it.
  property real progress: 0
  property bool dragging: false
  readonly property bool opened: progress > 0.5

  // The monitor the gesture belongs to. Focus follows the mouse here, so the
  // focused monitor is the one under the fingers.
  property string targetMonitor: ""
  // Snapshot taken when the gesture starts: [{ toplevel, x, y, w, h, address, title }]
  property var windows: []
  property int selectedIndex: 0

  // Swipe right moves the desktop right, the way content follows fingers on
  // macOS. Flip this if it feels backwards.
  property bool naturalWorkspaceSwipe: true

  // While the finger is down the overview tracks it exactly; the animation is
  // only for what happens after release.
  Behavior on progress {
    enabled: !root.dragging
    NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
  }

  // ---------------------------------------------------------------- helpers

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  function monitorOf(name) {
    var monitors = Hyprland.monitors.values
    for (var i = 0; i < monitors.length; i++)
      if (monitors[i].name === name) return monitors[i]
    return null
  }

  // Snapshot the windows of the active workspace on the gesture's monitor,
  // with their geometry in monitor-local logical pixels — the same coordinate
  // space the overlay window draws in.
  function snapshot() {
    var monitor = monitorOf(root.targetMonitor)
    if (!monitor || !monitor.activeWorkspace) { root.windows = []; return }

    var workspaceId = monitor.activeWorkspace.id
    var out = []
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var t = toplevels[i]
      if (!t.wayland || !t.workspace || t.workspace.id !== workspaceId) continue

      var ipc = t.lastIpcObject || {}
      var at = ipc.at || [monitor.x, monitor.y]
      var size = ipc.size || [monitor.width / monitor.scale, monitor.height / monitor.scale]
      if (!size[0] || !size[1]) continue

      out.push({
        toplevel: t,
        address: String(ipc.address || t.address || ""),
        title: String(t.title || ""),
        x: at[0] - monitor.x,
        y: at[1] - monitor.y,
        w: size[0],
        h: size[1]
      })
    }

    // Left to right, top to bottom, so the grid order matches what the eye
    // already learned from the desktop.
    out.sort(function(a, b) { return (a.y - b.y) || (a.x - b.x) })
    root.windows = out

    var active = Hyprland.activeToplevel
    root.selectedIndex = 0
    if (active) {
      for (var j = 0; j < out.length; j++)
        if (out[j].toplevel === active) { root.selectedIndex = j; break }
    }
  }

  readonly property int gridMargin: 48
  readonly property int gridGap: 24

  // sqrt(count) columns is the obvious choice and the wrong one on a wide
  // screen: three windows land in a 2x2 with a hole, at half the size a 3x1
  // would have given them. Try every column count, keep the roomiest — and
  // score it on the whole set, so every window agrees on one grid.
  function chooseColumns(count, panelWidth, panelHeight) {
    var columns = 1
    var best = -1
    for (var c = 1; c <= count; c++) {
      var candidateRows = Math.ceil(count / c)
      var candidateW = (panelWidth - 2 * gridMargin - (c - 1) * gridGap) / c
      var candidateH = (panelHeight - 2 * gridMargin - (candidateRows - 1) * gridGap) / candidateRows
      if (candidateW <= 0 || candidateH <= 0) continue
      var worst = 1
      for (var i = 0; i < root.windows.length; i++) {
        var other = root.windows[i]
        worst = Math.min(worst, candidateW / other.w, candidateH / other.h)
      }
      if (worst > best) { best = worst; columns = c }
    }
    return columns
  }

  // Arrow keys need the same grid the thumbnails are laid out on, and they are
  // handled outside any one panel — so derive it from the monitor rather than
  // from a panel's width.
  readonly property int columns: {
    var monitor = monitorOf(root.targetMonitor)
    if (!monitor || root.windows.length === 0) return 1
    return chooseColumns(root.windows.length, monitor.width / monitor.scale, monitor.height / monitor.scale)
  }

  // Where window `index` sits when the overview is fully open, inside a panel
  // of the given size. A plain grid for now; the cell keeps the window's
  // aspect ratio so nothing is stretched.
  function slot(index, count, panelWidth, panelHeight, win) {
    var margin = gridMargin
    var gap = gridGap
    // The panel reports 0x0 for a frame before layer-shell hands it a size.
    if (panelWidth <= 0 || panelHeight <= 0) return { x: win.x, y: win.y, w: win.w, h: win.h }

    var columns = chooseColumns(count, panelWidth, panelHeight)
    var rows = Math.ceil(count / columns)

    var cellW = (panelWidth - 2 * margin - (columns - 1) * gap) / columns
    var cellH = (panelHeight - 2 * margin - (rows - 1) * gap) / rows

    var column = index % columns
    var row = Math.floor(index / columns)

    var scale = Math.min(cellW / win.w, cellH / win.h, 1)
    var w = win.w * scale
    var h = win.h * scale

    return {
      x: margin + column * (cellW + gap) + (cellW - w) / 2,
      y: margin + row * (cellH + gap) + (cellH - h) / 2,
      w: w,
      h: h
    }
  }

  // Focusing has to happen *after* the overlay is out of the way. The panel
  // holds an exclusive keyboard grab while it is open; dispatching first means
  // Hyprland hands focus back to whatever was focused before the grab as the
  // grab drops, quietly undoing the pick. So: close, let the layer surface
  // release the keyboard, then focus.
  property string pendingAddress: ""

  function focusWindow(index) {
    var win = root.windows[index]
    root.hide()
    if (!win || !win.address) return
    root.pendingAddress = win.address.indexOf("0x") === 0 ? win.address : "0x" + win.address
    focusAfterClose.restart()
  }

  Timer {
    id: focusAfterClose
    // Just past the 200ms close animation, by which point keyboardFocus has
    // gone back to None and the grab is released.
    interval: 240
    onTriggered: {
      if (root.pendingAddress === "") return
      // Omarchy configures Hyprland in Lua, and that changes the dispatch
      // grammar: the classic "focuswindow address:0x..." string is rejected by
      // the Lua evaluator ("')' expected near 'address'"), silently doing
      // nothing. Dispatchers have to be written as Lua expressions.
      Hyprland.dispatch('hl.dsp.focus({ window = "address:' + root.pendingAddress + '" })')
      root.pendingAddress = ""
    }
  }

  // Grid-aware navigation. Horizontal is a plain step; vertical jumps a whole
  // row. The last row is usually ragged, so Down from a full row lands on the
  // final window instead of refusing to move — which is what the eye expects
  // when there is clearly something below and to the left.
  function moveSelection(dx, dy) {
    var last = root.windows.length - 1
    if (last < 0) return

    var index = root.selectedIndex
    if (dx !== 0) {
      root.selectedIndex = clamp(index + dx, 0, last)
      return
    }

    var target = index + dy * root.columns
    if (target >= 0 && target <= last) {
      root.selectedIndex = target
      return
    }

    var rows = Math.ceil(root.windows.length / root.columns)
    if (dy > 0 && Math.floor(index / root.columns) < rows - 1) root.selectedIndex = last
  }

  function reveal() {
    if (root.windows.length === 0) snapshot()
    // An empty workspace has nothing to expose; opening onto a bare scrim
    // would just be a dead end the user has to swipe back out of.
    if (root.windows.length === 0) { root.progress = 0; return }
    root.progress = 1
  }

  function hide() {
    root.progress = 0
  }

  function switchWorkspace(direction) {
    Hyprland.dispatch('hl.dsp.focus({ workspace = "' + (direction > 0 ? "e+1" : "e-1") + '" })')
  }

  // ------------------------------------------------------- shell contract

  function open(payload) {
    root.targetMonitor = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    Hyprland.refreshToplevels()
    snapshot()
    reveal()
  }

  function close() {
    hide()
  }

  // ---------------------------------------------------------- the gesture

  SwipeSource {
    id: swipe

    property real startProgress: 0
    property int startSelection: 0

    onBegan: {
      swipe.startProgress = root.progress
      swipe.startSelection = root.selectedIndex
      root.dragging = true
      if (root.progress < 0.01) {
        root.targetMonitor = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
        Hyprland.refreshToplevels()
        root.snapshot()
      }
    }

    onMoved: (dx, dy, axis) => {
      if (axis === "v") {
        // Up (negative dy) opens, down closes — the macOS direction.
        root.progress = root.clamp(swipe.startProgress + (-dy) / swipe.threshold, 0, 1)
      } else if (axis === "h" && swipe.startProgress > 0.5 && root.windows.length > 0) {
        // Open overview: horizontal walks the grid instead of the workspaces.
        var step = Math.round(dx / 140)
        root.selectedIndex = root.clamp(swipe.startSelection + step, 0, root.windows.length - 1)
      }
    }

    onEnded: (dx, dy, vx, vy, cancelled) => {
      root.dragging = false
      if (cancelled) { root.progress = swipe.startProgress > 0.5 ? 1 : 0; return }

      if (swipe.axis === "h" || (swipe.axis === "" && Math.abs(dx) > Math.abs(dy))) {
        // Horizontal while the overview is closed is a workspace switch. This
        // is a one-shot dispatch, not a rubber band: Hyprland's native swipe
        // cannot be enabled and disabled at runtime, so the plugin has to own
        // all four directions or fight the compositor over them.
        if (swipe.startProgress <= 0.5 && Math.abs(dx) > swipe.threshold * 0.5) {
          var direction = dx > 0 ? -1 : 1
          root.switchWorkspace(root.naturalWorkspaceSwipe ? direction : -direction)
        }
        root.progress = swipe.startProgress > 0.5 ? 1 : 0
        return
      }

      // A flick wins over position; otherwise the nearest end.
      if (vy < -400) root.progress = 1
      else if (vy > 400) root.progress = 0
      else root.progress = root.progress > 0.5 ? 1 : 0
    }
  }

  // ------------------------------------------------------------- the overlay

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      visible: root.progress > 0.001 && modelData.name === root.targetMonitor
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "hooji-expose"
      WlrLayershell.layer: WlrLayer.Overlay
      // Only take the keyboard once the overview has actually settled open —
      // grabbing it mid-swipe would eat keystrokes on a gesture that ends up
      // going nowhere.
      WlrLayershell.keyboardFocus: root.progress > 0.99 && !root.dragging
        ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.None

      Rectangle {
        anchors.fill: parent
        color: Color.background
        opacity: root.progress * 0.92
      }

      MouseArea {
        anchors.fill: parent
        // Live a little before the overview has fully settled: a click that
        // lands in the last frames of the open animation is still a click.
        enabled: root.progress > 0.5
        onClicked: root.hide()
      }

      FocusScope {
        id: keys
        anchors.fill: parent
        focus: true

        // A layer-shell surface can hold the keyboard while nothing inside it
        // has active focus, and then every key press is dropped on the floor.
        Connections {
          target: root
          function onProgressChanged() {
            if (root.progress > 0.99 && !root.dragging) keys.forceActiveFocus()
          }
        }

        Keys.onPressed: (event) => {
          if (event.key === Qt.Key_Escape) { root.hide(); event.accepted = true }
          else if (event.key === Qt.Key_Right || event.key === Qt.Key_Tab) {
            root.moveSelection(1, 0)
            event.accepted = true
          } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Backtab) {
            root.moveSelection(-1, 0)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.moveSelection(0, 1)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.moveSelection(0, -1)
            event.accepted = true
          } else if (event.key === Qt.Key_Home) {
            root.selectedIndex = 0
            event.accepted = true
          } else if (event.key === Qt.Key_End) {
            root.selectedIndex = Math.max(0, root.windows.length - 1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                     || event.key === Qt.Key_Space) {
            root.focusWindow(root.selectedIndex)
            event.accepted = true
          }
        }

        Repeater {
          model: root.windows

          Item {
            id: thumb
            required property int index
            required property var modelData

            readonly property var target: root.slot(index, root.windows.length, panel.width, panel.height, modelData)
            readonly property real p: root.progress
            readonly property bool selected: index === root.selectedIndex

            // The window lifts from exactly where it lives to its slot in the
            // grid; at p = 0 the thumbnail sits on top of the real window, so
            // the transition reads as the desktop itself folding up.
            x: modelData.x + (target.x - modelData.x) * p
            y: modelData.y + (target.y - modelData.y) * p
            width: modelData.w + (target.w - modelData.w) * p
            height: modelData.h + (target.h - modelData.h) * p

            ScreencopyView {
              anchors.fill: parent
              captureSource: thumb.modelData.toplevel ? thumb.modelData.toplevel.wayland : null
              // Live frames are what make it feel like the desktop rather than
              // a screenshot of it. If this ever costs too much with many
              // windows open, bind it to `root.progress > 0.99`.
              live: true
            }

            Rectangle {
              anchors.fill: parent
              color: "transparent"
              border.width: 2
              border.color: Color.accent
              radius: 6
              opacity: thumb.selected ? thumb.p : 0
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.top: parent.bottom
              anchors.topMargin: 6
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              text: thumb.modelData.title
              color: Color.foreground
              opacity: thumb.p
              font.family: Style.fontFamily
              font.pixelSize: 12
            }

            MouseArea {
              anchors.fill: parent
              enabled: root.progress > 0.5
              onClicked: root.focusWindow(thumb.index)
            }
          }
        }
      }
    }
  }
}
