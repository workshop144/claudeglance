import AppKit

// MARK: - Dual-ring menu-bar gauge

/// Fraction (0...1) of a full ring to fill for a usage percentage. Clamps out-of
/// range input so a transient >100 or negative reading never draws past a full
/// circle. Pure — unit-tested.
func ringFillFraction(forPercent percent: Int) -> Double {
    Double(max(0, min(100, percent))) / 100.0
}

/// A compact two-ring usage gauge for the menu bar: the outer ring fills with the
/// 5-hour session usage, the inner ring with the 7-day weekly usage. Drawn as a
/// template image so it adapts to light/dark/tinted menu bars (the one colored
/// element stays the optional health dot, matching the app's neutral text).
///
/// `fiveHourPaceFraction` (0...1), when provided, draws a small pace marker on
/// the outer ring at the "time elapsed" position: when the 5h fill extends past
/// the marker you're burning faster than the clock (ahead of pace).
func menuBarRingImage(fiveHourPercent: Int, sevenDayPercent: Int,
                      fiveHourPaceFraction: Double? = nil) -> NSImage {
    let size: CGFloat = 18
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let center = NSPoint(x: size / 2, y: size / 2)
    let stroke: CGFloat = 2.0
    let gap: CGFloat = 1.5
    let outerRadius = size / 2 - stroke / 2 - 0.5
    let innerRadius = outerRadius - stroke - gap

    drawRing(center: center, radius: outerRadius, stroke: stroke, percent: fiveHourPercent)
    drawRing(center: center, radius: innerRadius, stroke: stroke, percent: sevenDayPercent)

    if let pace = fiveHourPaceFraction {
        drawPaceMarker(center: center, radius: outerRadius, stroke: stroke, fraction: pace)
    }

    image.unlockFocus()
    image.isTemplate = true
    return image
}

/// Erases a thin radial notch across the outer ring at the elapsed-time angle.
/// A gap (rather than an added mark) reads clearly exactly when it matters — when
/// the solid 5h fill has passed it (ahead of pace) the notch cuts visibly into it.
private func drawPaceMarker(center: NSPoint, radius: CGFloat, stroke: CGFloat, fraction: Double) {
    let frac = max(0, min(1, fraction))
    // Match the fill: clockwise from 12 o'clock (90°), in radians.
    let angle = (90 - frac * 360) * .pi / 180
    let r0 = radius - stroke / 2 - 0.5
    let r1 = radius + stroke / 2 + 0.5
    let notch = NSBezierPath()
    notch.move(to: NSPoint(x: center.x + cos(angle) * r0, y: center.y + sin(angle) * r0))
    notch.line(to: NSPoint(x: center.x + cos(angle) * r1, y: center.y + sin(angle) * r1))
    notch.lineWidth = 1.4
    notch.lineCapStyle = .round
    NSGraphicsContext.current?.compositingOperation = .clear
    NSColor.black.setStroke()
    notch.stroke()
    NSGraphicsContext.current?.compositingOperation = .sourceOver
}

/// Draws one ring: a faint full-circle track plus a solid arc that fills clockwise
/// from 12 o'clock in proportion to `percent`. Colors are black-with-alpha so the
/// template tint renders the track faint and the fill solid.
private func drawRing(center: NSPoint, radius: CGFloat, stroke: CGFloat, percent: Int) {
    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = stroke
    NSColor(white: 0, alpha: 0.28).setStroke()
    track.stroke()

    let fraction = ringFillFraction(forPercent: percent)
    guard fraction > 0 else { return }

    // AppKit angles are counter-clockwise from the +x axis; start at 90° (top) and
    // sweep clockwise so the gauge fills like a clock.
    let startAngle: CGFloat = 90
    let endAngle = startAngle - CGFloat(fraction) * 360
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius,
                  startAngle: startAngle, endAngle: endAngle, clockwise: true)
    arc.lineWidth = stroke
    arc.lineCapStyle = .round
    NSColor(white: 0, alpha: 1.0).setStroke()
    arc.stroke()
}

// MARK: - Signed-out menu-bar state

/// What the menu bar shows in place of usage when there's no live Claude session.
/// Without it, an expired session left the last numbers frozen (merely dimmed),
/// which read as "usage stalled" rather than "you need to sign in".
enum MenuBarAuthPrompt: Equatable {
    case signIn      // no session — the item invites a sign-in
    case signingIn   // browser flow in flight — the ring spins while we wait
}

/// Maps the auth state to a menu-bar prompt, or nil when usage should show. A
/// failed sign-in attempt only prompts if there's no stored session to fall back
/// on. Pure — unit-tested.
func menuBarAuthPrompt(for state: OAuthLoginService.AuthState,
                       hasCredentials: @autoclosure () -> Bool) -> MenuBarAuthPrompt? {
    switch state {
    case .signedIn:                       return nil
    case .awaitingBrowser, .awaitingCode: return .signingIn
    case .signedOut:                      return .signIn
    case .error:                          return hasCredentials() ? nil : .signIn
    }
}

/// The signed-out glyph: the gauge ring "locked" — a single ring around a keyhole,
/// so it stays recognizably ClaudeGlance while plainly asking for a sign-in.
/// With `spinnerPhase` (0...1) the ring becomes a faint track with a rotating arc,
/// the waiting-for-browser state. Template image, like the usage rings.
func menuBarSignInImage(spinnerPhase: Double? = nil) -> NSImage {
    let size: CGFloat = 18
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let center = NSPoint(x: size / 2, y: size / 2)
    let stroke: CGFloat = 1.6
    let radius = size / 2 - stroke / 2 - 0.5

    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = stroke
    if let phase = spinnerPhase {
        NSColor(white: 0, alpha: 0.28).setStroke()
        track.stroke()
        // A quarter-turn arc sweeping clockwise from 12 o'clock.
        let start = 90 - CGFloat(phase.truncatingRemainder(dividingBy: 1)) * 360
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius,
                      startAngle: start, endAngle: start - 100, clockwise: true)
        arc.lineWidth = stroke
        arc.lineCapStyle = .round
        NSColor(white: 0, alpha: 1.0).setStroke()
        arc.stroke()
    } else {
        NSColor(white: 0, alpha: 1.0).setStroke()
        track.stroke()
    }

    // Keyhole: a round head over a tapered slot, optically centered (nudged up).
    NSColor(white: 0, alpha: 1.0).setFill()
    let headY = center.y + 1.4
    NSBezierPath(ovalIn: NSRect(x: center.x - 2.0, y: headY - 2.0, width: 4.0, height: 4.0)).fill()
    let slot = NSBezierPath()
    slot.move(to: NSPoint(x: center.x - 0.8, y: headY))
    slot.line(to: NSPoint(x: center.x + 0.8, y: headY))
    slot.line(to: NSPoint(x: center.x + 1.4, y: center.y - 3.4))
    slot.line(to: NSPoint(x: center.x - 1.4, y: center.y - 3.4))
    slot.close()
    slot.fill()

    image.unlockFocus()
    image.isTemplate = true
    image.accessibilityDescription = spinnerPhase == nil ? "Sign in to Claude" : "Signing in to Claude"
    return image
}
