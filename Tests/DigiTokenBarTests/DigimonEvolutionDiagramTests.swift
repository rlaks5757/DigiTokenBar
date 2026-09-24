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

    // MARK: - (c) 렌더된 HTML 의 컨테이너 포함 관계

    // cae199d 에서 일부 노드 박스 높이만 92→111 로 키우고 그 박스를 감싸는 c-lane 밴드와
    // exception-lane(c-security-group)은 그대로 둬서, 박스 하단이 밴드 밖으로 15px
    // 튀어나간 채로 12장 중 6장이 나갔다. 기존 테스트는 전부 스펙 JSON(노드 목록/브랜드)만
    // 봤고 "렌더된 좌표가 서로 어떤 관계인가"를 보는 단언이 하나도 없어서 green 이었다.
    // 아래 세 가지는 그 기하 관계를 직접 잰다.

    private struct Rect {
        var x, y, width, height: Double
        var bottom: Double { y + height }
        func contains(_ inner: Rect) -> Bool {
            inner.x >= x && inner.y >= y && inner.bottom <= bottom && inner.x + inner.width <= x + width
        }
    }

    private struct DiagramGeometry {
        var lanes: [Rect] = []
        /// exception-lane. 소속 레인을 frame id 로 잇는다("lane-2" ↔ "lane-2-exception").
        var exceptionLanes: [String: Rect] = [:]
        var laneIDs: [String: Rect] = [:]
        /// 노드 박스만. 엣지 라벨 배킹은 제외한다(아래 파싱 주석 참고).
        var nodeBoxes: [Rect] = []
        var legendTitle: (y: Double, fontSize: Double)?
    }

    private func lineDiagramHTMLURL(_ lineKey: String) -> URL {
        repoRootURL().appendingPathComponent("Resources/digivolution.\(lineKey).html")
    }

    /// 렌더된 SVG 에서 기하만 뽑는다.
    ///
    /// 노드 박스 판별이 까다롭다: `c-mask` 클래스는 **두 가지**에 쓰인다 — 노드 박스와,
    /// 엣지에 붙는 라벨의 불투명 배킹(height 14). 배킹은 레인 밖으로 나가는 엣지에 붙어
    /// 있어서 레인 안에 있지 않다(예: tailmon 에 y=16, y=474 짜리가 있다). 그래서
    /// `c-mask` 를 전부 노드 박스로 치면 손대면 안 되는 6장에서도 빨개진다.
    /// 판별 기준: 노드 박스는 바로 뒤에 **동일 x/y/width/height 의 색상 rect 쌍둥이**가
    /// 따라온다(마스크 + 채색 2겹). 배킹은 쌍둥이 없이 `<text>` 가 따라온다.
    /// `[data-node-id]` 로 세면 안 된다 — 숨겨진 중복 때문에 실제의 2배가 나온다.
    private func parseDiagramGeometry(_ html: String) throws -> DiagramGeometry {
        var geo = DiagramGeometry()

        func attributes(_ tag: String) -> [String: String] {
            var out: [String: String] = [:]
            let pattern = try! NSRegularExpression(pattern: "([\\w-]+)=\"([^\"]*)\"")
            let ns = tag as NSString
            for m in pattern.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
                out[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
            }
            return out
        }

        func rect(_ a: [String: String]) -> Rect? {
            guard let x = Double(a["x"] ?? ""), let y = Double(a["y"] ?? ""),
                  let w = Double(a["width"] ?? ""), let h = Double(a["height"] ?? "")
            else { return nil }
            return Rect(x: x, y: y, width: w, height: h)
        }

        let ns = html as NSString
        let rectRE = try NSRegularExpression(pattern: "<rect\\b[^>]*>")
        let rectTags: [(attrs: [String: String], rect: Rect?)] = rectRE
            .matches(in: html, range: NSRange(location: 0, length: ns.length))
            .map { m in
                let a = attributes(ns.substring(with: m.range))
                return (a, rect(a))
            }

        for (index, entry) in rectTags.enumerated() {
            guard let r = entry.rect else { continue }
            let classes = Set((entry.attrs["class"] ?? "").split(separator: " ").map(String.init))
            let frameID = entry.attrs["data-composition-frame-id"]

            if classes.contains("c-lane") {
                geo.lanes.append(r)
                if let frameID { geo.laneIDs[frameID] = r }
            }
            if classes.contains("c-security-group") {
                if let frameID { geo.exceptionLanes[frameID] = r }
            }
            if classes.contains("c-mask") {
                // 쌍둥이(다음 rect 가 같은 기하 + 다른 클래스)가 있으면 노드 박스.
                if index + 1 < rectTags.count, let twin = rectTags[index + 1].rect,
                   twin.x == r.x, twin.y == r.y, twin.width == r.width, twin.height == r.height,
                   !Set((rectTags[index + 1].attrs["class"] ?? "").split(separator: " ").map(String.init))
                        .contains("c-mask") {
                    geo.nodeBoxes.append(r)
                }
            }
        }

        let titleRE = try NSRegularExpression(pattern: "<text\\b[^>]*>Legend</text>")
        if let m = titleRE.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) {
            let a = attributes(ns.substring(with: m.range))
            if let y = Double(a["y"] ?? "") {
                geo.legendTitle = (y: y, fontSize: Double(a["font-size"] ?? "") ?? 12)
            }
        }
        return geo
    }

    private func allLineGeometries() throws -> [(key: String, geo: DiagramGeometry)] {
        let ds = try DigimonData.loaded()
        // 12개 라인 키로만 연다. Resources/ 엔 visual-check 산출물과 통합본
        // digivolution.html 도 같이 있어서 glob 으로 쓸어담으면 범위 밖 파일까지 들어온다.
        XCTAssertEqual(ds.linesByKey.count, 12, "라인 수가 12가 아님 — 이 테스트의 전제가 깨짐")
        return try ds.linesByKey.keys.sorted().map { key in
            let url = lineDiagramHTMLURL(key)
            let html = try String(contentsOf: url, encoding: .utf8)
            return (key, try parseDiagramGeometry(html))
        }
    }

    /// 모든 노드 박스는 자기 레인 밴드 안에 들어있어야 한다.
    /// 박스 높이만 키우고 밴드를 안 키우면(cae199d) 여기서 잡힌다.
    func testNodeBoxesStayInsideTheirLaneBand() throws {
        var totalBoxes = 0
        for (key, geo) in try allLineGeometries() {
            XCTAssertFalse(geo.lanes.isEmpty, "'\(key)' 에 c-lane 이 하나도 없음 — 파싱이 깨진 것")
            XCTAssertFalse(geo.nodeBoxes.isEmpty, "'\(key)' 에 노드 박스가 하나도 없음 — 파싱이 깨진 것")
            totalBoxes += geo.nodeBoxes.count
            for box in geo.nodeBoxes {
                let owner = geo.lanes.first { $0.contains(box) }
                XCTAssertNotNil(owner,
                    "'\(key)': 노드 박스(y=\(box.y), h=\(box.height), 하단 \(box.bottom))가 "
                    + "어느 레인 밴드에도 담기지 않음. 레인: "
                    + geo.lanes.map { "y=\($0.y) h=\($0.height)" }.joined(separator: ", "))
            }
        }
        // 필터가 조용히 비어버리면(쌍둥이 판별이 깨지면) 위 루프가 공허하게 통과한다.
        XCTAssertEqual(totalBoxes, 77, "12장의 노드 박스 총수가 달라짐 — 파싱 필터나 다이어그램 구성이 변경됨")
    }

    /// exception-lane(c-security-group)은 자기 레인에서 상하 6px 씩 안쪽으로 파생된다.
    ///
    /// 여기서 "그룹이 박스를 포함한다"를 단언하지 않는 건, 그게 **기준선에서 이미 거짓**이기
    /// 때문이다: 박스는 레인 y+34 에서 높이 92 라 하단이 y+126 인데, 그룹 하단은 y+124 다
    /// (12장 전부, 손대지 않은 6장 포함). 즉 노드 박스는 원래 exception-lane 을 2px 넘친다.
    /// 실제로 깨진 불변식은 포함 관계가 아니라 **파생 관계**다 — cae199d 는 레인만 놔두고
    /// 박스를 키웠고, 레인을 고칠 때 그룹을 같이 안 고치면 이 단언이 빨개진다.
    func testExceptionLaneIsDerivedFromItsLane() throws {
        var checked = 0
        for (key, geo) in try allLineGeometries() {
            for (groupID, group) in geo.exceptionLanes {
                let laneID = groupID.replacingOccurrences(of: "-exception", with: "")
                let lane = try XCTUnwrap(geo.laneIDs[laneID],
                    "'\(key)': exception-lane '\(groupID)' 에 대응하는 레인 '\(laneID)' 없음")
                XCTAssertEqual(group.y, lane.y + 6, accuracy: 0.001,
                    "'\(key)': '\(groupID)' 의 y 가 레인 y+6 이 아님")
                XCTAssertEqual(group.height, lane.height - 12, accuracy: 0.001,
                    "'\(key)': '\(groupID)' 높이가 레인 높이-12 가 아님 "
                    + "(레인 \(lane.height) → 기대 \(lane.height - 12), 실제 \(group.height)). "
                    + "레인만 키우고 exception-lane 을 안 키운 것")
                checked += 1
            }
        }
        XCTAssertEqual(checked, 13, "exception-lane 총수가 달라짐 — 다이어그램 구성이 변경됨")
    }

    /// 노드 박스가 Legend 제목 글자 영역을 침범하면 안 된다.
    /// 제목의 baseline 이 아니라 **글자 상단**(baseline - font-size)과 비교한다 —
    /// baseline 으로 재면 기준선에서도 여유가 9px 나 있어서 회귀를 못 잡는다.
    func testNodeBoxesDoNotOverlapLegendTitle() throws {
        for (key, geo) in try allLineGeometries() {
            let title = try XCTUnwrap(geo.legendTitle, "'\(key)' 에 Legend 제목이 없음")
            let titleTop = title.y - title.fontSize
            for box in geo.nodeBoxes where box.bottom > titleTop {
                XCTFail("'\(key)': 노드 박스 하단(\(box.bottom))이 Legend 제목 상단"
                    + "(\(titleTop) = baseline \(title.y) - \(title.fontSize))을 침범함")
            }
        }
    }

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
