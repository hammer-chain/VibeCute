import AppKit
#if canImport(CaptionCore)
import CaptionCore
#endif

/// The caption's existing surface and tail surround a compact request card.
/// Native controls are retained across caption ticks; only request/width changes rebuild content.
final class QuestionReplyView: NSView {
    private(set) var drawCount = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    weak var bubbleRenderer: SubtitleView?
    var controlsOpacity: CGFloat = 1 {
        didSet { if controlsOpacity != oldValue { subviews.forEach { $0.alphaValue = controlsOpacity } } }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        controlsOpacity < 0.95 ? nil : super.hitTest(point)
    }
    private var request: UserQuestionRequest?
    private var page = 0
    private var answers: [String: String] = [:]
    private var selections: [String: Int] = [:]
    private var submitting = false
    private var uncertain = false
    private var generation = UUID()
    private var onSubmit: (([String: String], @escaping (Result<Void, Error>) -> Void) -> Void)?
    private var onOpenConversation: (() -> String?)?
    private var onClose: (() -> Void)?
    private let heading = NSTextField(labelWithString: "")
    private let context = NSTextField(labelWithString: "")
    private let document = FlippedQuestionContent()
    private let scroll = NSScrollView()
    private let previous = BubbleReplyButton(title: "‹", target: nil, action: nil)
    private let next = BubbleReplyButton(title: "›", target: nil, action: nil)
    private let submit = BubbleReplyButton(title: "发送回复", target: nil, action: nil)
    private let ownReply = BubbleReplyButton(title: "我要自己回复", target: nil, action: nil)
    private let deny = BubbleReplyButton(title: "拒绝", target: nil, action: nil)
    private let allow = BubbleReplyButton(title: "允许一次", target: nil, action: nil)
    private let scope = BubbleReplyButton(title: "⌄", target: nil, action: nil)
    private let close = BubbleReplyButton(title: "×", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private var choiceButtons: [NSButton] = []
    var fixedContentWidth: CGFloat = 0 {
        didSet { if abs(fixedContentWidth - oldValue) > 0.5 { needsLayout = true } }
    }
    private var contentWidth: CGFloat = 0
    private var repliesInCodex: Bool {
        guard let request, !request.approval, request.questions.indices.contains(page) else { return false }
        return request.questions[page].options.isEmpty
    }

    init() {
        super.init(frame: .zero)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.textColor = .white.withAlphaComponent(0.96)
        heading.lineBreakMode = .byTruncatingMiddle
        context.font = .systemFont(ofSize: 11, weight: .medium)
        context.textColor = .white.withAlphaComponent(0.6)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay; scroll.documentView = document
        status.font = .systemFont(ofSize: 10)
        status.textColor = .white.withAlphaComponent(0.66)
        for button in [previous, next, submit, ownReply, deny, allow, scope, close] {
            button.bezelStyle = .rounded; button.target = self
        }
        submit.isPrimary = true; allow.isPrimary = true; scope.isPrimary = true
        ownReply.action = #selector(openConversation)
        deny.action = #selector(denyApproval); allow.action = #selector(allowApproval)
        scope.action = #selector(showApprovalScopes); scope.setAccessibilityLabel("审批选项")
        previous.action = #selector(previousPage); next.action = #selector(nextPage)
        previous.setAccessibilityLabel("上一题"); next.setAccessibilityLabel("下一题")
        submit.action = #selector(sendReply)
        close.action = #selector(closeBubble)
        close.identifier = NSUserInterfaceItemIdentifier("close-request-bubble")
        close.setAccessibilityLabel("关闭气泡")
        close.toolTip = "关闭此气泡；仍可在 Codex 中处理请求"
        close.font = .systemFont(ofSize: 18, weight: .regular)
        [heading, context, scroll, previous, next, submit, ownReply, deny, allow, scope, close, status].forEach(addSubview)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        guard let bubbleRenderer else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: bounds.height)
        NSGraphicsContext.current?.cgContext.scaleBy(x: 1, y: -1)
        bubbleRenderer.drawBubbleSurface(in: bubbleRenderer.bubbleFrame, opaque: true)
        NSGraphicsContext.restoreGraphicsState()
    }

    func configure(_ request: UserQuestionRequest, title: String,
                   onOpenConversation: (() -> String?)? = nil,
                   onClose: (() -> Void)? = nil,
                   onSubmit: @escaping ([String: String], @escaping (Result<Void, Error>) -> Void) -> Void) {
        self.onSubmit = onSubmit; self.onOpenConversation = onOpenConversation; self.onClose = onClose
        heading.stringValue = title.isEmpty ? "Codex 对话" : title
        guard self.request != request else { updateControls(); return }
        self.request = request; page = 0; answers = [:]; selections = [:]
        submitting = false; uncertain = false; generation = UUID(); status.stringValue = ""
        setAccessibilityLabel((request.approval ? "Codex 权限审批 · " : "Codex 提问 · ") + title)
        contentWidth = 0; rebuildPage(); needsLayout = true
        // Focus is opt-in for the isolated native fixture, never for a real request.
        if CommandLine.arguments.contains("--question-focus-fixture") {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.window?.makeKeyAndOrderFront(nil); self.window?.makeFirstResponder(self)
            }
        }
    }
    /// Reuse the request/page measurement; animated window dimensions do not
    /// rewrap text or reconstruct option controls on every frame.
    func prepare(width: CGFloat) -> CGFloat {
        let content = width - 52
        if abs(fixedContentWidth - content) > 0.5 {
            fixedContentWidth = content; rebuildPage()
        }
        return 170 + min(146, max(24, document.frame.height))
    }
    override func layout() {
        super.layout()
        let inset: CGFloat = 26, width = bounds.width - inset * 2, height = bounds.height
        heading.frame = NSRect(x: inset, y: 23, width: width - 34, height: 20)
        close.frame = NSRect(x: bounds.width - inset - 26, y: 20, width: 26, height: 26)
        context.frame = NSRect(x: inset, y: 47, width: width - 68, height: 16)
        previous.frame = NSRect(x: bounds.width - inset - 54, y: 45, width: 24, height: 22)
        next.frame = NSRect(x: bounds.width - inset - 24, y: 45, width: 24, height: 22)
        let viewportHeight = min(document.frame.height, max(24, height - 170))
        scroll.frame = NSRect(x: inset, y: 76, width: width, height: viewportHeight)
        let footerY = scroll.frame.maxY + 8, approval = request?.approval == true
        let options = request?.questions.first?.options ?? []
        let primary = options.first == "允许本次" || options.first == "允许本轮"
        let three = approval && primary
        let gap: CGFloat = width < 280 ? 6 : 8
        let ownWidth: CGFloat = repliesInCodex ? min(width, 128) : (width < 280 ? 88 : 104)
        let firstWidth: CGFloat = approval ? (width < 280 ? 50 : 60) : 84
        let primaryWidth: CGFloat = width < 280 ? 78 : 100
        let buttonHeight: CGFloat = 28
        submit.frame = NSRect(x: inset, y: footerY, width: firstWidth, height: buttonHeight)
        deny.frame = submit.frame
        let hasScopes = approval && options.count > 2
        allow.frame = NSRect(x: inset + firstWidth + gap, y: footerY,
                             width: primaryWidth - (hasScopes ? 22 : 0), height: buttonHeight)
        scope.frame = NSRect(x: allow.frame.maxX + 1, y: footerY, width: 21, height: buttonHeight)
        ownReply.frame = NSRect(x: repliesInCodex ? inset : (three ? inset + firstWidth + gap + primaryWidth + gap : inset + firstWidth + gap),
                               y: footerY, width: ownWidth, height: buttonHeight)
        status.frame = NSRect(x: inset, y: footerY + buttonHeight + 6, width: width, height: 20)
        for button in [previous, next, submit, ownReply, deny, allow, scope, close] {
            button.accentHue = bubbleRenderer?.themeHue ?? 0.57
        }
        if abs(contentWidth - (fixedContentWidth > 0 ? fixedContentWidth : scroll.contentSize.width)) > 0.5 { rebuildPage() }
    }
    private func rebuildPage() {
        guard let request, page < request.questions.count else { return }
        let question = request.questions[page]
        document.subviews.forEach { $0.removeFromSuperview() }; choiceButtons = []
        let width = max(180, fixedContentWidth > 0 ? fixedContentWidth : scroll.contentSize.width); contentWidth = width
        var top: CGFloat = 0
        let content = FlippedQuestionContent()
        func label(_ text: String, font: NSFont, opacity: CGFloat = 0.94) {
            guard !text.isEmpty else { return }
            let view = NSTextField(wrappingLabelWithString: text)
            view.font = font; view.textColor = .white.withAlphaComponent(opacity)
            let height = ceil((text as NSString).boundingRect(with: NSSize(width: width - 4, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height) + 4
            view.frame = NSRect(x: 0, y: top, width: width - 4, height: height)
            content.addSubview(view); top += height + 8
        }
        func description(_ text: String, font: NSFont) {
            guard !text.isEmpty else { return }
            let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = lineHeight; paragraph.maximumLineHeight = lineHeight
            let value = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph,
                .foregroundColor: NSColor.white.withAlphaComponent(0.94)])
            let textHeight = ceil(value.boundingRect(with: NSSize(width: width - 6, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 2
            let viewportHeight = min(lineHeight * 3, textHeight)
            let viewport = NSScrollView(frame: NSRect(x: 0, y: top, width: width, height: viewportHeight))
            viewport.identifier = NSUserInterfaceItemIdentifier("request-description")
            viewport.setAccessibilityLabel(request.approval ? "审批说明" : "问题描述")
            viewport.drawsBackground = false; viewport.hasVerticalScroller = textHeight > viewportHeight
            viewport.scrollerStyle = .overlay
            let wrapper = FlippedQuestionContent(frame: NSRect(x: 0, y: 0, width: width, height: textHeight))
            let field = NSTextField(wrappingLabelWithString: "")
            field.attributedStringValue = value; field.isSelectable = true
            field.frame = NSRect(x: 0, y: 0, width: width - 6, height: textHeight)
            wrapper.addSubview(field); viewport.documentView = wrapper
            content.addSubview(viewport); top += viewportHeight + 8
        }
        if request.approval, let presentation = request.approvalContent {
            label(presentation.title, font: .systemFont(ofSize: 12, weight: .semibold), opacity: 0.66)
            description(presentation.reason, font: .systemFont(ofSize: 14))
            if !presentation.details.isEmpty {
                let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                let attributed = NSMutableAttributedString(string: "")
                let lines = presentation.details.components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    let color: NSColor = line.hasPrefix("+") ? NSColor(calibratedRed: 0.65, green: 0.91, blue: 0.74, alpha: 1)
                        : line.hasPrefix("-") ? NSColor(calibratedRed: 1, green: 0.72, blue: 0.76, alpha: 1)
                        : .white.withAlphaComponent(0.82)
                    attributed.append(NSAttributedString(string: line + (index == lines.count - 1 ? "" : "\n"),
                        attributes: [.font: font, .foregroundColor: color]))
                }
                let text = NSTextField(wrappingLabelWithString: "")
                text.attributedStringValue = attributed; text.isSelectable = true
                let textHeight = ceil(attributed.boundingRect(with: NSSize(width: width - 24, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 4
                let block = RequestDetailBlock(frame: NSRect(x: 0, y: top, width: width, height: textHeight + 20))
                text.frame = NSRect(x: 10, y: 10, width: width - 24, height: textHeight)
                block.addSubview(text); content.addSubview(block); top += block.frame.height + 8
            }
        } else {
            description(question.title, font: .systemFont(ofSize: 15, weight: .medium))
            for (index, option) in question.options.enumerated() {
                let button = BubbleReplyButton(title: option, target: self, action: #selector(selectChoice(_:)))
                button.isChoice = true; button.subtitle = question.descriptions[index]
                button.accentHue = bubbleRenderer?.themeHue ?? 0.57
                button.setButtonType(.radio); button.tag = index; button.font = .systemFont(ofSize: 13, weight: .medium)
                let textWidth = width - 50
                let titleHeight = ceil((option as NSString).boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: button.font!]).height)
                let detailHeight = button.subtitle.isEmpty ? 0 : ceil((button.subtitle as NSString).boundingRect(
                    with: NSSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: NSFont.systemFont(ofSize: 11)]).height) + 4
                button.frame = NSRect(x: 0, y: top, width: width, height: max(38, titleHeight + detailHeight + 18))
                button.state = selections[question.id] == index ? .on : .off
                content.addSubview(button); choiceButtons.append(button); top += button.frame.height + 8
            }
        }
        content.frame = NSRect(x: 0, y: 0, width: width, height: max(0, top - 8))
        document.frame = content.frame; document.addSubview(content)
        scroll.contentView.scroll(to: .zero); updateControls(); needsLayout = true
    }
    private func updateControls() {
        close.isEnabled = onClose != nil
        let approval = request?.approval == true
        let count = request?.questions.count ?? 0
        context.stringValue = "Codex · " + (approval ? "等待审批" : "等待回复") + (count > 1 ? "  ·  \(page + 1)/\(count)" : "")
        previous.isHidden = approval || count <= 1; next.isHidden = previous.isHidden
        previous.isEnabled = page > 0 && !submitting && !uncertain
        next.isEnabled = page + 1 < count && !submitting && !uncertain
        submit.isHidden = approval || repliesInCodex; deny.isHidden = !approval
        ownReply.title = repliesInCodex ? "去Codex里回复" : "我要自己回复"
        let options = request?.questions.first?.options ?? []
        let primary = options.first == "允许本次" || options.first == "允许本轮"
        allow.isHidden = !approval || !primary; scope.isHidden = !approval || options.count <= 2
        allow.title = options.first == "允许本轮" ? "允许本轮" : "允许一次"
        allow.toolTip = request?.questions.first?.descriptions.first
        deny.isEnabled = !submitting && !uncertain; allow.isEnabled = deny.isEnabled; scope.isEnabled = deny.isEnabled
        submit.isEnabled = !submitting && !uncertain && request?.questions.allSatisfy { answers[$0.id] != nil } == true
        ownReply.isEnabled = onOpenConversation != nil && !submitting
        choiceButtons.forEach { $0.isEnabled = !submitting && !uncertain }
    }
    @objc private func closeBubble() { onClose?() }
    @objc private func openConversation() {
        guard !submitting, let onOpenConversation else { return }
        status.stringValue = onOpenConversation() ?? "已打开 Codex 对话"
    }
    private func approvalChoice(_ index: Int) {
        guard let request, request.approval, !submitting, !uncertain,
              request.questions[0].options.indices.contains(index) else { return }
        answers[request.questions[0].id] = request.questions[0].options[index]; sendReply()
    }
    @objc private func allowApproval() { approvalChoice(0) }
    @objc private func denyApproval() {
        guard let options = request?.questions.first?.options, let index = options.firstIndex(of: "拒绝") else { return }
        approvalChoice(index)
    }
    @objc private func showApprovalScopes() {
        guard let request, request.approval, !submitting, !uncertain else { return }
        let menu = NSMenu()
        for (index, title) in request.questions[0].options.enumerated() where title != "拒绝" {
            let item = NSMenuItem(title: index == 0 ? allow.title : title, action: #selector(approvalScope(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.representedObject = generation.uuidString
            item.toolTip = request.questions[0].descriptions[index]; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: scope.bounds.height + 3), in: scope)
    }
    @objc private func approvalScope(_ item: NSMenuItem) {
        guard item.representedObject as? String == generation.uuidString else { return }; approvalChoice(item.tag)
    }
    @objc private func selectChoice(_ button: NSButton) {
        guard let question = request?.questions[page], !submitting, !uncertain else { return }
        selections[question.id] = button.tag; answers[question.id] = question.options[button.tag]
        choiceButtons.forEach { $0.state = $0 === button ? .on : .off }
        status.stringValue = ""; updateControls()
    }
    @objc private func previousPage() { guard page > 0 else { return }; page -= 1; rebuildPage() }
    @objc private func nextPage() { guard page + 1 < (request?.questions.count ?? 0) else { return }; page += 1; rebuildPage() }
    @objc private func sendReply() {
        guard let request, !submitting, !uncertain else { return }
        if let index = request.questions.firstIndex(where: { (answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            page = index; rebuildPage(); status.stringValue = "请先选择选项，或到 Codex 自己回复。"; return
        }
        submitting = true; status.stringValue = "正在提交…"; updateControls()
        let currentGeneration = generation
        onSubmit?(answers) { [weak self] result in
            guard let self, self.generation == currentGeneration else { return }
            self.submitting = false
            switch result {
            case .success: self.status.stringValue = "已发送"; self.uncertain = true
            case let .failure(error):
                self.status.stringValue = error.localizedDescription
                if let error = error as? QuestionReplyError, case .uncertain = error { self.uncertain = true }
            }
            self.updateControls()
        }
    }
}

private final class FlippedQuestionContent: NSView { override var isFlipped: Bool { true } }
private final class RequestDetailBlock: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        NSColor.black.withAlphaComponent(0.08).setFill(); path.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke(); path.lineWidth = 0.6; path.stroke()
    }
}

/// Light, rounded controls use the current bubble hue rather than a foreign theme.
final class BubbleReplyButton: NSButton {
    var isChoice = false
    var isPrimary = false
    var subtitle = ""
    var accentHue: CGFloat = 0.57
    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.7, dy: 0.7)
        let path = NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7)
        let alpha: CGFloat = isEnabled ? 1 : 0.4
        if isPrimary {
            NSColor(calibratedHue: accentHue, saturation: 0.16,
                    brightness: isEnabled ? (isHighlighted ? 0.90 : 0.98) : 0.62, alpha: 1).setFill()
        } else {
            NSColor(calibratedHue: accentHue, saturation: state == .on ? 0.32 : 0.42,
                    brightness: isEnabled ? (state == .on || isHighlighted ? 0.43 : 0.32) : 0.27, alpha: 1).setFill()
        }
        path.fill()
        NSColor.white.withAlphaComponent((isPrimary ? 0.1 : state == .on ? 0.62 : 0.18) * alpha).setStroke()
        path.lineWidth = 0.7; path.stroke()
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = isChoice ? .left : .center
        paragraph.lineBreakMode = .byWordWrapping
        let foreground = isPrimary ? NSColor(calibratedHue: accentHue, saturation: 0.52, brightness: 0.27, alpha: alpha)
            : NSColor.white.withAlphaComponent(0.94 * alpha)
        let text = NSMutableAttributedString(string: title, attributes: [.font: font ?? NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: foreground, .paragraphStyle: paragraph])
        if isChoice && !subtitle.isEmpty {
            text.append(NSAttributedString(string: "\n" + subtitle, attributes: [.font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.white.withAlphaComponent(0.6 * alpha), .paragraphStyle: paragraph]))
        }
        let textX = box.minX + (isChoice ? 36 : 6), textWidth = box.width - (isChoice ? 48 : 12)
        let height = ceil(text.boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        text.draw(with: NSRect(x: textX, y: box.midY - height / 2, width: textWidth, height: height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        if isChoice {
            let circle = NSRect(x: box.minX + 11, y: box.midY - 8, width: 16, height: 16)
            let marker = NSBezierPath(ovalIn: circle)
            NSColor.white.withAlphaComponent((state == .on ? 0.22 : 0.08) * alpha).setFill(); marker.fill()
            let number = NSAttributedString(string: state == .on ? "✓" : "\(tag + 1)", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: foreground])
            let size = number.size()
            number.draw(at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2))
        }
        if window?.firstResponder === self {
            NSColor.white.withAlphaComponent(0.7).setStroke()
            let focus = NSBezierPath(roundedRect: box.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7)
            focus.lineWidth = 0.7; focus.stroke()
        }
    }
}
