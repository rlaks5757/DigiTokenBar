import Foundation

/// 도감 상세 패널이 보여주는 **디지몬 설정 정보**(세대·속성·형태·필살기·소개문).
///
/// `DigimonDetails`(PokéAPI 전투 메타데이터)와는 별개 타입이다 — 그쪽은
/// `DigimonProfile.enrich`/`DigimonStatCalculator` 가 쓰는 능력치 경로이고, 이쪽은 디지몬 고유의
/// 설정값만 담는다. 둘을 한 타입에 합치면 능력치 계산 경로가 설정 데이터의 스키마 변화를 떠안는다.
///
/// **이 타입은 JSON 을 직접 디코딩하지 않는다.** 번들 파일(`Resources/digimon_details.json`)의
/// 파싱·검증은 별도 로더가 맡고, 패널은 `DigimonLoreProviding` 주입으로만 값을 받는다 — 표시
/// 계층이 파일 스키마에 직접 묶이지 않게 하려는 것이다. 하위 타입을 중첩해 두는 이유도 같다:
/// 데이터 계층이 `Attack` 같은 흔한 이름을 최상위에 두더라도 이름이 부딪히지 않는다.
///
/// 출처가 번들 파일이라 **네트워크 대기가 없다** — 로딩 상태가 존재할 수 없고, 조회는 항상 즉시
/// "있음/없음" 으로 끝난다(`DigimonLoreLookup` 참고).
struct DigimonLore: Sendable, Equatable {
    let speciesID: Int
    /// 진화 세대. `DigiLevel` 그대로 — 표시 이름은 `L.stageName(_:)` 가 7개 언어로 번역한다.
    let level: DigiLevel
    /// 백신/데이터/바이러스/프리. 닫힌 집합이라 enum 이고 7개 언어 번역이 있다.
    let attribute: Attribute
    /// 형태(파충류형 등). **열린 집합이라 번역 테이블을 다 채우지 않는다** — 값 종류가 데이터
    /// 파일에서 계속 늘어나(현재 31종) 7개 언어를 미리 채우면 없는 값을 지어내게 된다. 한국어만
    /// `L.typeName(dataValue:)` 로 번역하고, 나머지 언어와 매핑 밖의 값은 이 원문을 그대로 쓴다.
    let type: String
    /// 한국어 표기명. 한국어 화면에서만 쓰고, 없으면 호출부가 기존 이름으로 폴백한다.
    let nameKo: String?
    /// 필살기 — 최대 2개.
    let attacks: [Attack]
    /// 한 줄 소개문(한국어).
    let summaryKo: String?

    /// 디지몬 속성. 닫힌 집합(4종)이라 enum — 열린 집합인 `type` 과 다루는 방식이 다르다.
    /// 데이터 파일이 `"Vaccine"` 처럼 대문자로 시작하는 표기를 쓰므로 `init?(dataValue:)` 가
    /// 대소문자를 무시하고 매핑한다. 모르는 값은 nil 로 떨어뜨려 호출부가 원문을 그대로 보여주게
    /// 한다 — 임의의 케이스에 밀어 넣으면 틀린 속성이 노출된다.
    enum Attribute: String, Sendable, CaseIterable {
        case vaccine, data, virus, free

        init?(dataValue: String) {
            let normalized = dataValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let match = Attribute(rawValue: normalized) else { return nil }
            self = match
        }
    }

    /// 필살기 하나. 한국 더빙명(`nameKo`)은 공식 더빙명이 확인되는 대로 붙는 자리이고, 지금은 없다.
    /// 북미 더빙명을 한국명 대용으로 넣으면 안 된다(틀린 이름).
    ///
    /// `nameKoTranslit`는 **음차**다 — 대부분 영어 외래어를 한국어 표기법으로 옮긴 것이라 실제
    /// 더빙명과 거의 일치하지만, 공식 출처로 확인된 값은 아니다. `nameKo`(확인된 공식 더빙명)가
    /// 채워지면 표시 우선순위를 그쪽으로 옮기고 이 필드는 대체·보조용으로 남긴다.
    struct Attack: Sendable, Equatable {
        let nameJa: String
        let romaji: String
        let nameKo: String?
        /// 한국어 음차(비공식). 위 주석 참고.
        let nameKoTranslit: String?

        init(nameJa: String, romaji: String, nameKo: String? = nil, nameKoTranslit: String? = nil) {
            self.nameJa = nameJa
            self.romaji = romaji
            self.nameKo = nameKo
            self.nameKoTranslit = nameKoTranslit
        }
    }
}

/// 상세 패널이 한 종에 대해 받을 수 있는 **유일한 두 결과**. 번들 데이터라 "로딩 중" 이라는 제3의
/// 상태가 없다 — 이 타입이 없으면 뷰가 `if let` 의 else 를 로딩 스피너로 쓰게 되고, 데이터가 없는
/// 종이 영원히 스피너에서 멈춘다(이번 버그의 형태). 뷰 **밖**의 함수가 이 값을 내놓으므로 테스트가
/// SwiftUI 렌더링 없이 "없는 종은 missing 이다" 를 직접 단언할 수 있다.
enum DigimonLoreLookup: Sendable, Equatable {
    case found(DigimonLore)
    case missing
}

/// 설정 정보 출처. **동기**다 — 번들 파일이라 기다릴 것이 없고, async 로 두면 호출부가 다시
/// "로딩 중" 상태를 만들어내야 한다. 없는 종은 nil 로 즉시 끝난다.
///
/// 데이터 계층(번들 JSON 로더)이 이 프로토콜을 구현해 `CompanionStore(loreSource:)` 로 주입하면
/// 연결이 끝난다 — 표시 계층은 로더의 타입 이름에도, 로드 시점에도 의존하지 않는다.
protocol DigimonLoreProviding: Sendable {
    func lore(speciesID: Int) -> DigimonLore?
}

/// 데이터 출처가 주입되지 않았을 때의 기본값 — 모든 종이 `.missing` 이다.
///
/// 이게 조용한 실패가 아닌 이유: 화면이 스피너에 머무르지 않고 "정보 없음" 을 **명시적으로**
/// 보여준다. 로딩 중과 데이터 없음을 구분하지 못한 것이 바로 이번 버그였다.
struct EmptyDigimonLoreSource: DigimonLoreProviding {
    func lore(speciesID: Int) -> DigimonLore? { nil }
}
