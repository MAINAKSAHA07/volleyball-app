import SwiftUI

/// A simple two-thumb range slider for a bounded Double range.
struct RangeSlider: View {
    @Binding var lower: Double
    @Binding var upper: Double

    let bounds: ClosedRange<Double>
    let step: Double
    let minimumDistance: Double

    private let trackHeight: CGFloat = 6
    private let thumbSize: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width - thumbSize)
            let xLower = x(for: lower, width: w)
            let xUpper = x(for: upper, width: w)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.tertiarySystemFill))
                    .frame(height: trackHeight)
                    .padding(.horizontal, thumbSize / 2)

                Capsule()
                    .fill(Color.accentColor.opacity(0.65))
                    .frame(width: max(0, xUpper - xLower), height: trackHeight)
                    .offset(x: xLower + thumbSize / 2)
                    .padding(.vertical, 0)

                thumb(x: xLower, isLower: true, width: w)
                thumb(x: xUpper, isLower: false, width: w)
            }
            .frame(height: max(thumbSize, trackHeight))
        }
        .frame(height: 32)
    }

    private func thumb(x: CGFloat, isLower: Bool, width: CGFloat) -> some View {
        Circle()
            .fill(Color(.systemBackground))
            .overlay(
                Circle()
                    .stroke(Color.accentColor, lineWidth: 2)
            )
            .frame(width: thumbSize, height: thumbSize)
            .shadow(color: Color.black.opacity(0.12), radius: 2, x: 0, y: 1)
            .offset(x: x)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let v = valueToBoundedStep(x: value.location.x - thumbSize / 2, width: width)
                        if isLower {
                            lower = min(v, upper - minimumDistance)
                        } else {
                            upper = max(v, lower + minimumDistance)
                        }
                        clamp()
                    }
            )
            .accessibilityLabel(isLower ? "Lower bound" : "Upper bound")
            .accessibilityValue(Text(String(format: "%.2f", isLower ? lower : upper)))
    }

    private func clamp() {
        lower = min(max(lower, bounds.lowerBound), bounds.upperBound)
        upper = min(max(upper, bounds.lowerBound), bounds.upperBound)
        if upper - lower < minimumDistance {
            upper = min(bounds.upperBound, lower + minimumDistance)
        }
    }

    private func x(for value: Double, width: CGFloat) -> CGFloat {
        let t = (value - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound)
        return CGFloat(t) * width
    }

    private func valueToBoundedStep(x: CGFloat, width: CGFloat) -> Double {
        let t = min(1, max(0, Double(x / width)))
        let v = bounds.lowerBound + t * (bounds.upperBound - bounds.lowerBound)
        if step <= 0 { return v }
        let stepped = (v / step).rounded() * step
        return min(bounds.upperBound, max(bounds.lowerBound, stepped))
    }
}

