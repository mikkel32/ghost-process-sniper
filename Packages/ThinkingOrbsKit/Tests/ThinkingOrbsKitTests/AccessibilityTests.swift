#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ThinkingOrbsKit

@MainActor
/// VoiceOver sees one image element named per state; an outer
/// `.accessibilityLabel` renames it and `.accessibilityHidden` removes it
/// (the web `aria-label` / `aria-hidden`).
struct AccessibilityTests {
    func labels<V: View>(_ v: V) async -> [String] {
        let host = UIHostingController(rootView: v)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: 300_000_000)
        var out: [String] = []
        func walk(_ o: NSObject, _ depth: Int) {
            if depth > 8 { return }
            if o.isAccessibilityElement, let l = o.accessibilityLabel { out.append(l) }
            let n = o.accessibilityElementCount()
            if n != NSNotFound, n > 0 {
                for i in 0..<n { if let e = o.accessibilityElement(at: i) as? NSObject { walk(e, depth + 1) } }
            }
            if let els = o.accessibilityElements { for e in els { if let e = e as? NSObject { walk(e, depth + 1) } } }
            if let v = o as? UIView { for s in v.subviews { walk(s, depth + 1) } }
        }
        walk(host.view, 0)
        return out
    }

    @Test func labelsFollowTheWeb() async {
        #expect(await labels(ThinkingOrb(state: .breathing)) == ["Thinking…"])
        #expect(await labels(ThinkingOrb(state: .searching).accessibilityLabel("Searching the web")) == ["Searching the web"])
        #expect(await labels(ThinkingOrb(state: .searching).accessibilityHidden(true)).isEmpty)
    }
}
#endif
