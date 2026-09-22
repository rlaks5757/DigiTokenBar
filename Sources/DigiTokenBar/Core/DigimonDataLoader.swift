import Foundation

// DigimonData 의 JSON 배치(EVOLUTION.md §6) 로더. 파싱 + 무결성 검증만 담당한다
// (UI·네트워크 금지 — DigimonData.swift 와 동일한 제약).
//
// 핵심 로더는 URL/Data 를 파라미터로 받는다 — Bundle.module 을 직접 쓰지 않는다:
//   - Bundle.module 접근자는 실패 시 throw 가 아니라 fatalError trap 이라 명시적 실패 설계가
//     실행될 기회조차 없다.
//   - `swift test` 환경에서 Bundle.main 은 xctest 러너를 가리키고 리소스 조회가 nil 을 반환한다.
// → 앱 전용 진입점(loadFromAppBundle)만 Bundle.main 을 쓰고, 못 찾으면 throw 한다.

/// JSON 디코딩·무결성 검증 실패 원인. 관대하게 기본값으로 흡수하지 않고 전부 throw 한다 —
/// 스키마 불일치를 조용히 삼키면 앱이 "진화가 없는" 상태로 멀쩡히 돌아간다.
enum DigimonDataError: Error, CustomStringConvertible, Equatable {
    /// 리소스 파일을 찾지 못함(앱 번들 진입점 전용 — 핵심 로더는 URL 을 직접 받으므로 해당 없음).
    case resourceNotFound
    /// JSON 디코딩 자체 실패. 메시지는 근본 원인 설명용(Equatable 비교엔 안 씀).
    case decodingFailed(String)
    /// 정규화(min/max) 후 중복되는 죠그레스 키.
    case duplicateJogressKey(a: Int, b: Int)
    /// 중복되는 (Child, 디지멘탈) 아머 키.
    case duplicateArmorKey(childID: Int, digimental: Digimental)
    /// 같은 species id 가 라인마다 다른 레벨로 등장.
    case speciesLevelConflict(id: Int)
    /// 라인이 참조하는 species id 가 species 테이블에 없음.
    case unknownSpeciesInLine(id: Int)
    /// 죠그레스 입력/결과 id 가 species 테이블에 없음.
    case unknownSpeciesInJogress(id: Int)
    /// 아머 결과 id 가 species 테이블에 없음.
    case unknownSpeciesInArmor(id: Int)
    /// 단일 부모 전이(chain)가 참조하는 species id 가 species 테이블에 없음.
    case unknownSpeciesInChain(id: Int)
    /// 통합 진화 그래프(정규+죠그레스+아머)에서 순환 발견.
    case cycleDetected(path: [Int])

    var description: String {
        switch self {
        case .resourceNotFound:
            return "digimon.json 을 앱 번들에서 찾지 못함"
        case .decodingFailed(let reason):
            return "digimon.json 디코딩 실패: \(reason)"
        case .duplicateJogressKey(let a, let b):
            return "죠그레스 키 중복(정규화 후): (\(a), \(b))"
        case .duplicateArmorKey(let childID, let digimental):
            return "아머 키 중복: (child: \(childID), digimental: \(digimental))"
        case .speciesLevelConflict(let id):
            return "species id \(id) 가 라인마다 다른 레벨로 등장"
        case .unknownSpeciesInLine(let id):
            return "라인이 참조하는 species id \(id) 가 species 테이블에 없음"
        case .unknownSpeciesInJogress(let id):
            return "죠그레스가 참조하는 species id \(id) 가 species 테이블에 없음"
        case .unknownSpeciesInArmor(let id):
            return "아머가 참조하는 species id \(id) 가 species 테이블에 없음"
        case .unknownSpeciesInChain(let id):
            return "chain 이 참조하는 species id \(id) 가 species 테이블에 없음"
        case .cycleDetected(let path):
            return "진화 그래프에서 순환 발견: \(path)"
        }
    }
}

// MARK: - JSON 원시 스키마

/// `Resources/digimon.json` 의 최상위 구조를 그대로 반영한 디코딩 전용 타입.
/// 배열 형태를 쓰는 이유: 맵(`[String: T]`) 이었다면 중복 키가 디코딩 단계에서 조용히
/// 마지막 값으로 덮어써져 무결성 검증(중복 죠그레스 키·레벨 충돌)이 애초에 불가능해진다.
private struct RawDataset: Decodable {
    struct Species: Decodable {
        let id: Int
        let apiName: String
        let spriteStem: String
        let spriteStemVerified: Bool
        let spriteSeriesPin: String?
        /// digi-api 에 없는 내부 전용 id 인지. 없으면 false(§ DigimonName.isInternalID 문서 참고).
        let isInternalID: Bool?
    }
    struct Stage: Decodable {
        let id: Int
        let level: DigiLevel
    }
    struct Line: Decodable {
        let key: String
        let stages: [Stage]
        let rarity: Rarity
    }
    struct Jogress: Decodable {
        let a: Int
        let b: Int
        let result: Int
    }
    struct Armor: Decodable {
        let childID: Int
        let digimental: Digimental
        let result: Int
    }
    /// 단일 부모 전이 한 단계. 죠그레스(두 부모)·정규 라인(라인 소속)으로 표현 안 되는
    /// 개별 간선용 — Imperialdramon Dragon Mode 처럼 라인에 속하지 않는 중간 단계가 대상이다.
    /// EVOLUTION.md §3 "Imperialdramon 체인" 참고. 기존 JSON 과의 하위호환을 위해 옵셔널로 둔다.
    struct Chain: Decodable {
        let from: Int
        let fromLevel: DigiLevel
        let to: Int
        let toLevel: DigiLevel
    }

    let dataVersion: Int
    let series: [String]
    let species: [Species]
    let lines: [Line]
    let jogress: [Jogress]
    let chain: [Chain]?
    let armor: [Armor]
}

// MARK: - 로드 결과

/// 로더가 검증까지 마친 후 내놓는 완성된 데이터셋. `DigimonData` 의 정적 프로퍼티들은
/// 이 타입 하나를 감싸는 얇은 파사드다.
struct DigimonDataset: Sendable {
    let dataVersion: Int
    let series: [String]
    let names: [Int: DigimonName]
    let lines: [DigiLine]
    let linesByKey: [String: DigiLine]
    let jogressResults: [JogressKey: Int]
    let armorResults: [ArmorKey: Int]

    /// 통합 진화 그래프(정규+죠그레스+아머)의 순방향 간선 인덱스. 로드 시점에 한 번만 만든다
    /// (중복 진실 원천 금지 — JSON 에 간선을 직접 담지 않는다).
    let forwardEdges: [Int: [EvolutionEdge]]
}

enum DigimonDataLoader {

    /// 핵심 로더. URL 을 받아 Data 를 읽고 디코딩 + 검증한다. 테스트는 이 함수에 직접
    /// `#filePath` 기반 저장소 경로를 넘겨 Bundle 의미론을 우회한다.
    static func load(from url: URL) throws -> DigimonDataset {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DigimonDataError.decodingFailed("파일 읽기 실패: \(error.localizedDescription)")
        }
        return try load(from: data)
    }

    /// Data 를 직접 받는 버전 — 뮤테이션 테스트가 파일 없이 조작된 JSON 을 바로 검증할 때 쓴다.
    static func load(from data: Data) throws -> DigimonDataset {
        let raw: RawDataset
        do {
            raw = try JSONDecoder().decode(RawDataset.self, from: data)
        } catch {
            throw DigimonDataError.decodingFailed("\(error)")
        }

        // 1) 이름 테이블 구성.
        var names: [Int: DigimonName] = [:]
        for s in raw.species {
            names[s.id] = DigimonName(
                apiName: s.apiName,
                spriteStem: s.spriteStem,
                spriteStemVerified: s.spriteStemVerified,
                spriteSeriesPin: s.spriteSeriesPin,
                isInternalID: s.isInternalID ?? false)
        }

        // 2) 라인 구성 + species 참조 무결성 + 종별 레벨 충돌 검증.
        var speciesLevel: [Int: DigiLevel] = [:]
        var lines: [DigiLine] = []
        var linesByKey: [String: DigiLine] = [:]
        for rawLine in raw.lines {
            var stages: [DigiStage] = []
            for rawStage in rawLine.stages {
                guard names[rawStage.id] != nil else {
                    throw DigimonDataError.unknownSpeciesInLine(id: rawStage.id)
                }
                if let existing = speciesLevel[rawStage.id], existing != rawStage.level {
                    throw DigimonDataError.speciesLevelConflict(id: rawStage.id)
                }
                speciesLevel[rawStage.id] = rawStage.level
                stages.append(DigiStage(id: rawStage.id, level: rawStage.level))
            }
            let line = DigiLine(stages: stages, rarity: rawLine.rarity)
            lines.append(line)
            linesByKey[rawLine.key] = line
        }

        // 3) 죠그레스 구성 + 정규화 후 중복 키 검증 + species 참조 무결성.
        var jogressResults: [JogressKey: Int] = [:]
        for j in raw.jogress {
            guard names[j.a] != nil else { throw DigimonDataError.unknownSpeciesInJogress(id: j.a) }
            guard names[j.b] != nil else { throw DigimonDataError.unknownSpeciesInJogress(id: j.b) }
            guard names[j.result] != nil else { throw DigimonDataError.unknownSpeciesInJogress(id: j.result) }
            let key = JogressKey(j.a, j.b)
            guard jogressResults[key] == nil else {
                throw DigimonDataError.duplicateJogressKey(a: j.a, b: j.b)
            }
            jogressResults[key] = j.result
        }

        // 3-b) 단일 부모 전이(chain) 구성 + species 참조 무결성 + 종별 레벨 충돌 검증.
        // 라인·죠그레스 어느 쪽으로도 표현 못하는 중간 단계용(EVOLUTION.md §3 Imperialdramon 체인).
        // speciesLevel 을 라인과 공유해, chain 에 두 번 등장하는 id(예: 900)가 서로 다른 레벨을
        // 주장하면 라인과 동일하게 speciesLevelConflict 로 잡힌다.
        var chainEdges: [(from: Int, to: Int)] = []
        for c in raw.chain ?? [] {
            guard names[c.from] != nil else { throw DigimonDataError.unknownSpeciesInChain(id: c.from) }
            guard names[c.to] != nil else { throw DigimonDataError.unknownSpeciesInChain(id: c.to) }
            for (id, level) in [(c.from, c.fromLevel), (c.to, c.toLevel)] {
                if let existing = speciesLevel[id], existing != level {
                    throw DigimonDataError.speciesLevelConflict(id: id)
                }
                speciesLevel[id] = level
            }
            chainEdges.append((from: c.from, to: c.to))
        }

        // 4) 아머 구성 + 중복 키 검증 + species 참조 무결성.
        var armorResults: [ArmorKey: Int] = [:]
        for a in raw.armor {
            guard names[a.childID] != nil else { throw DigimonDataError.unknownSpeciesInArmor(id: a.childID) }
            guard names[a.result] != nil else { throw DigimonDataError.unknownSpeciesInArmor(id: a.result) }
            let key = ArmorKey(childID: a.childID, digimental: a.digimental)
            guard armorResults[key] == nil else {
                throw DigimonDataError.duplicateArmorKey(childID: a.childID, digimental: a.digimental)
            }
            armorResults[key] = a.result
        }

        // 5) 통합 진화 그래프 인덱스 구성 + 순환 검증(로드 시점에 한 번).
        var forwardEdges: [Int: [EvolutionEdge]] = [:]
        for line in lines {
            for i in 1..<line.stages.count {
                let from = line.stages[i - 1].id
                let to = line.stages[i].id
                forwardEdges[from, default: []].append(.normal(to: to))
            }
        }
        for (key, result) in jogressResults {
            let ids = key.speciesIDs
            forwardEdges[ids[0], default: []].append(.jogress(partnerID: ids[1], to: result))
            forwardEdges[ids[1], default: []].append(.jogress(partnerID: ids[0], to: result))
        }
        for (key, result) in armorResults {
            forwardEdges[key.childID, default: []].append(.armor(digimental: key.digimental, to: result))
        }
        for edge in chainEdges {
            forwardEdges[edge.from, default: []].append(.normal(to: edge.to))
        }

        try detectCycle(forwardEdges: forwardEdges)

        return DigimonDataset(
            dataVersion: raw.dataVersion,
            series: raw.series,
            names: names,
            lines: lines,
            linesByKey: linesByKey,
            jogressResults: jogressResults,
            armorResults: armorResults,
            forwardEdges: forwardEdges)
    }

    /// 앱 전용 진입점. `Bundle.main` 에서 못 찾으면 반드시 throw 한다(trap 금지).
    static func loadFromAppBundle() throws -> DigimonDataset {
        guard let url = Bundle.main.url(forResource: "digimon", withExtension: "json") else {
            throw DigimonDataError.resourceNotFound
        }
        return try load(from: url)
    }

    /// DFS + visited/onPath 로 순환을 감지한다. 순진한 재귀는 실패 대신 hang 하므로
    /// (Paildramon → Imperialdramon 다단 죠그레스가 실제로 재귀 순회를 요구한다) 반드시
    /// onPath 집합으로 "현재 경로 위에 있는 노드로 되돌아오는지"를 구분한다.
    private static func detectCycle(forwardEdges: [Int: [EvolutionEdge]]) throws {
        var visited = Set<Int>()
        var onPath = Set<Int>()
        var pathStack: [Int] = []

        func visit(_ node: Int) throws {
            if onPath.contains(node) {
                throw DigimonDataError.cycleDetected(path: pathStack + [node])
            }
            if visited.contains(node) { return }
            visited.insert(node)
            onPath.insert(node)
            pathStack.append(node)
            for edge in forwardEdges[node] ?? [] {
                try visit(edge.destination)
            }
            pathStack.removeLast()
            onPath.remove(node)
        }

        for node in forwardEdges.keys {
            try visit(node)
        }
    }
}
