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

swift build --package-path app -c release --arch arm64
BIN="$(swift build --package-path app -c release --arch arm64 --show-bin-path)/procwatch"
APP=app/.build/bundle/procwatch.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/kiwi"
cp "$BIN" "$APP/Contents/MacOS/procwatch"
cp app/Bundle/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
cp assets/frames2/kiwi/0[0-3].png "$APP/Contents/Resources/kiwi/"
rm -rf app/.build/AppIcon.iconset
swift app/scripts/make-icon.swift assets/frames2/kiwi/00.png app/.build/AppIcon.iconset
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" app/.build/AppIcon.iconset
codesign --force --sign - --identifier io.github.nharu.procwatch "$APP"
codesign --verify --strict "$APP"

if [[ "$mode" == "install" ]]; then
    # `osascript quit` 은 설치 도중 자동화 동의 창을 띄우고, 정상 종료가 저장할 것도 없다.
    pkill -x procwatch || true
    rm -rf /Applications/procwatch.app
    ditto "$APP" /Applications/procwatch.app
    open /Applications/procwatch.app
fi
