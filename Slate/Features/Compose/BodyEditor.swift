import SwiftUI
import UIKit

/// Lets SwiftUI controls apply formatting to the live text view.
@MainActor
final class BodyEditorController {
    weak var textView: UITextView?
    var onChange: ((NSAttributedString) -> Void)?

    func replaceAll(_ text: NSAttributedString) {
        guard let tv = textView else { return }
        tv.attributedText = Self.normalized(text)
    }

    static func normalized(_ text: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: m.length)
        m.enumerateAttribute(.font, in: full) { value, range, _ in
            let traits = (value as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            m.addAttribute(.font, value: font(traits.intersection([.traitBold, .traitItalic])), range: range)
        }
        m.addAttribute(.foregroundColor, value: UIColor.label, range: full)
        return m
    }

    static func font(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: .body)
        guard !traits.isEmpty, let d = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: d, size: 0)
    }

    func toggle(_ trait: UIFontDescriptor.SymbolicTraits) {
        guard let tv = textView else { return }
        let range = tv.selectedRange
        if range.length == 0 {
            var attrs = tv.typingAttributes
            let current = (attrs[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            attrs[.font] = Self.font(current.symmetricDifference(trait).intersection([.traitBold, .traitItalic]))
            tv.typingAttributes = attrs
            return
        }
        let storage = tv.textStorage
        var allHave = true
        storage.enumerateAttribute(.font, in: range) { v, _, _ in
            if !((v as? UIFont)?.fontDescriptor.symbolicTraits.contains(trait) ?? false) { allHave = false }
        }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { v, r, _ in
            var t = (v as? UIFont)?.fontDescriptor.symbolicTraits.intersection([.traitBold, .traitItalic]) ?? []
            if allHave { t.remove(trait) } else { t.insert(trait) }
            storage.addAttribute(.font, value: Self.font(t), range: r)
        }
        storage.endEditing()
        tv.selectedRange = range
        onChange?(tv.attributedText)
    }

    /// Toggles "• " at the start of each selected paragraph.
    func toggleBullets() {
        guard let tv = textView else { return }
        let ns = tv.textStorage.string as NSString
        let para = ns.paragraphRange(for: tv.selectedRange)
        var starts: [Int] = []
        ns.enumerateSubstrings(in: para, options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in starts.append(r.location) }
        if starts.isEmpty { starts = [para.location] }
        let allBulleted = starts.allSatisfy { ns.length >= $0 + 2 && ns.substring(with: NSRange(location: $0, length: 2)) == "• " }
        tv.textStorage.beginEditing()
        for s in starts.reversed() {
            if allBulleted { tv.textStorage.deleteCharacters(in: NSRange(location: s, length: 2)) }
            else { tv.textStorage.insert(NSAttributedString(string: "• ", attributes: tv.typingAttributes), at: s) }
        }
        tv.textStorage.endEditing()
        onChange?(tv.attributedText)
    }

    func addLink(_ url: URL) {
        guard let tv = textView else { return }
        var range = tv.selectedRange
        if range.length == 0 {
            let text = NSAttributedString(string: url.absoluteString, attributes: tv.typingAttributes)
            tv.textStorage.insert(text, at: range.location)
            range = NSRange(location: range.location, length: text.length)
        }
        tv.textStorage.addAttribute(.link, value: url, range: range)
        onChange?(tv.attributedText)
    }

    var hasSelection: Bool { (textView?.selectedRange.length ?? 0) > 0 }
}

/// UITextView-backed body editor: native selection, spellcheck, dictation, undo, Writing Tools, and Dynamic Type.
struct BodyEditor: UIViewRepresentable {
    var initial: NSAttributedString
    var controller: BodyEditorController
    var onChange: (NSAttributedString) -> Void
    var onWritingTools: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.attributedText = BodyEditorController.normalized(initial)
        tv.typingAttributes = [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label]
        tv.adjustsFontForContentSizeCategory = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        tv.allowsEditingTextAttributes = true
        tv.dataDetectorTypes = []
        tv.autocapitalizationType = .sentences
        tv.smartQuotesType = .default
        tv.writingToolsBehavior = .complete
        tv.allowedWritingToolsResultOptions = [.plainText, .richText, .list]
        tv.delegate = context.coordinator
        tv.accessibilityLabel = "Message body"
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        controller.textView = tv
        controller.onChange = onChange
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        controller.onChange = onChange
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(220, size.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: BodyEditor
        init(_ parent: BodyEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.onChange(textView.attributedText)
            textView.invalidateIntrinsicContentSize()
        }

        func textViewWritingToolsWillBegin(_ textView: UITextView) { parent.onWritingTools(true) }

        func textViewWritingToolsDidEnd(_ textView: UITextView) {
            parent.onWritingTools(false)
            parent.onChange(textView.attributedText)
        }
    }
}
