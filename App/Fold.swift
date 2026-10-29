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
        #if DUO_SDK
        if #available(iOS 27.1, *) {
            guard window != nil, bounds.width > 0, bounds.height > 0 else { return nil }
            let regions = reservedRegions(kind: .division, options: .includeInactive)
            return regions.map(\.frame).first { f in
                f.width > 0 && f.height > 0 && bounds.insetBy(dx: 1, dy: 1).intersects(f)
            }
        }
        #endif
        return nil
    }
}
