import Accessibility
import UIKit
import XCTest

// 顔サイズ調整ツールの試験 target からも共有するため、CatRobot の型や import に依存させない。

/// 有効にした手段（診断用）。一度だけ有効にする。
@MainActor private var enabledAccessibilityRuntime: String?

/// fixture で実際の画面遷移を確かめるための補助。SwiftUI の部品を VoiceOver のダブルタップと同じ経路で探して押す。
@MainActor
extension XCTestCase {
    func allScrollViews(in view: UIView) -> [UIScrollView] {
        ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap { allScrollViews(in: $0) }
    }

    /// 2列の右側（詳細）のスクロール。標準文字では最も右にあるスクロールが詳細になる。
    func detailScrollView(in view: UIView) -> UIScrollView? {
        allScrollViews(in: view).max { $0.convert($0.bounds, to: view).minX < $1.convert($1.bounds, to: view).minX }
    }

    /// SwiftUI はアクセシビリティの実行環境が有効なときだけ要素の木を作る。AccessibilitySnapshot と同じく、
    /// テストのプロセスの中だけ libAccessibility で有効にする。画面を作る前に呼ぶ。
    @discardableResult
    func enableAccessibilityRuntime() async -> String {
        if let enabledAccessibilityRuntime { return enabledAccessibilityRuntime }
        typealias SetEnabled = @convention(c) (Bool) -> Void
        var used: [String] = []
        if let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW) {
            for name in ["_AXSApplicationAccessibilitySetEnabled", "_AXSSetAutomationEnabled"] {
                guard let symbol = dlsym(handle, name) else { continue }
                unsafeBitCast(symbol, to: SetEnabled.self)(true)
                used.append(name)
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        let result = used.isEmpty ? "unavailable" : used.joined(separator: "+")
        enabledAccessibilityRuntime = result
        return result
    }

    func accessibilityElement(in view: UIView, identifier: String) -> NSObject? {
        findAccessibilityElement(in: view, nearestView: view, depth: 0, where: Self.matching(identifier: identifier, label: nil))?.element
    }

    func accessibilityElement(in view: UIView, label: String) -> NSObject? {
        findAccessibilityElement(in: view, nearestView: view, depth: 0, where: Self.matching(identifier: nil, label: label))?.element
    }

    /// SwiftUI は描画の後で要素の木を作るので、識別子を持つ要素が現れるまで待つ（最大 timeout）。
    func waitForAccessibilityTree(in view: UIView, timeout: Duration = .seconds(2)) async throws {
        _ = try await waitUntil(timeout: timeout, settling: view) {
            findAccessibilityElement(in: view, nearestView: view, depth: 0) {
                (Self.identifier(of: $0) ?? "").isEmpty == false
            } != nil
        }
    }

    /// VoiceOver が届く要素を探す。描画を終わらせながら少し待ち、それでも無ければ scrollingIn を少しずつ送る
    /// （画面外のリストの行は作られていない）。scrollingIn は待った後に評価するので、切り替わった後の列を渡せる。
    /// 見つからなければ要素の木を AX_TREE として出力し、nil を返す。
    func reachableAccessibilityElement(in view: UIView, identifier: String? = nil, label: String? = nil,
                                       scrollingIn scroll: @autoclosure () -> UIScrollView? = nil,
                                       timeout: Duration = .seconds(2)) async throws -> (element: NSObject, view: UIView)? {
        let match = Self.matching(identifier: identifier, label: label)
        var found: (element: NSObject, view: UIView)?
        _ = try await waitUntil(timeout: timeout, settling: view) {
            found = findAccessibilityElement(in: view, nearestView: view, depth: 0, where: match)
            return found != nil
        }
        if found == nil, let scroll = scroll() {
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
            for _ in 0..<20 where found == nil {
                let bottom = max(-scroll.adjustedContentInset.top,
                                 scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                guard scroll.contentOffset.y < bottom - 0.5 else { break }
                scroll.setContentOffset(CGPoint(x: 0, y: min(bottom, scroll.contentOffset.y + scroll.bounds.height * 0.6)), animated: false)
                try await Task.sleep(for: .milliseconds(150))
                settleRendering(view)
                found = findAccessibilityElement(in: view, nearestView: view, depth: 0, where: match)
            }
        }
        if found == nil {
            print("AX_TREE for \(identifier ?? label ?? "") (runtime: \(enabledAccessibilityRuntime ?? "not enabled"))\n"
                  + accessibilityTreeDescription(of: view))
        }
        return found
    }

    /// 見つけた部品を押す。探し方は reachableAccessibilityElement と同じ。
    /// accessibilityActivate が働かない部品は、UIKit の操作部品の送信か、リストの行のセル選択に回す。
    func activateAccessibilityElement(in view: UIView, identifier: String? = nil, label: String? = nil,
                                      scrollingIn scroll: @autoclosure () -> UIScrollView? = nil,
                                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let name = identifier ?? label ?? ""
        guard let found = try await reachableAccessibilityElement(in: view, identifier: identifier, label: label,
                                                                  scrollingIn: scroll()) else {
            XCTFail("\(name) is not reachable through accessibility (runtime: \(enabledAccessibilityRuntime ?? "not enabled"))",
                    file: file, line: line)
            return
        }
        let activationBlock = found.element.responds(to: NSSelectorFromString("accessibilityActivateBlock"))
            ? found.element.accessibilityActivateBlock : nil
        if activationBlock?() ?? found.element.accessibilityActivate() { return }
        var ancestor: UIView? = found.view
        while let current = ancestor {
            if let control = current as? UIControl {
                // 同じ操作を二度送ると、切り替えや画面遷移が元に戻ることがあるので1種類だけ送る。
                control.sendActions(for: control.allControlEvents.contains(.primaryActionTriggered) ? .primaryActionTriggered : .touchUpInside)
                return
            }
            if let cell = current as? UICollectionViewCell {
                var container = cell.superview
                while let candidate = container, !(candidate is UICollectionView) { container = candidate.superview }
                let list = try XCTUnwrap(container as? UICollectionView, "\(name) has no list", file: file, line: line)
                let indexPath = try XCTUnwrap(list.indexPath(for: cell), "\(name) has no row", file: file, line: line)
                list.delegate?.collectionView?(list, didSelectItemAt: indexPath)
                return
            }
            ancestor = current.superview
        }
        XCTFail("\(name) could not be activated", file: file, line: line)
    }

    /// accessibilityFrame（画面座標）を view の座標へ直す。scene に載ったウィンドウは画面の座標空間から変換する。
    /// scene の無い fixture のウィンドウではその変換が CGRect.zero になるので、ウィンドウを画面の原点に置き、
    /// 画面座標をウィンドウ座標として扱う。
    func accessibilityFrame(of element: NSObject, in view: UIView,
                            file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        let window = try XCTUnwrap(view.window, "the view must be in a window", file: file, line: line)
        let frameBlock = element.responds(to: NSSelectorFromString("accessibilityFrameBlock")) ? element.accessibilityFrameBlock : nil
        let frame = frameBlock?() ?? element.accessibilityFrame
        XCTAssertFalse(frame.isEmpty, "\(type(of: element)) has no accessibility frame", file: file, line: line)
        if window.windowScene != nil { return view.convert(frame, from: window.screen.coordinateSpace) }
        XCTAssertEqual(window.frame.origin, .zero, "scene-less fixture windows sit at the screen origin", file: file, line: line)
        return view.convert(frame, from: window)
    }

    /// VoiceOver の「その他のコンテンツ」（AXCustomContent）を "ラベル=値" で返す。
    func accessibilityCustomContent(of element: NSObject) -> [String] {
        let content: [AXCustomContent]
        if element.responds(to: NSSelectorFromString("accessibilityCustomContentBlock")),
           let provider = element as? AXCustomContentProvider,
           let block = provider.accessibilityCustomContentBlock ?? nil {
            content = block() ?? []
        } else if element.responds(to: NSSelectorFromString("accessibilityCustomContent")) {
            content = element.value(forKey: "accessibilityCustomContent") as? [AXCustomContent] ?? []
        } else {
            content = []
        }
        return content.map { "\($0.label)=\($0.value)" }
    }

    func navigationController(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { self.navigationController(in: $0) }.first
    }

    /// 画面の切り替えや表示の完了を待つ。アニメーションの長さに依存しないよう、条件を満たすまで見る。
    /// settling を渡すと、見る前に毎回そのウィンドウの描画を終わらせる。
    func waitUntil(timeout: Duration = .seconds(3), settling view: UIView? = nil,
                   _ condition: () -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if let view { settleRendering(view) }
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        if let view { settleRendering(view) }
        return condition()
    }

    /// レイアウトを更新して、呼び出し元が選んだ対象を描く。
    /// 描画を挟まないと、SwiftUI のレイアウトやアクセシビリティの木が古いままのことがある。
    /// シーンに属さない fixture の window は描けないため、host または sheet の view を渡す。
    /// シーンに属する window 全体を撮る fixture では、その window を明示して渡す。
    @discardableResult
    func settleRendering(_ view: UIView) -> UIImage {
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }

    /// sRGB の RGBA8 画素と幅・高さ（画素の色を数える試験が共有する）。
    func rgbaPixels(of image: UIImage) -> ([UInt8], Int, Int)? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (pixels, width, height) : nil
    }

    /// 押し込み・戻りは要求した時点で viewControllers が変わり、表示の入れ替えはその後に起きる。
    /// 一番上の画面がウィンドウに載り、下の画面がウィンドウから外れるまで待つ。
    func waitForNavigation(_ navigation: UINavigationController, toShow count: Int, in view: UIView,
                           timeout: Duration = .seconds(3)) async throws -> Bool {
        try await waitUntil(timeout: timeout, settling: view) {
            guard navigation.viewControllers.count == count, navigation.transitionCoordinator == nil,
                  navigation.topViewController?.viewIfLoaded?.window != nil else { return false }
            return navigation.viewControllers.dropLast().allSatisfy { $0.viewIfLoaded?.window == nil }
        }
    }

    /// テストが作ったウィンドウを片付ける。隠すだけだと画面と状態が残り、後のウィンドウに影響することがある。
    func releaseWindow(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private static func matching(identifier: String?, label: String?) -> (NSObject) -> Bool {
        { object in
            if let identifier { return Self.identifier(of: object) == identifier }
            return Self.label(of: object) == label
        }
    }

    /// SwiftUI の要素は accessibilityIdentifier に応答しても UIAccessibilityIdentification に準拠していないことがあるので、KVC でも読む。
    private static func identifier(of object: NSObject) -> String? {
        if object.responds(to: NSSelectorFromString("accessibilityIdentifierBlock")),
           let block = object.accessibilityIdentifierBlock { return block() }
        if let identification = object as? UIAccessibilityIdentification { return identification.accessibilityIdentifier }
        guard object.responds(to: NSSelectorFromString("accessibilityIdentifier")) else { return nil }
        return object.value(forKey: "accessibilityIdentifier") as? String
    }

    private static func label(of object: NSObject) -> String? {
        if object.responds(to: NSSelectorFromString("accessibilityLabelBlock")),
           let block = object.accessibilityLabelBlock { return block() }
        return object.accessibilityLabel
    }

    private func accessibilityChildren(of object: NSObject) -> [NSObject] {
        var children: [NSObject] = []
        let elementsBlock = object.responds(to: NSSelectorFromString("accessibilityElementsBlock")) ? object.accessibilityElementsBlock : nil
        let suppliedElements = elementsBlock.map { $0() } ?? object.accessibilityElements
        if let elements = suppliedElements as? [NSObject], !elements.isEmpty {
            children = elements
        } else {
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                children = (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
            }
        }
        if let view = object as? UIView {
            children += view.subviews.filter { subview in !children.contains { $0 === subview } }
        }
        return children
    }

    private func findAccessibilityElement(in object: NSObject, nearestView: UIView, depth: Int,
                                          where match: (NSObject) -> Bool) -> (element: NSObject, view: UIView)? {
        guard depth < 64 else { return nil }
        let hiddenBlock = object.responds(to: NSSelectorFromString("accessibilityElementsHiddenBlock")) ? object.accessibilityElementsHiddenBlock : nil
        if hiddenBlock?() ?? (object.responds(to: NSSelectorFromString("accessibilityElementsHidden")) && object.accessibilityElementsHidden) { return nil }
        let view = object as? UIView
        // 画面から外れた view（押し込まれた下の画面など）は、要素の木に古く残っていても届かない。
        if let view, view.isHidden || view.alpha == 0 || view.window == nil { return nil }
        let nearest = view ?? nearestView
        if match(object) { return (object, nearest) }
        for child in accessibilityChildren(of: object) {
            if let found = findAccessibilityElement(in: child, nearestView: nearest, depth: depth + 1, where: match) {
                return found
            }
        }
        return nil
    }

    /// 見つからないときの手がかり。要素の型・識別子・ラベルを最大200行。
    private func accessibilityTreeDescription(of view: UIView) -> String {
        var lines: [String] = []
        func walk(_ object: NSObject, _ depth: Int) {
            guard depth < 40, lines.count < 200 else { return }
            if let view = object as? UIView, view.isHidden { return }
            let identifier = Self.identifier(of: object) ?? "-"
            let ownCount = object.accessibilityElementCount()
            lines.append("\(String(repeating: " ", count: depth))\(type(of: object)) id=\(identifier) label=\(Self.label(of: object) ?? "-") isElement=\(object.isAccessibilityElement) axChildren=\((object.accessibilityElements?.count).map(String.init) ?? "nil")/\(ownCount == NSNotFound ? -1 : ownCount)")
            for child in accessibilityChildren(of: object) { walk(child, depth + 1) }
        }
        walk(view, 0)
        return lines.joined(separator: "\n")
    }
}
