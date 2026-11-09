import Foundation

/// 앱 번들의 `Localizable.strings` 에서 메뉴·알림·입력 창 문구를 찾는다. 인자가 없으면
/// 형식 문자열로 해석하지 않으므로 그 값은 `%` 를 그대로 쓰고, 인자가 있는 값은 글자
/// `%` 를 `%%` 로 쓴다.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    return arguments.isEmpty ? format : String(format: format, locale: .current, arguments: arguments)
}
