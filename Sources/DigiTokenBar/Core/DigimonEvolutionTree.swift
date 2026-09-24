import Foundation

// 진화 트리 조회 계층. 정규 진화 + 죠그레스 + 아머를 하나의 방향 그래프로 통합해
// 순방향/역방향/도달 가능성 질의를 제공한다. 간선은 JSON 에 담지 않고 로드 시점에
// DigimonDataLoader 가 만든 인덱스(DigimonDataset.forwardEdges)를 그대로 쓴다
// (중복 진실 원천 금지).

/// 통합 진화 그래프의 간선 한 개. 종류별로 UI 가 필요로 하는 부가 정보(파트너 종·디지멘탈)를
/// 함께 들고 있다 — 예: "Stingmon을 먼저 졸업시켜야 합니다" 같은 안내는 partnerID 없이 못 만든다.
enum EvolutionEdge: Sendable {
    case normal(to: Int)
    case jogress(partnerID: Int, to: Int)
    case armor(digimental: Digimental, to: Int)

    var destination: Int {
        switch self {
        case .normal(let to): return to
        case .jogress(_, let to): return to
        case .armor(_, let to): return to
        }
    }
}

extension DigimonDataset {

    /// `from` 에서 한 단계로 도달 가능한 모든 간선(정규+죠그레스+아머+chain 통합). 간선이 없으면
    /// 빈 배열(예: 481 은 최종형이라 여기서 나가는 간선이 없다 — EVOLUTION.md §3 참고).
    func nextStages(from id: Int) -> [EvolutionEdge] {
        forwardEdges[id] ?? []
    }

    /// `target` 까지의 모든 역방향 경로(간선 순서대로 나열된 id 리스트, target 포함, 시작 id 포함).
    /// DFS 로 그래프를 거슬러 올라간다. 로드 시점에 순환이 없음을 이미 검증했지만, 방어적으로
    /// 이 함수 자체도 경로 위 방문 집합을 두어 무한 재귀를 만들지 않는다.
    func pathsTo(_ target: Int) -> [[Int]] {
        // target 을 향하는 역방향 인접 리스트를 즉석에서 구성.
        var incoming: [Int: [Int]] = [:]
        for (from, edges) in forwardEdges {
            for edge in edges {
                incoming[edge.destination, default: []].append(from)
            }
        }

        var results: [[Int]] = []
        var onPath = Set<Int>()

        func walk(_ node: Int, path: [Int]) {
            let newPath = [node] + path
            guard let parents = incoming[node], !parents.isEmpty else {
                results.append(newPath)
                return
            }
            onPath.insert(node)
            for parent in parents where !onPath.contains(parent) {
                walk(parent, path: newPath)
            }
            onPath.remove(node)
        }

        walk(target, path: [])
        return results
    }

    /// `target` 이 현재 도감(`dex`) 상태에서 도달 가능한지. 정규 진화는 무조건 순회하지만,
    /// 죠그레스 간선은 **파트너 종이 도감에 졸업 기록으로 있어야만** 통과한다
    /// (GAME-DESIGN.md §3 "죠그레스 — 도감 게이팅": 파트너는 소모되지 않고 기록으로만 인정).
    /// 아머 간선은 디지멘탈 보유 여부를 이 계층이 알지 못하므로 그래프 연결성만 판단한다
    /// (실제 보유 검사는 상위 게임 로직 책임).
    ///
    /// **파트너 판정은 원본 `dex` 가 아니라 누적 도달 집합(`reached`) 기준이다.** 죠그레스 결과도
    /// 도감에 졸업 등록되므로(GAME-DESIGN.md §3), Omegamon(183) 처럼 그 자체가 죠그레스 결과이면서
    /// 상위 죠그레스(Paladin Mode)의 파트너로도 쓰이는 체인이 실제로 있다 — 원본 `dex` 만 보면
    /// 이런 다단 체인이 영구히 막힌다.
    ///
    /// 구현은 "더 늘지 않을 때까지" 반복하는 고정점(fixpoint) 계산이다. 후보 개체 수(48종)가
    /// 작고 `reached` 가 단조 증가만 하므로, 그래프에 순환이 있어도(로드 시점에 이미 거부되지만
    /// 방어적으로) 최대 반복 횟수가 종 수로 유한하게 bound 된다.
    func isReachable(_ target: Int, dex: Set<Int>) -> Bool {
        var reached = dex
        var grew = true
        while grew {
            grew = false
            for node in Array(reached) {   // 스냅샷 순회 — 순회 중 reached 를 직접 mutate 하므로 필요
                for edge in nextStages(from: node) {
                    switch edge {
                    case .normal(let to), .armor(_, let to):
                        if reached.insert(to).inserted { grew = true }
                    case .jogress(let partnerID, let to):
                        // 파트너 종이 "지금까지 도달한" 집합에 있어야만 이 간선을 탈 수 있다.
                        guard reached.contains(partnerID) else { continue }
                        if reached.insert(to).inserted { grew = true }
                    }
                }
            }
        }
        return reached.contains(target)
    }
}

/// 종 id → 진화 다이어그램 라인 키(`Resources/digimon.json` 의 `lines[].key`, 12개) 조회.
/// 다이어그램은 라인별로 분리된 12장이라(EVOLUTION.md 확장 결정), 상세 패널 버튼이 "이 종이
/// 속한 라인"을 알아야 한다 — 도감의 아무 종이나 열 수 있으므로 `lines[].stages` 만으로는
/// 부족하다(52종 중 36종만 커버, 나머지 16종은 죠그레스/아머/chain 결과라 어느 라인에도
/// `stages` 로 속해 있지 않다).
///
/// 다이어그램 각 장이 실제로 어떤 종을 그리는지(diagrams/digivolution.<key>.workflow.json,
/// scratchpad gen_full.py 의 챕터 구성)에 맞춰 정적으로 배정한다 — 그래프 순회로 자동 유도하지
/// 않는 이유: 아머 결과(10종)는 `childID`로 라인이 하나로 정해지지만, 죠그레스/chain 결과
/// (Omegamon/Paildramon/Shakkoumon/Silphymon/Imperialdramon 계열)는 **두 라인이 동시에
/// 관여해 원천적으로 모호하다**(Omegamon 은 agumon·gabumon 라인 양쪽 최종 죠그레스 결과).
/// 이 경우 실제로 다이어그램에 그려 넣은 라인(`lines[]` 배열에서 더 앞선 라인, gen_full.py
/// 챕터 구성과 동일)으로 고정한다. Imperialdramon Paladin Mode(481)는 vmon(Fighter Mode)
/// 체인·agumon/gabumon 죠그레스(Omegamon)를 동시에 부모로 요구해 두 라인에 걸쳐 있지만,
/// vmon 챕터에 대표로 그려 넣었으므로(Omegamon 도 두 번째 부모로 함께 그려짐) vmon 을 배정한다.
enum DigimonLineChapter {
    /// 라인에 직접 속하지 않는 16종의 배정 근거는 위 문서 참고. 아머 결과 10종은 `armor[].childID`
    /// 의 라인, 죠그레스/chain 결과 6종은 다이어그램에 실제로 그려진(대표) 라인을 쓴다.
    private static let nonLineOverrides: [Int: String] = [
        // 죠그레스/chain 결과 — 두 라인 중 다이어그램에 그려 넣은 쪽(= lines[] 배열에서 더 앞선 라인).
        183: "agumon",     // Omegamon: agumon·gabumon 공통 죠그레스 → agumon 챕터가 대표(vmon 에도 두 번째 부모로 그려짐)
        387: "patamon",    // Shakkoumon: patamon·armadimon 공통 죠그레스 → patamon 챕터에 그려짐
        390: "tailmon",    // Silphymon: tailmon·hawkmon 공통 죠그레스 → tailmon 챕터에 그려짐
        331: "vmon",       // Paildramon: vmon·wormmon 공통 죠그레스 → vmon 챕터에 그려짐
        900: "vmon",       // Imperialdramon Dragon Mode: Paildramon 체인 후속 → vmon 챕터에 그려짐
        405: "vmon",       // Imperialdramon Fighter Mode: 위와 동일 체인 → vmon 챕터에 그려짐
        481: "vmon",       // Imperialdramon Paladin Mode: vmon 챕터에 그려짐 — vmon 을 대표로 배정
    ]

    /// 종 id → 라인 키. `dataset.linesByKey` 의 키(12개)와 항상 일치하는 값만 반환한다.
    /// species 테이블에 없는 id 를 넘기면 nil(호출부가 버튼을 숨긴다).
    static func lineKey(for speciesID: Int, dataset: DigimonDataset) -> String? {
        for (key, line) in dataset.linesByKey where line.stages.contains(where: { $0.id == speciesID }) {
            return key
        }
        if let overridden = nonLineOverrides[speciesID] {
            return overridden
        }
        for (armorKey, result) in dataset.armorResults where result == speciesID {
            return lineKey(for: armorKey.childID, dataset: dataset)
        }
        return nil
    }
}
