import XCTest
@testable import DigiTokenBar

// 진화 다이어그램(라인별 12장) 대조 테스트. 이 저장소엔 서로 대조 안 되는 enum 두 개가
// 있어서 누락이 green 으로 통과한 전례가 있다(디지멘탈 enum 분리 사건) — 같은 함정을
// 다이어그램 쪽에도 만들지 않기 위해 "생성된 산출물 ↔ 앱 소스 진실" 을 직접 비교한다.

final class DigimonEvolutionDiagramTests: XCTestCase {

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DigiTokenBarTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // 저장소 루트
    }

    private func diagramSpecURL(_ lineKey: String) -> URL {
        repoRootURL().appendingPathComponent("diagrams/digivolution.\(lineKey).workflow.json")
    }

    // MARK: - (a) 하드코딩된 라인 키 목록 ↔ lines[].key

    /// `DigimonData.lines` 가 아는 12개 라인 키 전부에 대해 다이어그램 스펙 파일이 실제로
    /// 존재해야 한다 — 라인이 추가/삭제됐는데 다이어그램 생성을 안 돌리면 여기서 잡힌다.
    func testEveryLineHasADiagramSpecFile() throws {
        let ds = try DigimonData.loaded()
        XCTAssertEqual(ds.linesByKey.count, 12, "라인 수가 12가 아님 — 이 테스트의 전제가 깨짐")
        for key in ds.linesByKey.keys {
            let url = diagramSpecURL(key)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                "라인 '\(key)' 의 다이어그램 스펙(\(url.lastPathComponent))이 없음")
        }
    }

    /// **회귀 가드 핵심**: 도감에 존재하는 52종 전부가 `DigimonLineChapter.lineKey(for:)` 로
    /// 라인 키를 얻을 수 있어야 한다(totality). `lines[].stages` 만으로는 52종 중 36종만
    /// 커버되므로(나머지 16종은 죠그레스/아머/chain 결과), 이 테스트가 없으면 그 16종은
    /// 상세 패널에서 버튼이 조용히 사라진다 — 에러도 로그도 없이.
    ///
    /// 이 단언은 "챕터에 그 종이 실제로 그려져 있는지"는 보지 않는다(별도 테스트가 그건
    /// 확인한다) — `lineKey`가 반환하는 대표 라인과 실제로 그려지는 챕터가 다른 경우가
    /// 있어서(예: Omegamon(183)은 agumon 이 대표 라인이지만 vmon 챕터에도 두 번째
    /// 부모로 그려짐), 두 검사를 하나로 합치지 않는다.
    func testEverySpeciesResolvesToALineKey() throws {
        let ds = try DigimonData.loaded()
        let validKeys = Set(ds.linesByKey.keys)
        for speciesID in ds.names.keys {
            let resolved = DigimonLineChapter.lineKey(for: speciesID, dataset: ds)
            XCTAssertNotNil(resolved, "종 id \(speciesID) 가 어떤 라인 키로도 resolve 되지 않음")
            if let resolved {
                XCTAssertTrue(validKeys.contains(resolved),
                    "종 id \(speciesID) 가 존재하지 않는 라인 키 '\(resolved)' 로 resolve 됨")
            }
        }
    }

    /// 챕터 멤버십(52/52, 예외 없음)은 totality 와 별개로 확인한다 — 위 테스트 문서 참고.
    /// 각 다이어그램 스펙에 실제로 그려진 species id 노드 집합의 합집합이 species 테이블
    /// 전체와 정확히 일치해야 한다. Imperialdramon Paladin Mode(481)는 vmon 챕터에 그 두
    /// 부모(impfighter, omegamon)와 함께 그려져 있어 더 이상 예외가 아니다.
    func testDiagramChaptersCoverAllSpecies() throws {
        let ds = try DigimonData.loaded()
        var covered = Set<Int>()
        for key in ds.linesByKey.keys {
            let spec = try loadDiagramSpec(key)
            covered.formUnion(spec.speciesNodeIDs)
        }
        let allSpecies = Set(ds.names.keys)
        XCTAssertEqual(allSpecies.subtracting(covered), [],
            "다이어그램 12장이 커버하지 못하는 종이 생김 — 52종 전부가 어느 챕터엔가 그려져야 함")
    }

    // MARK: - (b) 다이어그램 스펙의 디지멘탈 파일명 ↔ Digimental.wikimonFilename 9종

    /// 다이어그램에 등장하는 모든 디지멘탈 아이템 노드의 brand URL 이 실제로
    /// `Digimental.wikimonFilename`(앱이 상점 화면에서 쓰는, 검증된 파일명) 을 참조해야 한다.
    /// 파일명을 지어내거나 규칙으로 일반화하면(예: sincerity → "Digimental_sincerity.jpg")
    /// 여기서 실패한다 — sincerity 는 실제로 "Digimental_reliability.jpg" 다.
    func testDiagramDigimentalBrandsMatchAppWikimonFilenames() throws {
        let ds = try DigimonData.loaded()
        var foundDigimentals = Set<Digimental>()
        for key in ds.linesByKey.keys {
            let spec = try loadDiagramSpec(key)
            for node in spec.digimentalItemNodes {
                guard let digimental = Digimental.allCases.first(where: { node.brandURL.contains($0.wikimonFilename) }) else {
                    XCTFail("다이어그램 '\(key)' 의 아이템 노드 '\(node.id)' brand URL 이 어떤 Digimental.wikimonFilename 과도 안 맞음: \(node.brandURL)")
                    continue
                }
                foundDigimentals.insert(digimental)
            }
        }
        // 앱이 실제로 아머 진화에 쓰는 디지멘탈만 다이어그램에 나온다(9종 전부가 armor[] 에
        // 있음 — Resources/digimon.json 의 armor 배열 참고). 9종 전부 실제로 그려졌는지도 함께 확인.
        XCTAssertEqual(foundDigimentals, Set(Digimental.allCases),
            "다이어그램에 그려진 디지멘탈 집합이 Digimental.allCases(9종)와 다름")
    }

    // MARK: - 스펙 파일 파싱 헬퍼 (archify workflow schema 의 최소 부분집합만 읽는다)

    private struct DiagramSpec {
        struct Node {
            let id: String
            let brandURL: String
        }
        let speciesNodeIDs: Set<Int>
        let digimentalItemNodes: [Node]
    }

    /// node-id(디이그램 내부 슬러그) → digi-api species id. 생성 스크립트(gen_full.py)의
    /// NODE_TO_ID 와 동일한 테이블 — 스펙 JSON 자체엔 species id 가 없고 라벨/브랜드만 있어서,
    /// "이 노드가 어떤 종인가"는 이 테이블로만 알 수 있다(생성 스크립트와 이 매핑이 어긋나면
    /// 위 커버리지 테스트가 잡는다: 어긋나면 합집합이 52-{481} 과 달라진다).
    private static let nodeToSpeciesID: [String: Int] = [
        "agumon":1,"greymon":34,"metalgreymon":169,"wargreymon":202,
        "gabumon":16,"garurumon":33,"weregarurumon":205,"metalgarurumon":168,
        "piyomon":101,"birdramon":5,"garudamon":165,
        "tentomon":85,"kabuterimon":35,"atlurkabuterimon":40,
        "palmon":81,"togemon":195,"lilimon":166,
        "gomamon":117,"ikkakumon":124,"zudomon":96,
        "patamon":98,"angemon":3,"holyangemon":121,"seraphimon":384,
        "tailmon":83,"angewomon":38,"holydramon":123,
        "vmon":349,"xvmon":358,
        "wormmon":356,"stingmon":336,
        "hawkmon":399,"aquilamon":267,
        "armadimon":271,"ankylomon":266,
        "paildramon":331,"silphymon":390,"shakkoumon":387,"omegamon":183,
        "impdragon":900,"impfighter":405,"imppaladin":481,
        "fladramon":305,"depthmon":298,"magnamon":315,"lighdramon":312,
        "holsmon":401,"shurimon":389,
        "digmon":299,"submarimon":337,
        "pegasmon":363,
        "nefertimon":326,
    ]

    private func loadDiagramSpec(_ lineKey: String) throws -> DiagramSpec {
        let url = diagramSpecURL(lineKey)
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodes = json["nodes"] as? [[String: Any]]
        else {
            XCTFail("스펙 '\(lineKey)' 파싱 실패")
            return DiagramSpec(speciesNodeIDs: [], digimentalItemNodes: [])
        }

        var speciesIDs = Set<Int>()
        var itemNodes: [DiagramSpec.Node] = []
        for node in nodes {
            guard let nodeID = node["id"] as? String else { continue }
            if nodeID.hasPrefix("digimental") {
                if let brand = node["brand"] as? [String: Any], let url = brand["url"] as? String {
                    itemNodes.append(DiagramSpec.Node(id: nodeID, brandURL: url))
                }
            } else if let speciesID = Self.nodeToSpeciesID[nodeID] {
                speciesIDs.insert(speciesID)
            }
        }
        return DiagramSpec(speciesNodeIDs: speciesIDs, digimentalItemNodes: itemNodes)
    }
}
