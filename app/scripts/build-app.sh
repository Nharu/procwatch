#!/bin/bash
# procwatch.app 의 유일한 진입점: 빌드 + 조립 + 서명. `--install` 이면 /Applications 에
# 설치해 띄우고, `--uninstall` 이면 빌드 없이 설치본과 로그인 항목과 설정을 지운다.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

mode="build"
case "${1:-}" in
    "") ;;
    --install) mode="install" ;;
    --uninstall) mode="uninstall" ;;
    *) echo "사용법: $0 [--install | --uninstall]" >&2; exit 2 ;;
esac

if [[ "$mode" == "uninstall" ]]; then
    # 순서가 하중을 진다. 로그인 자동 실행 앱이라 거의 늘 이미 돌고 있고, `open -a` 는
    # 도는 앱에 `--args` 를 전달하지 않으므로 먼저 죽이고 `-n` 으로 새 인스턴스를 띄운다.
    # `-W` 로 그 인스턴스가 unregister() 를 마칠 때까지 기다린 뒤에야 번들을 지운다 —
    # 번들이 먼저 사라지면 등록을 해제할 주체가 없어 로그인 항목이 남는다.
    pkill -x procwatch || true                                           # 1. 도는 인스턴스 종료
    open -n -W -a /Applications/procwatch.app --args --unregister-login-item || true
                                                                         # 2. 새 인스턴스가 스스로 unregister()
    rm -rf /Applications/procwatch.app                                   # 3. 번들 제거
    defaults delete io.github.nharu.procwatch || true                    # 4. 설정 도메인 제거
    exit 0
fi

# 번들 버전: PROCWATCH_VERSION 이 있으면 그 값, 없으면 가장 가까운 v<주>.<부>.<수> 태그,
# 그것도 없으면(태그 없음·얕은 클론) 0.0.0. CFBundleShortVersionString 은 숫자 셋이어야 한다.
version_pattern='^[0-9]+\.[0-9]+\.[0-9]+$'
if [[ -n "${PROCWATCH_VERSION:-}" ]]; then
    if [[ ! "$PROCWATCH_VERSION" =~ $version_pattern ]]; then
        echo "PROCWATCH_VERSION must be <major>.<minor>.<patch>: $PROCWATCH_VERSION" >&2
        exit 2
    fi
    version="$PROCWATCH_VERSION"
else
    tag="$(git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null || true)"
    version="${tag#v}"
    [[ "$version" =~ $version_pattern ]] || version="0.0.0"
fi

# 서명 신원: 없으면 애드혹(-). 공증이 요구하는 hardened runtime 은 애드혹에도 켜고,
# 보안 타임스탬프는 실제 신원일 때만 붙인다.
identity="${PROCWATCH_SIGN_IDENTITY:--}"
sign_flags=(--force --options runtime)
[[ "$identity" == "-" ]] || sign_flags+=(--timestamp)

swift build --package-path app -c release --arch arm64
BIN="$(swift build --package-path app -c release --arch arm64 --show-bin-path)/procwatch"
APP=app/.build/bundle/procwatch.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/kiwi"
cp "$BIN" "$APP/Contents/MacOS/procwatch"
cp app/Bundle/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" "$APP/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string "$version" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
cp assets/frames2/kiwi/0[0-3].png "$APP/Contents/Resources/kiwi/"
# 앱의 현지화 목록은 Resources 의 .lproj 디렉터리가 정한다.
cp -R app/Bundle/en.lproj app/Bundle/ko.lproj "$APP/Contents/Resources/"
plutil -lint "$APP/Contents/Resources/en.lproj/Localizable.strings" "$APP/Contents/Resources/ko.lproj/Localizable.strings"
rm -rf app/.build/AppIcon.iconset
swift app/scripts/make-icon.swift assets/frames2/kiwi/00.png app/.build/AppIcon.iconset
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" app/.build/AppIcon.iconset
codesign "${sign_flags[@]}" --sign "$identity" --identifier io.github.nharu.procwatch "$APP"
codesign --verify --strict "$APP"

if [[ "$mode" == "install" ]]; then
    # `osascript quit` 은 설치 도중 자동화 동의 창을 띄우고, 정상 종료가 저장할 것도 없다.
    pkill -x procwatch || true
    rm -rf /Applications/procwatch.app
    ditto "$APP" /Applications/procwatch.app
    open /Applications/procwatch.app
fi
