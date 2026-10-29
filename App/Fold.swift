import SwiftUI
import UIKit

/// Where the iPhone Duo's crease runs through a view, from UIKit's reserved regions (iOS 27.1).
/// The rect is in the view's own coordinates and includes the margins the system keeps clear around the fold.
/// nil on every other device, on the folded outer screen, and when the crease is outside the window (Split View).
struct FoldReader: UIViewRepresentable {
    @Binding var fold: CGRect?

    func makeUIView(context: Context) -> FoldProbeView {
        let v = FoldProbeView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ v: FoldProbeView, context: Context) {
        let binding = $fold
        v.onChange = { r in
            DispatchQueue.main.async { if binding.wrappedValue != r { binding.wrappedValue = r } }
        }
        v.report()
    }
}

final class FoldProbeView: UIView {
    /// Where the last fold came from ("reserved region", "estimated" or "none"); shown by -DuoDemoShowFold.
    static var lastSource = "none"
    var onChange: ((CGRect?) -> Void)?
    private var last: CGRect?? = .none

    override func layoutSubviews() {
        super.layoutSubviews()
        report()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        report()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        report()
    }

    func report() {
        let r = currentFold()
        if case .some(let prev) = last, prev == r { return }
        last = .some(r)
        onChange?(r)
    }

    private func currentFold() -> CGRect? {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return nil }
        #if DUO_SDK
        if #available(iOS 27.1, *) {
            let regions = reservedRegions(kind: .division, options: .includeInactive)
            if let f = regions.map(\.frame).first(where: { f in
                f.width > 0 && f.height > 0 && bounds.insetBy(dx: 1, dy: 1).intersects(f)
            }) {
                Self.lastSource = "reserved region"
                return f
            }
        }
        #endif
        let e = estimatedFold()
        Self.lastSource = e == nil ? "none" : "estimated"
        return e
    }

    /// Fallback when UIKit reports no division: on the iPhone Duo's inner screen (669 × 951 points, 951 × 669 held wide)
    /// the crease is a band about 40 points wide through the middle. Only used while the app fills the whole screen.
    private func estimatedFold() -> CGRect? {
        guard let window, let screen = window.windowScene?.screen else { return nil }
        if let size = DemoMode.fakeInnerSize {
            // -DuoDemoInner: an inner-screen-sized window centred in a bigger screen
            let w = window.bounds
            let fake = CGRect(x: (w.width - size.width) / 2, y: (w.height - size.height) / 2, width: size.width, height: size.height)
            let band = size.width > size.height
                ? CGRect(x: fake.midX - 20, y: fake.minY, width: 40, height: fake.height)
                : CGRect(x: fake.minX, y: fake.midY - 20, width: fake.width, height: 40)
            let r = convert(band, from: nil)
            return bounds.insetBy(dx: 1, dy: 1).intersects(r) ? r : nil
        }
        let s = screen.bounds.size
        let inner = CGSize(width: 669, height: 951)
        func near(_ a: CGSize, _ b: CGSize) -> Bool { abs(a.width - b.width) < 1.5 && abs(a.height - b.height) < 1.5 }
        guard near(s, inner) || near(s, CGSize(width: inner.height, height: inner.width)),
              near(window.bounds.size, s) else { return nil }
        let band = s.width > s.height
            ? CGRect(x: s.width / 2 - 20, y: 0, width: 40, height: s.height)
            : CGRect(x: 0, y: s.height / 2 - 20, width: s.width, height: 40)
        let r = convert(band, from: nil)
        return bounds.insetBy(dx: 1, dy: 1).intersects(r) ? r : nil
    }
}

/// -DuoDemoShowFold: outlines the fold the layout is using, for simulator screenshots.
struct FoldDebugOverlay: View {
    let fold: CGRect?
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let f = fold {
                Rectangle()
                    .stroke(Color.red, lineWidth: 2)
                    .background(Color.red.opacity(0.12))
                    .frame(width: f.width, height: f.height)
                    .offset(x: f.minX, y: f.minY)
            }
            Text("fold: \(FoldProbeView.lastSource) \(fold.map { "x \(Int($0.minX)) y \(Int($0.minY)) w \(Int($0.width)) h \(Int($0.height))" } ?? "") in \(Int(size.width))×\(Int(size.height))")
                .font(.caption2.monospaced())
                .padding(4)
                .background(.yellow.opacity(0.85))
                .offset(x: 4, y: size.height - 60)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}
