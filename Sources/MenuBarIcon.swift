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
