import SwiftUI
import UIKit
import ImageIO

/// Downscaled image loading for illustrations. The EPUB originals
/// are multi-megapixel files; decoding them at full size on every
/// page turn is what made the paged reader stutter (build 67
/// feedback). Thumbnails are decoded once via ImageIO and cached.
enum NovelImageCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(at url: URL, maxPixel: CGFloat) -> UIImage? {
        let key = (url.path + "#\(Int(maxPixel))") as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { return nil }
        let img = UIImage(cgImage: cg)
        cache.setObject(img, forKey: key)
        return img
    }
}

/// Live page position for the scrolling reader (build 69: the
/// bottom control bar was replaced by a small page indicator).
/// Pages are viewport-height slices of the (realized) content, so
/// totals grow as more of the book is laid out — they are live
/// estimates in scroll mode, exact in paged mode. Published values
/// change only when the page number does, keeping scrolling smooth.
final class NovelScrollMetrics: ObservableObject {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
    @Published var page = 1
    @Published var total = 1

    func update(viewport: CGFloat) {
        guard viewport > 0, contentHeight > 0 else { return }
        let t = max(1, Int(ceil(contentHeight / viewport)))
        let p = min(max(Int(offset / viewport) + 1, 1), t)
        if t != total { total = t }
        if p != page { page = p }
    }
}

// Direct UIScrollView tracking (KVO on contentOffset/contentSize).
// The PreferenceKey route never delivered values out of the lazy stack.
struct ScrollViewTracker: UIViewRepresentable {
    /// Optional drag-state feed (comic reader's pull-to-next-chapter);
    /// the novel reader leaves it nil. Declared before onChange so the
    /// trailing-closure call sites keep binding to onChange.
    var onDragging: ((Bool) -> Void)? = nil
    var onChange: (_ offset: CGFloat, _ contentHeight: CGFloat, _ viewport: CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        DispatchQueue.main.async { context.coordinator.attach(from: v) }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onDragging = onDragging
        if context.coordinator.scrollView == nil {
            DispatchQueue.main.async { context.coordinator.attach(from: uiView) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator {
        var onChange: (_ offset: CGFloat, _ contentHeight: CGFloat, _ viewport: CGFloat) -> Void
        var onDragging: ((Bool) -> Void)?
        weak var scrollView: UIScrollView?
        private var offsetObs: NSKeyValueObservation?
        private var sizeObs: NSKeyValueObservation?
        private var lastDragging: Bool?

        init(onChange: @escaping (_ offset: CGFloat, _ contentHeight: CGFloat, _ viewport: CGFloat) -> Void) {
            self.onChange = onChange
        }

        func attach(from view: UIView) {
            guard scrollView == nil else { return }
            var p = view.superview
            while let cur = p {
                if let sv = cur as? UIScrollView { bind(sv); return }
                p = cur.superview
            }
        }

        private func bind(_ sv: UIScrollView) {
            scrollView = sv
            offsetObs = sv.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
                self?.report(sv)
            }
            sizeObs = sv.observe(\.contentSize, options: [.new]) { [weak self] sv, _ in
                self?.report(sv)
            }
            report(sv)
        }

        private func report(_ sv: UIScrollView) {
            onChange(sv.contentOffset.y, sv.contentSize.height, sv.bounds.height)
            let d = sv.isDragging
            if d != lastDragging {
                lastDragging = d
                onDragging?(d)
            }
        }
    }
}

/// The small live page indicator shown instead of a control bar.
struct NovelPageBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

struct NovelScrollIndicator: View {
    @ObservedObject var metrics: NovelScrollMetrics

    var body: some View {
        NovelPageBadge(text: "\(metrics.page) / \(metrics.total)")
    }
}

/// An illustration block in the scrolling reader: loads its
/// downscaled image off the main thread, aspect-fit.
struct NovelBlockImage: View {
    let url: URL
    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.08))
                    .aspectRatio(1.4, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity)
        .task {
            let u = url
            image = await Task.detached(priority: .userInitiated) {
                NovelImageCache.image(at: u, maxPixel: 1242)
            }.value
        }
    }
}

// MARK: - paged novel layout (TextKit)
//
// The novel reader is paged (build 67): each chapter is laid out once
// into a stack of fixed-size text containers, one per page, and pages
// are shown with a UIPageViewController. Because every page view
// renders its container straight from the shared layout manager,
// line breaks, first-line indents and illustration placement are
// exactly the paginated ones — no re-layout surprises.

final class NovelChapterLayout {
    let storage: NSTextStorage
    let layoutManager: NSLayoutManager
    let containers: [NSTextContainer]
    let ranges: [NSRange]
    init(storage: NSTextStorage, layoutManager: NSLayoutManager,
         containers: [NSTextContainer], ranges: [NSRange]) {
        self.storage = storage
        self.layoutManager = layoutManager
        self.containers = containers
        self.ranges = ranges
    }
}

enum NovelPager {
    /// Chapter content as an attributed string: bold title, body
    /// paragraphs with a two-character first-line indent (printed
    /// novel style), illustrations as centered attachments fitted to
    /// the page.
    static func attributedString(chapter: NovelChapter, bookDir: URL,
                                 fontSize: CGFloat, imageMaxWidth: CGFloat,
                                 imageMaxHeight: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let bodyFont = UIFont.systemFont(ofSize: fontSize)
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineSpacing = 4
        titleStyle.paragraphSpacing = fontSize * 0.9
        out.append(NSAttributedString(string: chapter.title + "\n", attributes: [
            .font: UIFont.boldSystemFont(ofSize: fontSize + 5),
            .foregroundColor: UIColor.label,
            .paragraphStyle: titleStyle,
        ]))
        for block in chapter.contentBlocks {
            if block.kind == "image", let rel = block.file {
                let url = bookDir.appendingPathComponent(rel)
                guard let img = NovelImageCache.image(at: url, maxPixel: imageMaxWidth * 2)
                else { continue }
                let att = NSTextAttachment()
                att.image = img
                var w = min(imageMaxWidth, img.size.width)
                var h = img.size.width > 0 ? img.size.height * w / img.size.width : 0
                if h > imageMaxHeight {
                    h = imageMaxHeight
                    w = img.size.height > 0 ? img.size.width * h / img.size.height : w
                }
                att.bounds = CGRect(x: 0, y: 0, width: w, height: h)
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                style.paragraphSpacingBefore = fontSize * 0.4
                style.paragraphSpacing = fontSize * 0.4
                out.append(NSAttributedString(string: "\n", attributes: [
                    .font: bodyFont, .paragraphStyle: style,
                ]))
                let para = NSMutableAttributedString(attachment: att)
                para.addAttributes([.paragraphStyle: style],
                                   range: NSRange(location: 0, length: para.length))
                out.append(para)
                out.append(NSAttributedString(string: "\n", attributes: [
                    .font: bodyFont, .paragraphStyle: style,
                ]))
                continue
            }
            guard let text = block.text else { continue }
            for line in text.components(separatedBy: "\n") {
                let p = line.trimmingCharacters(in: .whitespaces)
                if p.isEmpty {
                    out.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
                    continue
                }
                let style = NSMutableParagraphStyle()
                style.lineSpacing = fontSize * 0.45
                style.paragraphSpacing = fontSize * 0.3
                style.firstLineHeadIndent = fontSize * 2
                out.append(NSAttributedString(string: p + "\n", attributes: [
                    .font: bodyFont,
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: style,
                ]))
            }
        }
        return out
    }

    static func build(chapter: NovelChapter, bookDir: URL,
                      fontSize: CGFloat, pageSize: CGSize) -> NovelChapterLayout {
        let attr = attributedString(chapter: chapter, bookDir: bookDir, fontSize: fontSize,
                                    imageMaxWidth: pageSize.width,
                                    imageMaxHeight: pageSize.height * 0.92)
        let storage = NSTextStorage(attributedString: attr)
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)
        var containers: [NSTextContainer] = []
        var ranges: [NSRange] = []
        var start = 0
        while start < attr.length {
            let c = NSTextContainer(size: pageSize)
            c.lineFragmentPadding = 0
            layout.addTextContainer(c)
            layout.ensureLayout(for: c)
            let cr = layout.characterRange(forGlyphRange: layout.glyphRange(for: c),
                                           actualGlyphRange: nil)
            if cr.length == 0 { break }
            containers.append(c)
            ranges.append(cr)
            start = cr.location + cr.length
        }
        if start < attr.length {
            // A glyph taller than a page (or any other layout stall):
            // give the remainder one tall container so no text is
            // ever unreachable.
            let c = NSTextContainer(size: CGSize(width: pageSize.width, height: 200_000))
            c.lineFragmentPadding = 0
            layout.addTextContainer(c)
            layout.ensureLayout(for: c)
            let cr = layout.characterRange(forGlyphRange: layout.glyphRange(for: c),
                                           actualGlyphRange: nil)
            if cr.length > 0 {
                containers.append(c)
                ranges.append(cr)
            }
        }
        if containers.isEmpty {
            let c = NSTextContainer(size: pageSize)
            c.lineFragmentPadding = 0
            layout.addTextContainer(c)
            containers.append(c)
            ranges.append(NSRange(location: 0, length: attr.length))
        }
        return NovelChapterLayout(storage: storage, layoutManager: layout,
                                  containers: containers, ranges: ranges)
    }

    static func buildAll(chapters: [NovelChapter], bookDir: URL,
                         fontSize: CGFloat, pageSize: CGSize)
        -> (layouts: [NovelChapterLayout], pages: [(chapter: Int, page: Int)], chapterStarts: [Int]) {
        var layouts: [NovelChapterLayout] = []
        var pages: [(chapter: Int, page: Int)] = []
        var starts: [Int] = []
        for (ci, ch) in chapters.enumerated() {
            let lay = build(chapter: ch, bookDir: bookDir, fontSize: fontSize, pageSize: pageSize)
            layouts.append(lay)
            starts.append(pages.count)
            for pi in lay.ranges.indices { pages.append((ci, pi)) }
        }
        return (layouts, pages, starts)
    }
}

// MARK: - one page

final class NovelPageVC: UIViewController {
    let pageIndex: Int
    private let textContainer: NSTextContainer

    init(pageIndex: Int, textContainer: NSTextContainer) {
        self.pageIndex = pageIndex
        self.textContainer = textContainer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let tv = UITextView(frame: .zero, textContainer: textContainer)
        tv.isEditable = false
        tv.isSelectable = false
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.contentInset = .zero
        view = tv
    }
}

// MARK: - page host (UIPageViewController)

/// Swipe left/right to turn pages; the page after a chapter's last
/// page is the next chapter's first page, so reading flows across
/// chapters. Tapping the left/right third of the page turns it too.
struct NovelPageHost: UIViewControllerRepresentable {
    let layouts: [NovelChapterLayout]
    let pages: [(chapter: Int, page: Int)]
    let generation: Int
    @Binding var current: Int
    var onCenterTap: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(transitionStyle: .scroll,
                                       navigationOrientation: .horizontal,
                                       options: nil)
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = .clear
        context.coordinator.parent = self
        context.coordinator.host = pvc
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        pvc.view.addGestureRecognizer(tap)
        context.coordinator.generation = generation
        context.coordinator.show(at: current, in: pvc, animated: false)
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        let co = context.coordinator
        co.parent = self
        if co.generation != generation {
            co.generation = generation
            co.show(at: current, in: pvc, animated: false)
        } else if co.shown != current {
            co.show(at: current, in: pvc, animated: true)
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: NovelPageHost?
        weak var host: UIPageViewController?
        var shown = -1
        var generation = -1

        func makePage(at index: Int) -> NovelPageVC? {
            guard let parent, index >= 0, index < parent.pages.count else { return nil }
            let item = parent.pages[index]
            guard parent.layouts.indices.contains(item.chapter) else { return nil }
            let layout = parent.layouts[item.chapter]
            guard item.page >= 0, item.page < layout.containers.count else { return nil }
            return NovelPageVC(pageIndex: index, textContainer: layout.containers[item.page])
        }

        func show(at index: Int, in pvc: UIPageViewController, animated: Bool) {
            guard let vc = makePage(at: index) else { return }
            let dir: UIPageViewController.NavigationDirection = index >= shown ? .forward : .reverse
            shown = index
            pvc.setViewControllers([vc], direction: dir, animated: animated)
        }

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let i = (vc as? NovelPageVC)?.pageIndex else { return nil }
            return makePage(at: i - 1)
        }

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let i = (vc as? NovelPageVC)?.pageIndex else { return nil }
            return makePage(at: i + 1)
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            if completed, let vc = pvc.viewControllers?.first as? NovelPageVC {
                shown = vc.pageIndex
                parent?.current = vc.pageIndex
            }
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let view = host?.view else { return }
            let x = g.location(in: view).x
            let w = view.bounds.width
            if x < w * 0.32 { step(-1) }
            else if x > w * 0.68 { step(1) }
            else { parent?.onCenterTap() }
        }

        private func step(_ delta: Int) {
            guard let host, shown >= 0 else { return }
            let target = shown + delta
            guard target >= 0, let parent, target < parent.pages.count else { return }
            show(at: target, in: host, animated: true)
            parent.current = target
        }
    }
}
