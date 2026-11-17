# 앱 아이콘

보관함의 카드 더미를 옮긴 모양입니다. 맨 앞 앨범 카드에 해와 언덕 사진, 뒤로 앨범 두 장이 겹쳐 있습니다.

| 파일 | 쓰임 |
|---|---|
| `light.html` | 기본 아이콘 (`AppIcon.png`) |
| `dark.html` | 다크 모드 아이콘 (`AppIcon-Dark.png`) |
| `tinted.html` | 틴트(단색) 아이콘 (`AppIcon-Tinted.png`). 시스템이 색을 입힌다 |

고친 뒤 1024×1024 PNG로 다시 뽑아 `PhotoAlbum/Assets.xcassets/AppIcon.appiconset/`에 덮어씁니다.
투명한 부분이 없어야 앱 스토어가 받습니다. 모서리는 시스템이 둥글게 깎으므로 네모로 둡니다.

```sh
# Chrome(또는 Chromium headless)으로 뽑기
chrome --headless --hide-scrollbars --force-device-scale-factor=1 \
  --window-size=1024,1024 --screenshot=light.png "file://$PWD/light.html"
```
