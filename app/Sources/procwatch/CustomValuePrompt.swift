import AppKit

/// 「직접 입력…」. `NSApp.activate()` 뒤에 숫자 입력란을 단 `NSAlert` 를 띄우고, 범위 밖이면
/// OK 가 비활성이다.
@MainActor
enum CustomValuePrompt {
    static func ask(title: String, message: String, range: ClosedRange<Int>, current: Int) -> Int? {
        NSApp.activate()

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let ok = alert.addButton(withTitle: L("prompt.ok"))
        alert.addButton(withTitle: L("prompt.cancel"))

        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.formatter = formatter
        field.stringValue = String(current)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let observer = NotificationCenter.default.addObserver(
            forName: NSControl.textDidChangeNotification, object: field, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ok.isEnabled = parse(field.currentEditor()?.string ?? field.stringValue, range: range) != nil
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return parse(field.stringValue, range: range)
    }

    static func parse(_ text: String, range: ClosedRange<Int>) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), range.contains(value) else { return nil }
        return value
    }
}
