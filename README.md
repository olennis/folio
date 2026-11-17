# Folio

종이 앨범처럼 연도, 인물, 여행 단위로 사진을 묶어 보는 iPhone 사진 뷰어입니다.
사진 앱의 폴더 정리가 불편한 문제를, 음악 앱의 보관함 구조(앨범 → 포토앨범, 곡 → 사진)를 빌려 풉니다.

## 기능

- **홈**: 몇 년 전 오늘의 앨범, 자주 보는 인물, 최근 본 앨범
- **보관함**: 앨범을 카드 더미로 넘겨 보기, 전체·연도·인물·장소로 걸러 보기
- **앨범**: 가로 캐러셀과 필름 스트립, 기간·장소 요약, 사진 이름 붙이기, 순서 바꾸기, 표지 설정
- **뷰어**: 확대, 이전·다음, 슬라이드쇼, 속한 앨범 표시, 빼기 실행 취소
- **정리**: 어느 앨범에도 없는 사진을 골라 여러 앨범에 한 번에 넣기(날짜·장소로 앨범 추천)
- **검색**: 앨범 이름으로 찾기
- **미니 바**: 보던 사진으로 돌아가기

한 사진은 여러 앨범에 속할 수 있습니다(`Photo` – `AlbumPhoto` – `Album`). 앨범은 사진을 복사하지 않고 사진 보관함의 식별자만 가집니다.

## 실행

SwiftUI · SwiftData · PhotoKit, iOS 17 이상(Xcode 26에서 빌드).

```sh
open PhotoAlbum.xcodeproj
# 또는 시뮬레이터 테스트
xcodebuild -project PhotoAlbum.xcodeproj -scheme PhotoAlbum \
  -destination "platform=iOS Simulator,name=iPhone 17" test
```

실행 인자 `-seedDemo`를 주면 기기의 사진으로 예시 앨범을 만듭니다(디버그 빌드).

`mockup/`에는 구현 전 HTML 목업과 화면 캡처가 있습니다.
