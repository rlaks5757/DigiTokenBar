import Foundation

/// 부화 후보 — 진화라인 시작점(base) 종과 희귀도 신호.
struct BaseSpecies: Sendable, Codable {
    let id: Int
    let captureRate: Int    // 3(희귀)~255(흔함) — 현재는 `DigimonLineProvider` 가 등급에서 유도한다
}

/// 진화 라인 데이터 제공(주입 가능 — 테스트는 스텁 사용). 프로덕션 구현은 `DigimonLineProvider`(번들 JSON).
protocol DigimonLineProviding: Sendable {
    func line(baseSpeciesID: Int) async throws -> EvoLine
    /// 부화 후보가 되는 base 종 전체 인덱스.
    func baseSpeciesIndex() async throws -> [BaseSpecies]
    /// 단일 종이 base(진화 시작점)면 BaseSpecies, 아니면 nil.
    /// `baseSpeciesIndex()` 가 throw 할 때 종 단위로 후보를 뽑는 폴백 경로용
    /// (`CompanionStore.chooseBaseViaREST`).
    func baseSpecies(id: Int) async throws -> BaseSpecies?
}

/// Separate from `DigimonLineProviding` so existing evolution-only test doubles stay small.
protocol DigimonDetailProviding: Sendable {
    func digimonDetails(speciesID: Int) async throws -> DigimonDetails
}

// MARK: - 이름 응답 DTO (`DigimonNameLocalization` 이 디코드)

struct NameDTO: Decodable, Sendable { let name: String; let language: NamedRef }
struct NamedRef: Decodable, Sendable { let name: String; let url: String? }
