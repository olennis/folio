import XCTest

/// 손으로 하는 조작(누르기, 끌기)이 기대대로 동작하는지 시뮬레이터에서 확인한다.
/// 예시 앨범(`-seedDemo`)이 들어 있는 상태를 전제로 한다.
final class PhotoAlbumUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        // 실기기용으로 기억해 둔 Pro 강제 값이 테스트 사이에 남지 않게 지우고 시작한다.
        app.launchArguments = ["-seedDemo", "-forcePro", "CLEAR"]
        app.launch()
        allowPhotosIfAsked()
        // 앱은 홈에서 시작한다. 대부분의 테스트는 보관함에서 출발한다.
        let library = app.tabBars.firstMatch.buttons["보관함"]
        XCTAssertTrue(library.waitForExistence(timeout: 15))
        library.tap()
        // 켜진 직후의 탭이 가끔 먹히지 않는다. 보관함이 안 뜨면 한 번 더 누른다.
        if !app.navigationBars["보관함"].waitForExistence(timeout: 5) { library.tap() }
        XCTAssertTrue(app.navigationBars["보관함"].waitForExistence(timeout: 15))
        XCTAssertTrue(frontCard.waitForExistence(timeout: 15), "예시 앨범이 보여야 한다")
    }

    private var frontCard: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "제주 가족여행")).firstMatch
    }

    private func allowPhotosIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["전체 접근 허용", "Allow Full Access"] {
            let button = springboard.buttons[title]
            if button.waitForExistence(timeout: 2) {
                button.tap()
                return
            }
        }
    }

    private func shot(_ name: String) {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("mockup/screenshots")
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: folder.appendingPathComponent("ui-\(name).png"))
    }

    private func openFrontAlbum() {
        frontCard.tap()
        let opened = app.navigationBars["제주 가족여행"].waitForExistence(timeout: 5)
        if !opened { shot("fail-open-album") }
        XCTAssertTrue(opened, "앞 카드를 누르면 앨범이 열려야 한다")
    }

    func testTappingFrontCardOpensAlbumAndBackStaysInLibrary() {
        shot("01-library")
        openFrontAlbum()
        XCTAssertTrue(app.staticTexts["album-position"].waitForExistence(timeout: 5))
        shot("02-album")

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["보관함"].waitForExistence(timeout: 5))
        // 돌아온 뒤 아무것도 하지 않으면 보관함에 그대로 있어야 한다.
        sleep(3)
        XCTAssertTrue(app.navigationBars["보관함"].exists)
        XCTAssertFalse(app.navigationBars["제주 가족여행"].exists)
    }

    func testDraggingDeckDownFlipsToNextAlbumWithoutOpeningIt() {
        let position = app.staticTexts["deck-position"]
        XCTAssertTrue(position.label.hasPrefix("1 /"), position.label)

        let start = frontCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = frontCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        start.press(forDuration: 0.05, thenDragTo: end)

        sleep(1)
        XCTAssertTrue(app.navigationBars["보관함"].exists, "끌었을 때 앨범이 열리면 안 된다")
        XCTAssertTrue(position.label.hasPrefix("2 /"), position.label)
        shot("03-deck-flipped")
    }

    func testSmallDragSnapsBackWithoutFlipping() {
        let position = app.staticTexts["deck-position"]
        let start = frontCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let end = frontCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.44))
        start.press(forDuration: 0.3, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)

        sleep(1)
        XCTAssertTrue(app.navigationBars["보관함"].exists)
        XCTAssertTrue(position.label.hasPrefix("1 /"), position.label)
    }

    func testViewerOpensAndRemovalCanBeUndone() {
        openFrontAlbum()
        let before = app.staticTexts["album-position"].label

        app.buttons["carousel-photo-1"].tap()
        let close = app.buttons["닫기"]
        let viewerOpened = close.waitForExistence(timeout: 5)
        if !viewerOpened {
            shot("fail-open-viewer")
            print("UI-TREE-BEGIN\n\(app.debugDescription)\nUI-TREE-END")
        }
        XCTAssertTrue(viewerOpened, "사진을 누르면 뷰어가 열려야 한다")
        let viewerPosition = app.staticTexts["viewer-position"]
        XCTAssertTrue(viewerPosition.waitForExistence(timeout: 5))
        let total = viewerPosition.label
        shot("04-viewer")

        app.buttons["이 앨범에서 빼기"].tap()
        let undo = app.buttons["실행 취소"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "빼면 실행 취소가 떠야 한다")
        XCTAssertNotEqual(viewerPosition.label, total)
        shot("05-viewer-undo")

        undo.tap()
        XCTAssertTrue(viewerPosition.waitForExistence(timeout: 3))
        XCTAssertEqual(viewerPosition.label, total, "실행 취소하면 같은 자리로 돌아온다")

        close.tap()
        XCTAssertTrue(app.navigationBars["제주 가족여행"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["album-position"].label, before)
    }

    func testTabBarSwitchesBetweenLibraryOrganizeAndSearch() {
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.buttons["보관함"].exists)

        tabs.buttons["정리"].tap()
        XCTAssertTrue(app.navigationBars["정리"].waitForExistence(timeout: 5))
        let unsorted = app.staticTexts["unsorted-count"]
        let allDone = app.staticTexts["모두 정리했습니다"]
        XCTAssertTrue(unsorted.waitForExistence(timeout: 5) || allDone.exists, "미정리 사진이나 완료 안내가 보여야 한다")
        shot("06-organize")

        tabs.buttons["검색"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("제주")
        shot("07-search")
        // 미니 바도 앨범 이름을 담고 있으므로 이름으로 시작하는 줄만 찾는다.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "제주 가족여행, 사진")).firstMatch
        let found = row.waitForExistence(timeout: 8)
        if !found { print("UI-TREE-BEGIN\n\(app.debugDescription)\nUI-TREE-END") }
        XCTAssertTrue(found, "검색어에 맞는 앨범이 보여야 한다")
        row.tap()
        XCTAssertTrue(app.navigationBars["제주 가족여행"].waitForExistence(timeout: 5))
    }

    func testFilterShowsOnlyAlbumsOfThatKind() {
        let position = app.staticTexts["deck-position"]
        XCTAssertTrue(position.label.hasSuffix("/ 4"), position.label)

        app.segmentedControls.buttons["인물"].tap()
        let person = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "서윤이 성장 앨범")).firstMatch
        XCTAssertTrue(person.waitForExistence(timeout: 5), "인물 앨범만 남아야 한다")
        XCTAssertFalse(frontCard.exists)
        shot("08-filter-person")

        app.segmentedControls.buttons["전체"].tap()
        XCTAssertTrue(frontCard.waitForExistence(timeout: 5))
    }

    func testViewerStepsWithButtonsAndMiniBarReturnsToThatPhoto() {
        openFrontAlbum()
        XCTAssertTrue(app.staticTexts["album-summary"].exists)
        app.buttons["carousel-photo-1"].tap()
        let viewerPosition = app.staticTexts["viewer-position"]
        XCTAssertTrue(viewerPosition.waitForExistence(timeout: 5))
        XCTAssertTrue(viewerPosition.label.hasPrefix("1 /"), viewerPosition.label)
        XCTAssertFalse(app.buttons["이전 사진"].isEnabled)

        app.buttons["다음 사진"].tap()
        sleep(1)
        XCTAssertTrue(viewerPosition.label.hasPrefix("2 /"), viewerPosition.label)

        // 슬라이드쇼: 막대가 숨고 혼자 넘어간다. 화면을 누르면 멈춘다.
        app.buttons["슬라이드쇼"].tap()
        sleep(4)
        shot("09-slideshow")
        XCTAssertFalse(app.buttons["닫기"].exists, "슬라이드쇼 중에는 막대가 숨는다")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["닫기"].waitForExistence(timeout: 5))
        XCTAssertTrue(viewerPosition.label.hasPrefix("3 /"), viewerPosition.label)
        let seen = viewerPosition.label

        app.buttons["닫기"].tap()
        XCTAssertTrue(app.navigationBars["제주 가족여행"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()

        // 다른 탭에 가서도 미니 바로 보던 사진에 돌아온다.
        app.tabBars.firstMatch.buttons["정리"].tap()
        let bar = app.buttons["mini-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "보던 사진이 있으면 미니 바가 보여야 한다")
        shot("10-mini-bar")
        bar.tap()
        XCTAssertTrue(viewerPosition.waitForExistence(timeout: 5))
        XCTAssertEqual(viewerPosition.label, seen)
        app.buttons["닫기"].tap()
        XCTAssertTrue(app.navigationBars["정리"].waitForExistence(timeout: 5))
    }

    func testHomeShowsRecentlyOpenedAlbum() {
        openFrontAlbum()
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.firstMatch.buttons["홈"].tap()
        XCTAssertTrue(app.navigationBars["홈"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["최근 본 앨범"].waitForExistence(timeout: 5))
        shot("11-home")
        let recent = app.buttons.matching(identifier: "recent-album").firstMatch
        XCTAssertTrue(recent.label.contains("제주 가족여행"), recent.label)
        recent.tap()
        XCTAssertTrue(app.navigationBars["제주 가족여행"].waitForExistence(timeout: 5))
    }

    func testPhotoCanBeNamedAndSheetOffersSearch() {
        openFrontAlbum()
        app.buttons["더 보기"].tap()
        let name = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "사진 이름")).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if let old = field.value as? String, !old.isEmpty, old != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText("Morning")
        app.alerts.buttons["저장"].tap()
        let title = app.staticTexts["photo-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Morning")
        shot("12-photo-title")

        // 붙인 이름을 지워 예시 데이터를 원래대로 돌려놓는다. 비우면 다시 날짜가 보인다.
        app.buttons["더 보기"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7))
        app.alerts.buttons["저장"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertNotEqual(title.label, "Morning")

        // 앨범 선택 시트: 검색 필드가 있고, 이름으로 좁혀진다.
        app.buttons["더 보기"].tap()
        app.buttons["다른 앨범에도 넣기…"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        shot("13-album-sheet")
        search.tap()
        search.typeText("2015")
        XCTAssertTrue(app.staticTexts["검색 결과"].waitForExistence(timeout: 5)
            || app.staticTexts["검색 결과".uppercased()].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "캠핑 모음")).firstMatch.exists)
    }

    // MARK: Folio Pro

    /// 앱을 주어진 실행 인자로 다시 켜고 보관함으로 간다.
    private func relaunch(_ arguments: [String]) {
        app.terminate()
        app.launchArguments = ["-seedDemo"] + arguments
        app.launch()
        let library = app.tabBars.firstMatch.buttons["보관함"]
        XCTAssertTrue(library.waitForExistence(timeout: 15))
        library.tap()
        XCTAssertTrue(app.navigationBars["보관함"].waitForExistence(timeout: 10))
    }

    private var albumCount: Int {
        let position = app.staticTexts["deck-position"]
        guard position.waitForExistence(timeout: 5) else { return 1 }
        return Int(position.label.split(separator: "/").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
    }

    private func tapNewAlbum() {
        app.navigationBars["보관함"].buttons["새로운 앨범"].tap()
    }

    /// 무료 한도(5개)까지 앨범을 채운다. 만든 앨범 이름을 돌려준다.
    private func fillToFreeLimit() -> [String] {
        var created: [String] = []
        while albumCount < 5 {
            let name = "Pro 테스트 \(created.count + 1)"
            tapNewAlbum()
            let field = app.alerts.textFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5), "한도 전에는 앨범 만들기 창이 떠야 한다")
            field.typeText(name)
            app.alerts.buttons["만들기"].tap()
            created.append(name)
            sleep(1)
        }
        return created
    }

    private func albumCard(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(name), 사진")).firstMatch
    }

    /// 테스트가 만든 앨범을 지워 예시 데이터를 원래대로 돌려놓는다. 새 앨범은 늘 맨 앞에 온다.
    /// 지우지 못하면 실패한다. 남은 앨범이 다음 테스트를 망가뜨리기 때문이다.
    private func deleteAlbums(_ names: [String]) {
        for name in names.reversed() {
            // 앨범 카드의 라벨은 "이름, 사진 N장"이다. 미니 바처럼 이름으로 시작하는 다른 버튼과 헷갈리지 않게 한다.
            let card = albumCard(name)
            XCTAssertTrue(card.waitForExistence(timeout: 5), "지울 앨범 '\(name)'이 보여야 한다")
            card.press(forDuration: 1.0)
            let menuItem = app.buttons["앨범 삭제"].firstMatch
            if !menuItem.waitForExistence(timeout: 5) {
                shot("fail-delete-menu")
                for element in app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).allElementsBoundByIndex {
                    print("DELETE candidate:", element.label, element.frame, element.isHittable)
                }
            }
            XCTAssertTrue(menuItem.exists, "길게 누르면 앨범 메뉴가 떠야 한다")
            menuItem.tap()
            // 메뉴 항목과 이름이 같으므로, 확인 창 안의 버튼만 찾는다.
            let dialog = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.alerts.firstMatch
            let confirm = dialog.buttons["앨범 삭제"]
            if confirm.waitForExistence(timeout: 5) {
                confirm.tap()
            } else {
                app.buttons.matching(NSPredicate(format: "label == %@", "앨범 삭제")).allElementsBoundByIndex.last?.tap()
            }
            let gone = NSPredicate(format: "exists == false")
            expectation(for: gone, evaluatedWith: card)
            waitForExpectations(timeout: 5)
        }
    }

    func testFreeUserHitsAlbumLimitAndSeesPaywall() {
        relaunch(["-forcePro", "NO"])
        let created = fillToFreeLimit()
        tapNewAlbum()
        let headline = app.staticTexts["paywall-headline"]
        XCTAssertTrue(headline.waitForExistence(timeout: 5), "무료 한도를 넘기면 결제 화면이 떠야 한다")
        XCTAssertTrue(headline.label.contains("5개까지"), headline.label)
        XCTAssertTrue(app.buttons["구매 복원"].exists, "구매 복원은 늘 있어야 한다")
        let buy = app.buttons["paywall-buy"]
        XCTAssertTrue(buy.waitForExistence(timeout: 5))
        print("PAYWALL buy button:", buy.label)
        shot("14-paywall")
        app.buttons["닫기"].tap()
        XCTAssertFalse(app.alerts.firstMatch.exists, "결제 화면을 닫으면 앨범 만들기 창이 뜨면 안 된다")
        deleteAlbums(created)
    }

    func testProUserHasNoAlbumLimit() {
        relaunch(["-forcePro", "YES"])
        let created = fillToFreeLimit()
        tapNewAlbum()
        XCTAssertTrue(app.alerts["새로운 앨범"].waitForExistence(timeout: 5), "Pro는 한도 없이 앨범을 만든다")
        XCTAssertFalse(app.staticTexts["paywall-headline"].exists)
        app.alerts.buttons["취소"].tap()

        app.tabBars.firstMatch.buttons["홈"].tap()
        XCTAssertTrue(app.buttons["pro-button"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["pro-button"].label, "Folio Pro 사용 중")
        app.tabBars.firstMatch.buttons["보관함"].tap()
        deleteAlbums(created)
    }

    func testHomeTeasesMemoriesForFreeUsers() {
        // 예시 사진 가운데 2012년 8월 9일 사진이 있어, 이날로 맞추면 "N년 전 오늘"이 생긴다.
        relaunch(["-forcePro", "NO", "-today", "2018-08-09"])
        app.tabBars.firstMatch.buttons["홈"].tap()
        let locked = app.buttons["locked-feature"]
        XCTAssertTrue(locked.waitForExistence(timeout: 10), "무료 사용자에게는 추천이 잠긴 카드로 보여야 한다")
        XCTAssertTrue(locked.label.contains("년 전"), locked.label)
        shot("15-home-locked")
        locked.tap()
        let headline = app.staticTexts["paywall-headline"]
        XCTAssertTrue(headline.waitForExistence(timeout: 5))
        XCTAssertTrue(headline.label.contains("몇 년 전 오늘"), headline.label)
        app.buttons["닫기"].tap()
    }

    // MARK: 자동 분류

    func testProAutoClassifySuggestionCreatesAlbum() {
        relaunch(["-forcePro", "YES", "-autoMinimum", "1"])
        app.tabBars.firstMatch.buttons["정리"].tap()
        // 새 앨범을 만드는 제안을 고른다(이미 있는 예시 앨범을 바꾸지 않도록).
        let card = app.buttons.matching(identifier: "auto-suggestion")
            .matching(NSPredicate(format: "label CONTAINS %@", "새 앨범")).firstMatch
        let appeared = card.waitForExistence(timeout: 15)
        if !appeared {
            shot("fail-auto")
            for element in app.buttons.matching(identifier: "auto-suggestion").allElementsBoundByIndex {
                print("AUTO card:", element.label)
            }
            print("UI-TREE-BEGIN\n\(app.debugDescription)\nUI-TREE-END")
        }
        XCTAssertTrue(appeared, "Pro는 정리 탭에서 자동 분류 제안을 본다")
        shot("19-auto-classify")
        card.tap()

        let title = app.textFields["auto-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let name = (title.value as? String) ?? ""
        XCTAssertFalse(name.isEmpty)
        let apply = app.buttons["auto-apply"]
        XCTAssertTrue(apply.label.hasPrefix("앨범 만들기"), apply.label)
        shot("20-auto-review")
        apply.tap()

        app.tabBars.firstMatch.buttons["보관함"].tap()
        let created = albumCard(name)
        XCTAssertTrue(created.waitForExistence(timeout: 5), "제안대로 새 앨범 '\(name)'이 생겨야 한다")
        deleteAlbums([name])
    }

    func testFreeUserSeesLockedAutoClassify() {
        relaunch(["-forcePro", "NO", "-autoMinimum", "1"])
        app.tabBars.firstMatch.buttons["정리"].tap()
        let locked = app.buttons["locked-auto"]
        XCTAssertTrue(locked.waitForExistence(timeout: 15), "무료 사용자는 잠긴 자동 분류 줄을 본다")
        XCTAssertFalse(app.buttons["auto-suggestion"].exists)
        locked.tap()
        let headline = app.staticTexts["paywall-headline"]
        XCTAssertTrue(headline.waitForExistence(timeout: 5))
        XCTAssertTrue(headline.label.contains("연도·여행·장면"), headline.label)
        app.buttons["닫기"].tap()
    }
    }

    /// 앨범 메뉴의 "표지 바꾸기"로 표지를 고르고, 첫 사진으로 되돌린다.
    func testCoverCanBeChosenAndReset() {
        openFrontAlbum()
        app.buttons["더 보기"].tap()
        let change = app.buttons["표지 바꾸기…"]
        XCTAssertTrue(change.waitForExistence(timeout: 5))
        change.tap()

        let first = app.buttons["표지 사진 1"]
        let second = app.buttons["표지 사진 2"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertTrue(first.isSelected, "처음에는 첫 사진이 표지다")
        XCTAssertFalse(app.buttons["cover-reset"].exists, "직접 고른 표지가 없으면 되돌리기도 없다")
        shot("18-cover-picker")
        second.tap()

        // 고르면 닫힌다. 다시 열면 두 번째 사진이 표지로 표시된다.
        XCTAssertTrue(app.navigationBars["제주 가족여행"].waitForExistence(timeout: 5))
        app.buttons["더 보기"].tap()
        app.buttons["표지 바꾸기…"].tap()
        XCTAssertTrue(app.buttons["표지 사진 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["표지 사진 2"].isSelected)
        XCTAssertFalse(app.buttons["표지 사진 1"].isSelected)

        // 되돌리기: 다시 첫 사진이 표지가 된다(예시 데이터도 원래대로).
        app.buttons["cover-reset"].tap()
        XCTAssertTrue(app.navigationBars["제주 가족여행"].waitForExistence(timeout: 5))
        app.buttons["더 보기"].tap()
        app.buttons["표지 바꾸기…"].tap()
        XCTAssertTrue(app.buttons["표지 사진 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["표지 사진 1"].isSelected)
        XCTAssertFalse(app.buttons["cover-reset"].exists)
        app.buttons["닫기"].tap()
    }

    /// 결제 화면의 버튼은 모두 같은 높이여야 한다(가격을 불러온 때와 못 불러온 때 모두).
    func testPaywallButtonsShareOneHeight() {
        for unavailable in [false, true] {
            relaunch(["-forcePro", "NO"] + (unavailable ? ["-storeUnavailable", "YES"] : []))
            app.tabBars.firstMatch.buttons["홈"].tap()
            app.buttons["pro-button"].tap()
            let primary = app.buttons[unavailable ? "paywall-reload" : "paywall-buy"]
            let restore = app.buttons["paywall-restore"]
            XCTAssertTrue(primary.waitForExistence(timeout: 5))
            XCTAssertTrue(restore.exists)
            print("PAYWALL heights:", primary.frame.height, restore.frame.height, "widths:", primary.frame.width, restore.frame.width)
            XCTAssertEqual(primary.frame.height, restore.frame.height, accuracy: 0.5)
            XCTAssertEqual(primary.frame.width, restore.frame.width, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(restore.frame.height, 44, "누르기 쉬운 크기(44pt 이상)")
            shot(unavailable ? "17-paywall-unavailable" : "16-paywall-buttons")
            app.buttons["닫기"].tap()
        }
    }
}

