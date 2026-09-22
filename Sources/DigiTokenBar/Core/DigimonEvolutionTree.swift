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
