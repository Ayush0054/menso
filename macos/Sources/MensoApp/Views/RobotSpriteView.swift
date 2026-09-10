import SwiftUI
import MensoCore

struct RobotSpriteView: View {
    let state: RobotSpriteState
    let dimension: CGFloat
    var pendingCount = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: frameInterval)) { timeline in
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, size in
                context.withCGContext { graphics in
                    graphics.setShouldAntialias(false)
                    graphics.setAllowsAntialiasing(false)
                }
                drawRobot(in: &context, size: size, date: timeline.date)
            }
        }
        .frame(width: dimension, height: dimension)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var frameInterval: TimeInterval {
        switch state {
        case .running, .dictating, .voiceChat: 1 / 12
        case .waitingForPermission, .autoActing: 1 / 6
        case .idle, .error: 0.5
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .idle: "Menso is idle"
        case .running: "Menso is monitoring an active agent"
        case .waitingForPermission: "Menso is waiting for permission"
        case .error: "Menso needs attention"
        case .autoActing: "Menso is acting in auto mode"
        case .dictating: "Menso is dictating"
        case .voiceChat: "Menso voice chat is active"
        }
    }

    private func drawRobot(in context: inout GraphicsContext, size: CGSize, date: Date) {
        let unit = max(1, floor(min(size.width, size.height) / 16))
        let origin = CGPoint(
            x: floor((size.width - unit * 16) / 2),
            y: floor((size.height - unit * 16) / 2)
        )
        func rect(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> Path {
            Path(CGRect(
                x: origin.x + CGFloat(x) * unit,
                y: origin.y + CGFloat(y) * unit,
                width: CGFloat(width) * unit,
                height: CGFloat(height) * unit
            ))
        }
        func fill(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ color: Color) {
            context.fill(rect(x, y, width, height), with: .color(color))
        }

        let ink = Color(red: 0.08, green: 0.11, blue: 0.16)
        let shell = Color(red: 0.40, green: 0.91, blue: 0.75)
        let shellDark = Color(red: 0.18, green: 0.60, blue: 0.52)
        let eye = Color(red: 0.90, green: 1.00, blue: 0.83)
        let amber = Color(red: 1.00, green: 0.67, blue: 0.22)

        fill(4, 1, 8, 1, ink)
        fill(3, 2, 10, 2, shellDark)
        fill(2, 4, 12, 9, ink)
        fill(3, 5, 10, 7, shell)
        fill(4, 12, 2, 2, ink)
        fill(10, 12, 2, 2, ink)
        fill(1, 7, 1, 4, shellDark)
        fill(14, 7, 1, 4, shellDark)

        let tick = Int(date.timeIntervalSinceReferenceDate * 12)
        switch state {
        case .idle:
            let isBlinking = tick % 96 < 4
            fill(5, isBlinking ? 8 : 6, 2, isBlinking ? 1 : 3, ink)
            fill(9, isBlinking ? 8 : 6, 2, isBlinking ? 1 : 3, ink)
            fill(7, 10, 2, 1, shellDark)
        case .running:
            let scan = 6 + (tick / 2) % 3
            fill(4, scan, 8, 1, eye)
            fill(5, 10, 6, 1, shellDark)
        case .waitingForPermission:
            fill(5, 6, 2, 3, ink)
            fill(9, 6, 2, 3, ink)
            fill(7, 10, 2, 1, amber)
            let wave = (tick / 4) % 2
            fill(14, 4 + wave, 2, 2, amber)
        case .error:
            fill(4, 6, 1, 1, ink); fill(6, 8, 1, 1, ink)
            fill(6, 6, 1, 1, ink); fill(4, 8, 1, 1, ink)
            fill(9, 6, 1, 1, ink); fill(11, 8, 1, 1, ink)
            fill(11, 6, 1, 1, ink); fill(9, 8, 1, 1, ink)
            fill(6, 11, 4, 1, ink)
        case .autoActing:
            fill(4, 6, 8, 3, ink)
            fill(7, 7, 2, 1, shellDark)
            fill(6, 10, 4, 1, ink)
        case .dictating:
            fill(5, 6, 2, 2, ink)
            fill(9, 6, 2, 2, ink)
            let pulse = (tick / 2) % 3
            fill(5, 10 - pulse, 1, 1 + pulse, ink)
            fill(7, 9, 1, 3, ink)
            fill(9, 10 - pulse, 1, 1 + pulse, ink)
            fill(11, 10, 1, 1, ink)
        case .voiceChat:
            fill(5, 6, 2, 3, ink)
            fill(9, 6, 2, 3, ink)
            fill(2, 5, 2, 6, amber)
            fill(12, 5, 2, 6, amber)
            fill(5, 10, 6, 1, ink)
        }

        fill(12, 2, 2, 2, activityColor)
        if pendingCount > 0 {
            fill(0, 0, 4, 4, amber)
            fill(1, 1, 2, 2, ink)
        }
    }

    private var activityColor: Color {
        switch state {
        case .idle: .gray.opacity(0.7)
        case .running, .dictating, .voiceChat: .cyan
        case .waitingForPermission: .orange
        case .error: .red
        case .autoActing: .green
        }
    }
}
