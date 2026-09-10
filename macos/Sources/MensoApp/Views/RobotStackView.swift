import AppKit
import MensoCore
import SwiftUI

struct RobotStackView: View {
    let faces: [AgentFace]
    let dimension: CGFloat
    let pendingCount: Int
    let onClick: @MainActor () -> Void
    let onContextMenu: @MainActor (NSEvent) -> Void

    private var visibleFaces: [AgentFace] {
        Array(faces.prefix(4))
    }

    private var stackHeight: CGFloat {
        let count = CGFloat(max(visibleFaces.count, 1))
        return dimension * count - dimension * 0.22 * max(0, count - 1)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: -dimension * 0.22) {
                ForEach(Array(visibleFaces.enumerated()), id: \.element.id) { index, face in
                    RobotSpriteView(
                        state: face.state,
                        dimension: dimension,
                        pendingCount: index == 0 ? pendingCount : 0
                    )
                    .zIndex(Double(visibleFaces.count - index))
                    .help(face.name)
                }
            }
            if faces.count > 4 {
                Text("+\(faces.count - 4)")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.78), in: Capsule())
                    .offset(x: -2, y: 2)
                    .accessibilityLabel("\(faces.count - 4) more active agents")
            }
            PanelDragSurface(onClick: onClick, onContextMenu: onContextMenu)
        }
        .frame(width: dimension, height: stackHeight)
        .contentShape(Rectangle())
    }
}
