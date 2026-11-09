#!/bin/bash
# 릴리스 사전 점검: 서명·공증 시크릿 다섯과 탭 쓰기 토큰이 모두 있는지 본다. 빈 것마다
# 이름을 밝히고 하나라도 비면 종료 1 — 아무것도 공개하기 전에 멈춘다. 값은 출력하지 않는다.
set -euo pipefail

names=(
    DEVELOPER_ID_P12_BASE64
    DEVELOPER_ID_P12_PASSWORD
    NOTARY_APPLE_ID
    NOTARY_TEAM_ID
    NOTARY_APP_PASSWORD
    HOMEBREW_TAP_TOKEN
)

missing=0
for name in "${names[@]}"; do
    if [[ -z "${!name:-}" ]]; then
        echo "::error::missing secret: $name" >&2
        missing=1
    fi
done
exit "$missing"
