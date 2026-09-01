import QtQuick
import Quickshell.Io

// Four-finger swipes, read straight off libinput.
//
// Hyprland's own gesture API only fires once, at the end of a swipe: hl.gesture
// takes a one-shot action and returns nil, and no hl.on event carries swipe
// progress. An overview that follows the fingers needs the deltas as they
// happen, so this opens the touchpad a second time in parallel. libinput does
// not EVIOCGRAB in debug-events mode, so the compositor keeps receiving the
// same events untouched — this is a listener, not an interceptor.
//
// Reading /dev/input/event* needs group `input`, nothing more.
Item {
  id: root

  // Fingers we care about. Three-finger swipes stay with Hyprland (volume).
  property int fingers: 4
  // Unaccelerated travel, in libinput units, that counts as a full gesture.
  // Measured: a deliberate swipe lands around 160-290 on this touchpad.
  property real threshold: 220
  // Travel before the axis is locked, so a slightly diagonal swipe still
  // reads as purely vertical.
  property real axisLockDistance: 12

  readonly property bool active: swipe.active
  readonly property string axis: swipe.axis     // "", "h" or "v"
  readonly property real dx: swipe.dx           // accumulated, unaccelerated
  readonly property real dy: swipe.dy

  // dx/dy are cumulative for the whole gesture; vx/vy are units per second
  // over the tail of it, which is what separates a flick from a slow drag.
  signal began()
  signal moved(real dx, real dy, string axis)
  signal ended(real dx, real dy, real vx, real vy, bool cancelled)

  property string device: ""
  property string lastError: ""

  QtObject {
    id: swipe
    property bool active: false
    property string axis: ""
    property real dx: 0
    property real dy: 0
    property real t0: 0
    property real t: 0
    // Tail samples for the flick velocity: [time, dx, dy] triples.
    property var tail: []
  }

  function reset() {
    swipe.active = false
    swipe.axis = ""
    swipe.dx = 0
    swipe.dy = 0
    swipe.tail = []
  }

  function velocity() {
    var tail = swipe.tail
    if (tail.length < 2) return { vx: 0, vy: 0 }
    var first = tail[0]
    var last = tail[tail.length - 1]
    var dt = last[0] - first[0]
    if (dt <= 0) return { vx: 0, vy: 0 }
    return { vx: (last[1] - first[1]) / dt, vy: (last[2] - first[2]) / dt }
  }

  // libinput debug-events lines, e.g.
  //   event7 GESTURE_SWIPE_BEGIN     +21.269s  4
  //   event7 GESTURE_SWIPE_UPDATE  2 +21.281s  4  2.08/-6.14 ( 2.08/-6.14 unaccelerated)
  //   event7 GESTURE_SWIPE_END       +21.547s  4
  // The first UPDATE of a gesture has no sequence number, hence the optional
  // group. Deltas are taken unaccelerated: pointer acceleration is tuned for
  // a cursor, and would make the overview lurch on fast swipes.
  readonly property var beginRe: /GESTURE_SWIPE_BEGIN\s+\+([\d.]+)s\s+(\d+)/
  readonly property var updateRe: /GESTURE_SWIPE_UPDATE\s+(?:\d+\s+)?\+([\d.]+)s\s+(\d+)\s+(-?[\d.]+)\/\s*(-?[\d.]+)\s+\(\s*(-?[\d.]+)\/\s*(-?[\d.]+)\s+unaccelerated\)/
  readonly property var endRe: /GESTURE_SWIPE_END\s+\+([\d.]+)s\s+(\d+)(\s+cancelled)?/

  function handleLine(line) {
    if (line.indexOf("GESTURE_SWIPE") === -1) return

    var m = beginRe.exec(line)
    if (m) {
      if (parseInt(m[2]) !== root.fingers) return
      reset()
      swipe.active = true
      swipe.t0 = parseFloat(m[1])
      swipe.t = swipe.t0
      swipe.tail = [[swipe.t0, 0, 0]]
      root.began()
      return
    }

    m = updateRe.exec(line)
    if (m) {
      if (!swipe.active || parseInt(m[2]) !== root.fingers) return
      swipe.t = parseFloat(m[1])
      swipe.dx += parseFloat(m[5])
      swipe.dy += parseFloat(m[6])

      // Keep ~80ms of samples; enough to measure a flick, short enough that a
      // swipe that stalls at the end reads as stopped.
      var tail = swipe.tail.slice()
      tail.push([swipe.t, swipe.dx, swipe.dy])
      while (tail.length > 2 && swipe.t - tail[0][0] > 0.08) tail.shift()
      swipe.tail = tail

      if (swipe.axis === "") {
        var travel = Math.sqrt(swipe.dx * swipe.dx + swipe.dy * swipe.dy)
        if (travel >= root.axisLockDistance)
          swipe.axis = Math.abs(swipe.dx) > Math.abs(swipe.dy) ? "h" : "v"
      }

      root.moved(swipe.dx, swipe.dy, swipe.axis)
      return
    }

    m = endRe.exec(line)
    if (m) {
      if (!swipe.active || parseInt(m[2]) !== root.fingers) return
      var v = velocity()
      var cancelled = m[3] !== undefined
      var fdx = swipe.dx
      var fdy = swipe.dy
      reset()
      root.ended(fdx, fdy, v.vx, v.vy, cancelled)
    }
  }

  // Which event node is the touchpad is not stable across boots, so ask
  // libinput rather than hardcoding one.
  Process {
    id: findDevice
    running: true
    command: ["sh", "-c",
      "libinput list-devices | awk '/^Device:/{n=$0} /^Kernel:/{if (tolower(n) ~ /touchpad/) {print $2; exit}}'"]
    stdout: SplitParser {
      onRead: data => {
        var path = String(data).trim()
        if (path) root.device = path
      }
    }
    onExited: (code) => {
      if (!root.device) {
        root.lastError = "no touchpad found (libinput list-devices exit " + code + ")"
        console.warn("hooji.expose:", root.lastError)
      }
    }
  }

  // Started by hand rather than by binding `running` to the device. Bound
  // that way, `running` can flip before `command` has picked up the new path,
  // and libinput is handed an empty --device: it exits 1 with "Failed to
  // initialize device" and the overview is silently deaf to gestures.
  function startReader() {
    if (root.device === "" || reader.running) return
    reader.command = ["stdbuf", "-oL", "libinput", "debug-events", "--device", root.device]
    reader.running = true
  }

  onDeviceChanged: startReader()

  Process {
    id: reader
    stdout: SplitParser { onRead: data => root.handleLine(String(data)) }
    stderr: SplitParser {
      onRead: data => {
        var line = String(data).trim()
        if (line) root.lastError = line
      }
    }
    // If the reader dies (device unplugged, libinput upgraded underneath us)
    // the overview would silently stop responding. Come back after a beat.
    onExited: (code) => {
      if (code !== 0) console.warn("hooji.expose: libinput reader exited", code, root.lastError)
      root.reset()
      restart.start()
    }
  }

  Timer {
    id: restart
    interval: 2000
    onTriggered: root.startReader()
  }
}
