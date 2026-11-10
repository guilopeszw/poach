import SwiftUI

struct ScreenshotFontSelection: View {
    let imageSize: CGSize
    let onSelect: (CGRect) -> Void
    @State private var selection: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / max(1, imageSize.width),
                            geometry.size.height / max(1, imageSize.height))
            let fit = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            Color.black.opacity(0.08)
                .overlay {
                    if let selection {
                        Rectangle()
                            .fill(.white.opacity(0.12))
                            .strokeBorder(.white, lineWidth: 2)
                            .frame(width: selection.width, height: selection.height)
                            .position(x: selection.midX, y: selection.midY)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: fit.width, height: fit.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { selection = crop(from: $0, in: fit) }
                    .onEnded { drag in
                        selection = nil
                        let crop = crop(from: drag, in: fit)
                        guard crop.width >= 6, crop.height >= 6 else { return }
                        onSelect(CGRect(x: crop.minX / fit.width, y: crop.minY / fit.height,
                                        width: crop.width / fit.width, height: crop.height / fit.height))
                    })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        }
    }

    private func crop(from drag: DragGesture.Value, in size: CGSize) -> CGRect {
        let rect = CGRect(x: min(drag.startLocation.x, drag.location.x),
                          y: min(drag.startLocation.y, drag.location.y),
                          width: abs(drag.translation.width), height: abs(drag.translation.height))
        return rect.intersection(CGRect(origin: .zero, size: size))
    }
}
