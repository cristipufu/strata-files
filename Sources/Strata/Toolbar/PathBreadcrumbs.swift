import AppKit

/// Fits complete parent steps around the current folder; an optional branch badge uses the space left over.
final class PathBreadcrumbs: NSView {
    struct Step {
        let button: CrumbButton
        var chevron: ChevronButton?
        var branch: GitBranchPill?

        var width: CGFloat { button.intrinsicContentSize.width + (chevron?.intrinsicContentSize.width ?? 0) }
        var branchWidth: CGFloat {
            guard let branch, branch.model != nil else { return 0 }
            return branch.intrinsicContentSize.width + PathBreadcrumbs.branchSpacing
                + (chevron == nil ? 0 : PathBreadcrumbs.branchSpacing)
        }
    }

    private static let minimumCurrentWidth: CGFloat = 96
    private static let branchSpacing: CGFloat = 2
    private var steps: [Step] = []
    private struct Fitting {
        let visible: Set<Int>
        let rootWidth: CGFloat
        let currentWidth: CGFloat
        let branch: Int?
    }

    var buttons: [CrumbButton] { steps.map(\.button) }

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 24) }

    func show(_ steps: [Step]) {
        subviews.forEach { $0.removeFromSuperview() }
        self.steps = steps
        for step in steps {
            addSubview(step.button)
            if let branch = step.branch { addSubview(branch) }
            if let chevron = step.chevron { addSubview(chevron) }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !steps.isEmpty else { return }
        let current = steps.count - 1
        let fitting = fit(current: current)
        var x: CGFloat = 0
        for (index, step) in steps.enumerated() {
            setVisible(fitting.visible.contains(index), view: step.button)
            setVisible(fitting.visible.contains(index), view: step.chevron)
            setVisible(fitting.branch == index, view: step.branch)
            guard fitting.visible.contains(index) else { continue }
            let width = if index == current { fitting.currentWidth }
                else if index == 0 { fitting.rootWidth }
                else { step.button.intrinsicContentSize.width }
            place(step.button, width: width, at: &x)
            if fitting.branch == index, let pill = step.branch {
                x += Self.branchSpacing
                place(pill, width: pill.intrinsicContentSize.width, at: &x)
                if step.chevron != nil { x += Self.branchSpacing }
            }
            if let chevron = step.chevron { place(chevron, width: chevron.intrinsicContentSize.width, at: &x) }
        }
    }

    private func fit(current: Int) -> Fitting {
        let available = max(0, bounds.width)
        var visible: Set<Int> = [current]
        var currentWidth = min(steps[current].width, available)
        var remaining = available - currentWidth
        let root = steps[0]
        var rootWidth = root.button.intrinsicContentSize.width
        let chevronWidth = root.chevron?.intrinsicContentSize.width ?? 0
        let roomForRoot = available - min(steps[current].width, Self.minimumCurrentWidth) - chevronWidth
        // A long account name can truncate while its icon, chevron and the current folder still fit.
        if root.button.cloud != nil, roomForRoot >= CrumbButton.minimumCloudWidth {
            rootWidth = min(rootWidth, roomForRoot)
        }
        if current > 0, rootWidth <= roomForRoot {
            visible.insert(0)
            currentWidth = min(steps[current].width, available - rootWidth - chevronWidth)
            remaining = available - rootWidth - chevronWidth - currentWidth
        }
        let parents = steps.indices.filter { !visible.contains($0) }.sorted {
            let leftRepository = steps[$0].branch != nil, rightRepository = steps[$1].branch != nil
            return leftRepository == rightRepository ? $0 > $1 : leftRepository
        }
        for index in parents where steps[index].width <= remaining {
            visible.insert(index)
            remaining -= steps[index].width
        }
        let branch = steps.indices.first {
            visible.contains($0) && steps[$0].branchWidth > 0 && steps[$0].branchWidth <= remaining
        }
        return Fitting(visible: visible, rootWidth: rootWidth, currentWidth: currentWidth, branch: branch)
    }

    private func place(_ view: NSView, width: CGFloat, at x: inout CGFloat) {
        let height = view.intrinsicContentSize.height
        view.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
        x += width
    }

    private func setVisible(_ visible: Bool, view: NSView?) {
        guard let view else { return }
        let hidden = !visible
        if view.isHidden != hidden { view.isHidden = hidden }
    }
}
