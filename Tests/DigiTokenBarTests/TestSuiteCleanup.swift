import Foundation

/// 테스트 suite 정리 — 도메인 비우기 + plist 파일 삭제를 함께 한다.
///
/// `removePersistentDomain(forName:)` 은 도메인 **내용만** 비우고
/// `~/Library/Preferences/<suiteName>.plist` 파일은 그대로 남긴다. UUID 접미사 suite 를
/// 테스트마다 새로 만드는 구조에서는 42바이트 빈 plist 가 영구 누적된다(실측 6만 개 이상).
/// 그래서 도메인 제거 뒤 파일까지 직접 지운다.
///
/// `XCTestCase` extension 이 아니라 `UserDefaults` 의 static 메서드인 이유: 호출부 상당수가
/// `addTeardownBlock { ... }` 이고 그 클로저는 `@escaping @Sendable` 이다. 인스턴스 메서드로
/// 두면 클로저가 non-Sendable 한 `XCTestCase` 를 캡처해 동시성 진단에 걸린다. static 이면
/// 지금처럼 suite 이름(String)만 캡처한다.
extension UserDefaults {
    /// `suiteName` 도메인을 제거하고 대응하는 preferences plist 파일도 삭제한다.
    /// 파일이 없거나 지울 수 없어도 조용히 넘어간다 — 정리가 테스트를 깨뜨려선 안 된다.
    static func removeTestSuite(_ suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent("\(suiteName).plist")
        try? FileManager.default.removeItem(at: plist)
    }
}
