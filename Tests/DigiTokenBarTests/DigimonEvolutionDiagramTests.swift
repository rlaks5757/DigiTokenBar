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

    // MARK: - (d) 죠그레스 엣지 ↔ digimon.json jogress 배열

    /// 가트몬 라인 차트가 실피드몬(390) 의 죠그레스 파트너를 호크몬(399)으로 그린 채로
    /// 노드 커버리지 테스트를 통과한 전례가 있다(정답은 가트몬(83)+아큐라몬(267)) — 호크몬이
    /// hawkmon 챕터에 정당하게 존재해서 노드 집합 합집합이 안 깨졌기 때문이다. 이 테스트는
    /// 노드가 아니라 **엣지 끝점**을 데이터셋과 대조해 같은 함정을 잡는다.
    func testJogressEdgesMatchDataset() throws {
        let ds = try DigimonData.loaded()
        // Set 비교라 a/b 순서는 안 본다(JogressKey 와 동일한 정규화).
        let datasetTriples = Set(ds.jogressResults.map { key, result in
            Set(key.speciesIDs + [result])
        })

        var totalEdges = 0
        // (라인 키, 결과 노드 id) 별로 부모 노드 id 를 모은다.
        var groups: [String: [String: [String]]] = [:]
        for key in ds.linesByKey.keys {
            let spec = try loadDiagramSpec(key)
            for edge in spec.jogressEdges {
                totalEdges += 1
                groups[key, default: [:]][edge.to, default: []].append(edge.from)
            }
        }

        for (lineKey, resultGroups) in groups {
            for (resultNodeID, parentNodeIDs) in resultGroups {
                guard let resultSpeciesID = Self.nodeToSpeciesID[resultNodeID] else {
                    XCTFail("'\(lineKey)': 죠그레스 결과 노드 '\(resultNodeID)' 가 nodeToSpeciesID 에 없음")
                    continue
                }
                XCTAssertEqual(parentNodeIDs.count, 2,
                    "'\(lineKey)': 죠그레스 결과 '\(resultNodeID)'(species \(resultSpeciesID))의 부모가 "
                    + "2개가 아니라 \(parentNodeIDs.count)개(\(parentNodeIDs)) — 부모 한쪽이 누락됐을 수 있음")

                let parentSpeciesIDs = parentNodeIDs.compactMap { Self.nodeToSpeciesID[$0] }
                XCTAssertEqual(parentSpeciesIDs.count, parentNodeIDs.count,
                    "'\(lineKey)': 죠그레스 결과 '\(resultNodeID)' 의 부모 노드 중 nodeToSpeciesID 에 없는 것이 있음: \(parentNodeIDs)")

                let triple = Set(parentSpeciesIDs + [resultSpeciesID])
                XCTAssertTrue(datasetTriples.contains(triple),
                    "'\(lineKey)': 차트가 그린 죠그레스 (부모 \(parentNodeIDs)=\(parentSpeciesIDs), 결과 \(resultNodeID)=\(resultSpeciesID)) "
                    + "가 digimon.json 의 jogress 배열에 없음 — 기대 삼중항 \(triple)")
            }
        }

        // 12장 전체를 순회했는지 자체를 확인한다 — 파싱이나 라벨 필터가 조용히 비면
        // 위 루프가 공허하게 통과한다.
        XCTAssertEqual(totalEdges, 18, "12장의 '죠그레스' 라벨 엣지 총수가 달라짐 — 다이어그램 구성이 변경됨")
        let totalGroups = groups.values.reduce(0) { $0 + $1.count }
        XCTAssertEqual(totalGroups, 9, "12장의 죠그레스 결과 노드(라인별) 총수가 달라짐 — 다이어그램 구성이 변경됨")
    }

    // MARK: - (e) 노드 라벨 ↔ 데이터셋 이름

    /// 노드 라벨이 실제로 그 종의 이름을 가리키는지 대조한다. 한글 라벨은 `names.ko`, 라틴
    /// 라벨은 `apiName` 과 비교한다(다른 에이전트가 라틴→한글 치환을 병행 중이라 어느 쪽이든
    /// 허용한다). 라틴 쪽은 공백/하이픈 표기가 다를 수 있어 정규화 후 비교한다.
    ///
    /// 데이터셋 이름에 변형 표시(`:` 또는 `(...)`)가 붙는 종은 차트가 그 부분을 별도
    /// sublabel 행에 두므로, 대조는 **변형 표시를 떼어낸 기본 이름**(`baseName`)과 완전
    /// 일치로 한다(예: "황제드라몬: 파이터 모드" → "황제드라몬", "Atlur Kabuterimon (Blue)"
    /// → "Atlur Kabuterimon"). 접두 일치를 직접 허용하면 라벨이 잘려도(예: "가트몬"→"가트",
    /// "Atlur Kabuterimon"→"Atlur") 통과해버려서 회귀 가드가 무의미해진다 — `baseName` 으로
    /// 자른 뒤 완전 일치만 요구해 이 구멍을 막는다. 변형 표시가 없는 종은 애초에
    /// `baseName(x) == x` 라 규칙이 하나로 통일된다.
    func testNodeLabelsMatchDatasetNames() throws {
        let ds = try DigimonData.loaded()
        var totalLabeled = 0
        for key in ds.linesByKey.keys {
            let spec = try loadDiagramSpec(key)
            for node in spec.labeledNodes {
                totalLabeled += 1
                assertLabelMatchesDatasetName(node.label, speciesID: node.speciesID, dataset: ds,
                    context: "'\(key)': 노드 '\(node.id)'(species \(node.speciesID))")
            }
        }
        XCTAssertEqual(totalLabeled, 67, "12장의 라벨 붙은 species 노드 총수가 달라짐 — 다이어그램 구성이 변경됨")
    }

    /// 변형 표시(`:` 또는 `(`) 앞부분만 남기고 양끝 공백을 뗀다.
    private func baseName(_ s: String) -> String {
        String(s.prefix { $0 != ":" && $0 != "(" }).trimmingCharacters(in: .whitespaces)
    }
    private func normalizeLatin(_ s: String) -> String {
        s.filter { !$0.isWhitespace && $0 != "-" }.lowercased()
    }
    private func isHangul(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
    }

    /// `testNodeLabelsMatchDatasetNames` 와 `testCombinedDiagramNodeLabelsMatchDatasetNames` 가
    /// 공유하는 판정 본체. 한글 라벨은 `names.ko`, 라틴 라벨은 `apiName` 과 비교한다. `baseName`
    /// 은 **데이터셋 쪽에만** 적용한다 — 라벨에도 적용하면 "아트라캅테리몬(적)" 같은 오답 변형이
    /// "아트라캅테리몬" 으로 잘려 기본형과 맞아버린다.
    private func assertLabelMatchesDatasetName(_ label: String, speciesID: Int, dataset ds: DigimonDataset, context: String) {
        guard let name = ds.names[speciesID] else {
            XCTFail("\(context) species \(speciesID) 가 데이터셋에 없음")
            return
        }
        if isHangul(label) {
            guard let ko = name.localeNames["ko"] else {
                XCTFail("\(context) 라벨 '\(label)' 이 한글인데 데이터셋에 names.ko 가 없음")
                return
            }
            XCTAssertTrue(label == ko || label == baseName(ko),
                "\(context) 한글 라벨 '\(label)' 이 names.ko '\(ko)'(전체형/기본형 어느 쪽과도) 안 맞음")
        } else {
            let api = name.apiName
            let normLabel = normalizeLatin(label)
            XCTAssertTrue(normLabel == normalizeLatin(api) || normLabel == normalizeLatin(baseName(api)),
                "\(context) 라틴 라벨 '\(label)' 이 apiName '\(api)'(전체형/기본형 어느 쪽과도, 정규화 후) 안 맞음")
        }
    }

    // MARK: - 스펙 파일 파싱 헬퍼 (archify workflow schema 의 최소 부분집합만 읽는다)

    private struct DiagramSpec {
        struct Node {
            let id: String
            let brandURL: String
        }
        /// label == "죠그레스" 인 엣지 하나. `to` 가 결과 종의 노드 id, `from` 이 부모 한쪽.
        struct JogressEdge {
            let from: String
            let to: String
        }
        /// 라벨 대조용 — digimental_* 을 제외한 모든 species 노드.
        struct LabeledNode {
            let id: String
            let speciesID: Int
            let label: String
            /// JSON `sublabel` 필드값(없으면 nil — 대다수 노드는 없다).
            let sublabel: String?
        }
        let speciesNodeIDs: Set<Int>
        let digimentalItemNodes: [Node]
        let jogressEdges: [JogressEdge]
        let labeledNodes: [LabeledNode]
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

    // MARK: - (f) 렌더된 HTML ↔ 스펙 JSON 드리프트(라벨 화면 표시 + 죠그레스 엣지)

    // JSON 스펙이 맞아도 HTML 은 손으로 편집될 수 있어("차트는 후처리 산출물" 이지만 그 후
    // 산출물 자체가 수정 대상이 됨) 둘이 갈라질 수 있다 — 실제로 샌 결함이 JSON 과 HTML
    // 양쪽에 있었다. `parseDiagramGeometry` 와 마찬가지로 중첩 `<g>` 때문에 비탐욕 정규식으로
    // 노드 블록을 자르면 안쪽 `semantic-sigil` `<g>` 의 `</g>` 에서 멈춰 `t-primary` 텍스트를
    // 놓친다 — 태그 깊이를 세는 균형 파서를 쓴다.

    private struct HTMLDiagramSpec {
        struct LabeledNode {
            let id: String
            /// 여는 `<g id="node-X">` 태그의 `data-node-label` 속성값.
            let attrLabel: String
            /// 블록 안 `class="t-primary"` `<text>` 의 화면 표시 텍스트(trim 됨).
            let visibleLabel: String
            /// 여는 태그의 `data-node-sublabel` 속성값. 부 라벨 층 대조용(모든 노드에 값이
            /// 있는 건 아니다 — 없으면 nil).
            let attrSublabel: String?
            /// 블록 안 `class="t-muted"` `<text>` 의 화면 표시 텍스트(trim 됨, 없으면 nil).
            let visibleSublabel: String?
            /// 블록 안 `<title>` 전체 텍스트.
            let title: String?
            /// 여는 태그의 `aria-label` 속성값.
            let ariaLabel: String?
        }
        struct JogressEdge {
            let from: String
            let to: String
        }
        let speciesNodeIDs: Set<String>
        let labeledNodes: [LabeledNode]
        let jogressEdges: [JogressEdge]
    }

    /// 렌더된 HTML 에서 노드 라벨(속성 + 화면 텍스트)과 죠그레스 엣지 끝점을 뽑는다.
    ///
    /// - 노드 블록 경계: `<g id="node-…">` 여는 태그부터, `<g>`/`</g>` 태그 깊이가 그 시작
    ///   깊이로 되돌아오는 지점까지(균형 파싱). 비탐욕 정규식 `<g …>[^]*?</g>` 을 쓰면
    ///   노드 안의 `semantic-sigil` 중첩 `<g>` 의 `</g>` 에서 멈춰 `t-primary` 텍스트가
    ///   블록 밖으로 밀려난다.
    /// - `data-node-label` 은 파일 전체에 노드당 **두 번** 나온다(여는 `<g>` 태그와, 그 안의
    ///   `<text>` — `<text>` 쪽은 항상 빈 문자열이다). 여는 `<g>` 태그에서만 뽑는다.
    /// - 엣지 속성(`data-edge-from`/`to`/`label`/`id`)도 파일에 **두 번**(`<path>` 와
    ///   `<g data-detail="context">`) 나온다. 여는 태그 하나 단위로 매칭해 같은 id 의
    ///   두 occurrence 가 서로 일치하는지 확인한 뒤 하나로 합친다 — 반쪽만 고친 수동 편집을
    ///   여기서 잡는다.
    private func parseHTMLDiagramSpec(_ html: String) throws -> HTMLDiagramSpec {
        func attributes(_ tag: String) -> [String: String] {
            var out: [String: String] = [:]
            let pattern = try! NSRegularExpression(pattern: "([\\w-]+)=\"([^\"]*)\"")
            let ns = tag as NSString
            for m in pattern.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
                out[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
            }
            return out
        }

        let ns = html as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        // 1) 노드 블록: <g id="node-…"> 여는 태그부터 균형 잡힌 </g> 까지.
        let gTagRE = try NSRegularExpression(pattern: "<g\\b[^>]*>|</g>")
        let gTokens = gTagRE.matches(in: html, range: fullRange).map { m in
            (text: ns.substring(with: m.range), range: m.range)
        }

        var nodeBlocks: [(id: String, attrLabel: String, attrSublabel: String?, ariaLabel: String?, body: String)] = []
        var depth = 0
        var openNodeStack: [(id: String, attrLabel: String, attrSublabel: String?, ariaLabel: String?, startDepth: Int, bodyStart: Int)] = []
        for token in gTokens {
            if token.text == "</g>" {
                depth -= 1
                if let top = openNodeStack.last, top.startDepth == depth {
                    openNodeStack.removeLast()
                    let body = ns.substring(with: NSRange(
                        location: top.bodyStart, length: token.range.location - top.bodyStart))
                    nodeBlocks.append((id: top.id, attrLabel: top.attrLabel, attrSublabel: top.attrSublabel,
                        ariaLabel: top.ariaLabel, body: body))
                }
            } else {
                let attrs = attributes(token.text)
                if let gid = attrs["id"], gid.hasPrefix("node-"), let nodeID = attrs["data-node-id"] {
                    openNodeStack.append((id: nodeID, attrLabel: attrs["data-node-label"] ?? "",
                        attrSublabel: attrs["data-node-sublabel"], ariaLabel: attrs["aria-label"],
                        startDepth: depth, bodyStart: token.range.location + token.range.length))
                }
                depth += 1
            }
        }
        XCTAssertTrue(openNodeStack.isEmpty, "균형 파서가 닫히지 않은 <g id=\"node-…\"> 블록을 남김 — 파싱 버그")

        // 긍정 대조: 여는 <g id="node-…"> 태그 수와 뽑아낸 블록 수가 같아야 한다(균형 파서가
        // 깨지면 일부만 닫혀 조용히 줄어들 수 있다).
        let rawNodeOpenCount = try NSRegularExpression(pattern: "<g id=\"node-")
            .numberOfMatches(in: html, range: fullRange)
        XCTAssertEqual(nodeBlocks.count, rawNodeOpenCount,
            "노드 블록 파싱 개수(\(nodeBlocks.count))가 원시 <g id=\"node-…\"> 개수(\(rawNodeOpenCount))와 다름")

        var speciesIDs = Set<String>()
        var labeledNodes: [HTMLDiagramSpec.LabeledNode] = []
        let primaryTextRE = try NSRegularExpression(pattern: "<text\\b[^>]*class=\"t-primary\"[^>]*>([^<]*)</text>")
        // t-muted 와 <title> 은 부 라벨 층 대조용으로만 쓴다(testSublabel… 계열). t-primary 와
        // 달리 개수를 강제하지 않는다 — sublabel 이 없는 노드(대다수)는 t-muted 가 0개일 수
        // 있어서, 여기서 count==1 을 요구하면 기존 통과 테스트(`testHTMLNodeLabelsMatchDiagramSpecJSON`
        // 등)가 새로 깨진다.
        let mutedTextRE = try NSRegularExpression(pattern: "<text\\b[^>]*class=\"t-muted\"[^>]*>([^<]*)</text>")
        let titleRE = try NSRegularExpression(pattern: "<title>([^<]*)</title>")
        for block in nodeBlocks {
            if block.id.hasPrefix("digimental") { continue }
            speciesIDs.insert(block.id)
            let bodyNS = block.body as NSString
            let matches = primaryTextRE.matches(in: block.body, range: NSRange(location: 0, length: bodyNS.length))
            XCTAssertEqual(matches.count, 1,
                "노드 '\(block.id)' 블록에 t-primary 텍스트가 정확히 1개가 아니라 \(matches.count)개")
            guard let m = matches.first else { continue }
            let visible = bodyNS.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let mutedMatch = mutedTextRE.firstMatch(in: block.body, range: NSRange(location: 0, length: bodyNS.length))
            let visibleSublabel = mutedMatch.map {
                bodyNS.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let titleMatch = titleRE.firstMatch(in: block.body, range: NSRange(location: 0, length: bodyNS.length))
            let title = titleMatch.map { bodyNS.substring(with: $0.range(at: 1)) }
            labeledNodes.append(HTMLDiagramSpec.LabeledNode(id: block.id, attrLabel: block.attrLabel, visibleLabel: visible,
                attrSublabel: block.attrSublabel, visibleSublabel: visibleSublabel, title: title, ariaLabel: block.ariaLabel))
        }

        // 2) 죠그레스 엣지: 여는 태그 하나 단위로 매칭(전방 N자 윈도우 금지 — 다음 엣지 속성과
        // 섞인다). id 별로 동일 occurrence 대조 후 하나로 합친다.
        let edgeTagRE = try NSRegularExpression(pattern: "<(?:path|g)\\b[^>]*data-edge-id=\"[^\"]*\"[^>]*>")
        var edgesByID: [String: (from: String, to: String, label: String)] = [:]
        for m in edgeTagRE.matches(in: html, range: fullRange) {
            let attrs = attributes(ns.substring(with: m.range))
            guard let id = attrs["data-edge-id"], let from = attrs["data-edge-from"],
                  let to = attrs["data-edge-to"], let label = attrs["data-edge-label"]
            else { continue }
            if let existing = edgesByID[id] {
                let matches = existing.from == from && existing.to == to && existing.label == label
                XCTAssertTrue(matches,
                    "엣지 '\(id)' 의 반복 occurrence 끼리 속성이 다름(반쪽만 손으로 고친 경우 의심): "
                    + "\(existing) vs (\(from), \(to), \(label))")
            } else {
                edgesByID[id] = (from, to, label)
            }
        }
        let jogressEdges = edgesByID.values.filter { $0.label == "죠그레스" }.map {
            HTMLDiagramSpec.JogressEdge(from: $0.from, to: $0.to)
        }

        return HTMLDiagramSpec(speciesNodeIDs: speciesIDs, labeledNodes: labeledNodes, jogressEdges: jogressEdges)
    }

    /// 라인별 12장 전부의 (라인 키, HTML 스펙, 짝 JSON 스펙)을 반환한다.
    ///
    /// **통합 1장의 HTML(`Resources/digivolution.html`)은 의도적으로 뺀다.** `.gitignore:37`
    /// 이 이 파일을 명시적으로 제외한다 — "브라우저 열람 전용 산출물, 앱은 이 파일을 쓰지
    /// 않는다"(주석 인용), `scratchpad/gen_full.py` 로 재생성. 커밋된 트리에 없으므로
    /// CI·클린 체크아웃에서 항상 파일 없음으로 죽는다.
    ///
    /// 통합 1장의 **JSON 쪽**(`diagrams/digivolution.workflow.json`)은 이 제외 근거가 적용되지
    /// 않는다 — git 추적 파일이라 CI/클린 체크아웃에도 항상 존재한다. HTML 과 추적 상태가
    /// 다르므로 분리해서 다룬다: JSON 쪽은
    /// `testCombinedDiagramNodeLabelsMatchDatasetNames`/`testCombinedDiagramJogressEdgesMatchDataset`/
    /// `testCombinedDiagramLabelsMatchLineDiagrams` 가 별도로 커버한다.
    private func allHTMLAndJSONSpecPairs() throws -> [(fileKey: String, html: HTMLDiagramSpec, json: DiagramSpec)] {
        let ds = try DigimonData.loaded()
        XCTAssertEqual(ds.linesByKey.count, 12, "라인 수가 12가 아님 — 이 테스트의 전제가 깨짐")
        return try ds.linesByKey.keys.sorted().map { key in
            let html = try String(contentsOf: lineDiagramHTMLURL(key), encoding: .utf8)
            return (key, try parseHTMLDiagramSpec(html), try loadDiagramSpec(key))
        }
    }

    /// 노드 라벨(속성 + 화면 텍스트)이 JSON 스펙과 일치하는지, species 노드 집합이 같은지
    /// 대조한다. 언어(한글/라틴) 분기를 두지 않는다 — HTML 과 JSON 은 같은 생성 파이프라인의
    /// 산출물이라 항상 같은 언어여야 하고, JSON↔데이터셋 일치는 `testNodeLabelsMatchDatasetNames`
    /// 가 이미 보장하므로 여기선 HTML↔JSON 만 보면 HTML↔데이터셋도 추이적으로 성립한다.
    func testHTMLNodeLabelsMatchDiagramSpecJSON() throws {
        var totalCompared = 0
        for (fileKey, html, json) in try allHTMLAndJSONSpecPairs() {
            // uniqueKeysWithValues 는 중복 노드 id 가 있으면 런타임 트랩을 낸다(메시지 없이 크래시,
            // 같은 실행의 다른 테스트 결과까지 잃는다) — uniquingKeysWith 로 감지해 XCTFail 로 바꾼다.
            var jsonLabelsByID: [String: String] = [:]
            for node in json.labeledNodes {
                if let existing = jsonLabelsByID[node.id], existing != node.label {
                    XCTFail("'\(fileKey)': JSON 노드 id '\(node.id)' 가 서로 다른 라벨로 중복됨: '\(existing)' vs '\(node.label)'")
                }
                jsonLabelsByID[node.id] = node.label
            }

            XCTAssertEqual(html.speciesNodeIDs, Set(jsonLabelsByID.keys),
                "'\(fileKey)': HTML species 노드 집합과 JSON species 노드 집합이 다름 — "
                + "HTML 에만: \(html.speciesNodeIDs.subtracting(jsonLabelsByID.keys)), "
                + "JSON 에만: \(Set(jsonLabelsByID.keys).subtracting(html.speciesNodeIDs))")

            for node in html.labeledNodes {
                totalCompared += 1
                guard let jsonLabel = jsonLabelsByID[node.id] else {
                    XCTFail("'\(fileKey)': HTML 노드 '\(node.id)' 가 JSON 스펙에 없음")
                    continue
                }
                XCTAssertEqual(node.attrLabel, jsonLabel,
                    "'\(fileKey)': 노드 '\(node.id)' 의 data-node-label 속성('\(node.attrLabel)')이 "
                    + "JSON label('\(jsonLabel)')과 다름")
                XCTAssertEqual(node.visibleLabel, jsonLabel,
                    "'\(fileKey)': 노드 '\(node.id)' 의 화면 표시 텍스트(t-primary, '\(node.visibleLabel)')가 "
                    + "JSON label('\(jsonLabel)')과 다름 — 속성은 맞는데 화면이 틀린 경우")
            }
        }
        XCTAssertEqual(totalCompared, 67,
            "HTML 라벨 노드 총수가 달라짐(12장 인스턴스 합 67 기대) — 파일 구성이 변경됨")
    }

    /// 죠그레스 엣지 끝점을 HTML 에서 뽑아 데이터셋과 직접 대조한다(JSON 쪽
    /// `testJogressEdgesMatchDataset` 과 동일한 기준). JSON 이 맞아도 HTML 을 손으로
    /// 잘못 고치면(이번에 실제로 발생) JSON 쪽 테스트만으론 못 잡는다.
    func testHTMLJogressEdgesMatchDataset() throws {
        let ds = try DigimonData.loaded()
        let datasetTriples = Set(ds.jogressResults.map { key, result in Set(key.speciesIDs + [result]) })

        var totalEdges = 0
        for (fileKey, html, _) in try allHTMLAndJSONSpecPairs() {
            var groups: [String: [String]] = [:]
            for edge in html.jogressEdges {
                totalEdges += 1
                groups[edge.to, default: []].append(edge.from)
            }
            for (resultNodeID, parentNodeIDs) in groups {
                guard let resultSpeciesID = Self.nodeToSpeciesID[resultNodeID] else {
                    XCTFail("'\(fileKey)': HTML 죠그레스 결과 노드 '\(resultNodeID)' 가 nodeToSpeciesID 에 없음")
                    continue
                }
                let parentSpeciesIDs = parentNodeIDs.compactMap { Self.nodeToSpeciesID[$0] }
                XCTAssertEqual(parentSpeciesIDs.count, parentNodeIDs.count,
                    "'\(fileKey)': HTML 죠그레스 결과 '\(resultNodeID)' 의 부모 중 nodeToSpeciesID 에 없는 것: \(parentNodeIDs)")
                let triple = Set(parentSpeciesIDs + [resultSpeciesID])
                XCTAssertTrue(datasetTriples.contains(triple),
                    "'\(fileKey)': HTML 이 그린 죠그레스 (부모 \(parentNodeIDs)=\(parentSpeciesIDs), "
                    + "결과 \(resultNodeID)=\(resultSpeciesID)) 가 digimon.json 의 jogress 배열에 없음 — "
                    + "기대 삼중항 \(triple)")
            }
        }
        // 12장 합 18. (edge-id 반복 occurrence 는 이미 하나로 합쳐진 값.) JSON 쪽
        // testJogressEdgesMatchDataset 의 18 과 같아야 함 — 서로 다른 파일에서 뽑은 두
        // 독립된 카운트가 일치하는 것도 교차검증이다.
        XCTAssertEqual(totalEdges, 18, "HTML 의 '죠그레스' 라벨 엣지 총수가 달라짐 — 파일 구성이 변경됨")
    }

    // MARK: - (f-2) 부 라벨(sublabel) 층 가드

    // 기존 (e)/(f) 는 주 라벨(t-primary)만 본다. 부 라벨 층엔 단언이 0건이었다 — 황제드라몬
    // 3종(900/405/481)의 모드 문자열("드래곤 모드"/"파이터 모드"/"팔라딘 모드")을 전부 지워도
    // 기존 14개 테스트가 전부 green 이었다(직접 확인). 이 모드 문자열은 vmon 챕터의 3종,
    // wormmon 챕터의 2종(impdragon/impfighter — imppaladin 은 브이몬 라인이 필요해 정당하게
    // 없음)을 화면에서 구분하는 유일한 요소다.
    //
    // 대상 노드는 `names.ko` 에 콜론이 있는 종(데이터셋에서 유도 — 하드코딩 아님)을
    // `nodeToSpeciesID` 로 역매핑해 각 차트가 실제로 담고 있는 노드만 추적한다.
    //
    // 4개 층을 전부 본다: `data-node-sublabel` 속성, `t-muted` 화면 텍스트, `<title>`,
    // `aria-label`. 앞의 둘은 부 라벨 자체이므로 **완전 일치**로 비교한다(접두 일치를 허용하면
    // "파이터 모드"→"파이터" 같은 잘림도 통과해버려 회귀 가드가 무의미해진다 — 파일 상단
    // `baseName` 관련 주석과 같은 이유). `<title>`/`aria-label` 은 여러 필드를 이어붙인
    // 합성 문자열이라 완전 일치를 요구할 수 없으므로, 데이터셋에서 유도한 부분 문자열을
    // 포함하는지로 대조한다 — 이때도 그 부분 문자열 자체가 "이 노드의" 전체 이름(`names.ko`,
    // 콜론 포함)이라 스왑 뮤테이션(드래곤↔파이터)에서 여전히 깨진다.
    //
    // 반드시 **노드 블록 단위**로 스코프한다: vmon.html 한 파일 안에 impdragon 과 impfighter가
    // 같이 있어서, 파일 전체에서 "드래곤 모드"라는 문자열이 어딘가에 있는지만 보면 두 노드를
    // 맞바꿔도 파일 전체 집합은 그대로라 통과해버린다. `parseHTMLDiagramSpec` 이 이미 노드별로
    // 블록을 분리해뒀으므로 각 `HTMLDiagramSpec.LabeledNode`/`DiagramSpec.LabeledNode` 단위로
    // 비교한다. JSON `sublabel` 도 같은 루프에서 **데이터셋에 독립적으로** 대조한다 — HTML 을
    // JSON 과만 비교하면 둘이 같이 오염된 경우를 못 잡는다.
    func testModeVariantSublabelsMatchDatasetAcrossAllLayers() throws {
        let ds = try DigimonData.loaded()

        // 콜론 표기 종만 추적 대상. baseName() 의 여집합이 부 라벨이다.
        let modeVariantSpeciesIDs = ds.names.compactMap { id, name -> (Int, String, String)? in
            guard let ko = name.localeNames["ko"], ko.contains(":") else { return nil }
            let base = baseName(ko)
            let suffix = ko.dropFirst(base.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return (id, ko, suffix)
        }
        XCTAssertEqual(modeVariantSpeciesIDs.count, 3,
            "콜론 표기 종 수가 3이 아님(현재 황제드라몬 3종 기대) — 데이터셋 구성이 변경됨")
        var expectedByID: [Int: (fullKo: String, suffix: String)] = [:]
        for (id, ko, suffix) in modeVariantSpeciesIDs { expectedByID[id] = (ko, suffix) }

        var checkedInstances = 0
        for (fileKey, html, json) in try allHTMLAndJSONSpecPairs() {
            var jsonSublabelsByID: [String: String?] = [:]
            for node in json.labeledNodes { jsonSublabelsByID[node.id] = node.sublabel }

            for node in html.labeledNodes {
                guard let speciesID = Self.nodeToSpeciesID[node.id],
                      let expected = expectedByID[speciesID]
                else { continue }
                checkedInstances += 1
                let context = "'\(fileKey)': 노드 '\(node.id)'(species \(speciesID))"

                XCTAssertEqual(node.attrSublabel, expected.suffix,
                    "\(context) data-node-sublabel('\(node.attrSublabel ?? "nil")')이 기대 부 라벨('\(expected.suffix)')과 다름")
                XCTAssertEqual(node.visibleSublabel, expected.suffix,
                    "\(context) 화면 표시 부 라벨(t-muted, '\(node.visibleSublabel ?? "nil")')이 "
                    + "기대 부 라벨('\(expected.suffix)')과 다름")
                XCTAssertEqual(jsonSublabelsByID[node.id] ?? nil, expected.suffix,
                    "\(context) JSON sublabel('\(jsonSublabelsByID[node.id].flatMap { $0 } ?? "nil")')이 "
                    + "기대 부 라벨('\(expected.suffix)')과 다름")

                // <title> 은 "{라벨} · {부라벨} · {컨텍스트} · {브랜드}" 형식(콜론이 아니라
                // 가운뎃점으로 이어붙인다 — names.ko 원문과 구분자가 다르다).
                let titleNeedle = "\(baseName(expected.fullKo)) · \(expected.suffix)"
                let title = try XCTUnwrap(node.title, "\(context) <title> 이 없음")
                XCTAssertTrue(title.contains(titleNeedle),
                    "\(context) <title>('\(title)')이 기대 부분 문자열('\(titleNeedle)')을 포함하지 않음")

                let aria = try XCTUnwrap(node.ariaLabel, "\(context) aria-label 이 없음")
                XCTAssertTrue(aria.contains(expected.fullKo),
                    "\(context) aria-label('\(aria)')이 기대 전체 이름('\(expected.fullKo)')을 포함하지 않음")
            }
        }
        // 긍정 대조: vmon 3개 + wormmon 2개 = 5 인스턴스. imppaladin 은 wormmon 에 없는 게
        // 정상(팔라딘은 브이몬 라인 필요)이라 이 총수가 6이 아니라 5다. 파싱이 조용히
        // 비어버리면(필터 오류 등) 이 루프가 공허하게 통과하는 걸 여기서 막는다.
        XCTAssertEqual(checkedInstances, 5,
            "모드 변형 노드 인스턴스 총수가 5가 아님 — 차트 구성이 변경됐거나 파싱이 깨짐")
    }

    // MARK: - (g) 통합 스펙 JSON(`diagrams/digivolution.workflow.json`) 가드

    // 이 파일은 git 추적 파일인데(위 (f) 섹션 주석 참고) 어떤 테스트도 읽지 않아서 가드
    // 커버리지가 0 이었다 — 노드 label 을 전혀 다른 종 이름으로 바꿔도 기존 11개 테스트가
    // 전부 green 이었다(직접 확인). HTML 쪽(`Resources/digivolution.html`)은 gitignore 로
    // 빠져 있어 계속 제외하되, JSON 쪽은 커밋된 트리에 항상 있으므로 별도로 가드한다.

    private func combinedDiagramSpecURL() -> URL {
        repoRootURL().appendingPathComponent("diagrams/digivolution.workflow.json")
    }

    private func combinedDiagramSpec() throws -> DiagramSpec {
        let data = try Data(contentsOf: combinedDiagramSpecURL())
        return try loadDiagramSpec(fromData: data, describedAs: "통합(digivolution.workflow.json)")
    }

    /// 통합 차트의 노드 라벨이 데이터셋 이름과 일치하는지 대조한다. `testNodeLabelsMatchDatasetNames`
    /// 와 같은 판정 본체(`assertLabelMatchesDatasetName`)를 쓴다 — `baseName` 은 데이터셋 쪽에만
    /// 적용해 "아트라캅테리몬(적)" 같은 변형이 기본형으로 잘려 통과하는 걸 막는다.
    func testCombinedDiagramNodeLabelsMatchDatasetNames() throws {
        let ds = try DigimonData.loaded()
        let spec = try combinedDiagramSpec()
        for node in spec.labeledNodes {
            assertLabelMatchesDatasetName(node.label, speciesID: node.speciesID, dataset: ds,
                context: "통합 차트: 노드 '\(node.id)'(species \(node.speciesID))")
        }
        XCTAssertEqual(spec.labeledNodes.count, 52, "통합 차트의 라벨 붙은 species 노드 총수가 달라짐")
    }

    /// 통합 차트 JSON(`diagrams/digivolution.workflow.json`)의 황제드라몬 3종 sublabel 을
    /// 데이터셋과 대조한다. 이 파일은 git 추적 파일이라 (g) 섹션 나머지 테스트와 같은 이유로
    /// 별도 가드가 필요하다 — HTML 쪽(`Resources/digivolution.html`)은 gitignore 대상이라
    /// 원천적으로 대조 불가능하므로 대상에서 뺀다(브리프 범위 밖의 판단 — 파일 상단 (f) 섹션
    /// 주석의 제외 근거와 동일).
    func testCombinedDiagramSublabelsMatchDataset() throws {
        let ds = try DigimonData.loaded()
        let modeVariantSpeciesIDs = ds.names.compactMap { id, name -> (Int, String)? in
            guard let ko = name.localeNames["ko"], ko.contains(":") else { return nil }
            let suffix = ko.dropFirst(baseName(ko).count)
                .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return (id, suffix)
        }
        var expectedSuffixByID: [Int: String] = [:]
        for (id, suffix) in modeVariantSpeciesIDs { expectedSuffixByID[id] = suffix }

        let spec = try combinedDiagramSpec()
        var checked = 0
        for node in spec.labeledNodes {
            guard let expectedSuffix = expectedSuffixByID[node.speciesID] else { continue }
            checked += 1
            XCTAssertEqual(node.sublabel, expectedSuffix,
                "통합 차트: 노드 '\(node.id)'(species \(node.speciesID)) sublabel('\(node.sublabel ?? "nil")')이 "
                + "기대 부 라벨('\(expectedSuffix)')과 다름")
        }
        XCTAssertEqual(checked, 3, "통합 차트에서 모드 변형 노드 수가 3이 아님 — 차트 구성이 변경됨")
    }

    /// 통합 차트의 죠그레스 엣지를 `digimon.json` 의 `jogress` 배열과 대조한다.
    /// `testJogressEdgesMatchDataset` 과 동일한 기준(부모 2개, 삼중항이 데이터셋에 존재).
    func testCombinedDiagramJogressEdgesMatchDataset() throws {
        let ds = try DigimonData.loaded()
        let datasetTriples = Set(ds.jogressResults.map { key, result in Set(key.speciesIDs + [result]) })
        let spec = try combinedDiagramSpec()

        var groups: [String: [String]] = [:]
        for edge in spec.jogressEdges {
            groups[edge.to, default: []].append(edge.from)
        }
        for (resultNodeID, parentNodeIDs) in groups {
            guard let resultSpeciesID = Self.nodeToSpeciesID[resultNodeID] else {
                XCTFail("통합 차트: 죠그레스 결과 노드 '\(resultNodeID)' 가 nodeToSpeciesID 에 없음")
                continue
            }
            XCTAssertEqual(parentNodeIDs.count, 2,
                "통합 차트: 죠그레스 결과 '\(resultNodeID)'(species \(resultSpeciesID))의 부모가 "
                + "2개가 아니라 \(parentNodeIDs.count)개(\(parentNodeIDs))")
            let parentSpeciesIDs = parentNodeIDs.compactMap { Self.nodeToSpeciesID[$0] }
            XCTAssertEqual(parentSpeciesIDs.count, parentNodeIDs.count,
                "통합 차트: 죠그레스 결과 '\(resultNodeID)' 의 부모 노드 중 nodeToSpeciesID 에 없는 것: \(parentNodeIDs)")
            let triple = Set(parentSpeciesIDs + [resultSpeciesID])
            XCTAssertTrue(datasetTriples.contains(triple),
                "통합 차트: (부모 \(parentNodeIDs)=\(parentSpeciesIDs), 결과 \(resultNodeID)=\(resultSpeciesID)) "
                + "가 digimon.json 의 jogress 배열에 없음 — 기대 삼중항 \(triple)")
        }
        XCTAssertEqual(spec.jogressEdges.count, 10, "통합 차트의 '죠그레스' 라벨 엣지 총수가 달라짐")
        XCTAssertEqual(groups.count, 5, "통합 차트의 죠그레스 결과 노드 총수가 달라짐")
    }

    /// 통합 차트와 12장 라인 차트 사이의 라벨 드리프트를 잡는다. 같은 노드 id 가 통합 차트와
    /// 어느 라인 차트에서 서로 다른 라벨이면 실패한다 — 각 파일 자체는 데이터셋과 맞아도
    /// (`testNodeLabelsMatchDatasetNames`/`testCombinedDiagramNodeLabelsMatchDatasetNames` 가
    /// 개별로 보장) 둘이 서로 다른 표기(전체형 vs 기본형 등)로 갈라질 수 있어 별도로 본다.
    func testCombinedDiagramLabelsMatchLineDiagrams() throws {
        let ds = try DigimonData.loaded()
        let combined = try combinedDiagramSpec()
        let combinedLabelsByID = Dictionary(uniqueKeysWithValues: combined.labeledNodes.map { ($0.id, $0.label) })

        var comparedIDs = Set<String>()
        for key in ds.linesByKey.keys {
            let lineSpec = try loadDiagramSpec(key)
            for node in lineSpec.labeledNodes {
                comparedIDs.insert(node.id)
                guard let combinedLabel = combinedLabelsByID[node.id] else {
                    XCTFail("통합 차트에 노드 '\(node.id)'(라인 '\(key)') 가 없음")
                    continue
                }
                XCTAssertEqual(combinedLabel, node.label,
                    "노드 '\(node.id)': 통합 차트 라벨 '\(combinedLabel)' 이 라인 '\(key)' 라벨 '\(node.label)' 과 다름")
            }
        }
        XCTAssertEqual(comparedIDs, Set(combinedLabelsByID.keys),
            "통합 차트와 12장 라인 차트의 species 노드 집합이 다름 — "
            + "통합에만: \(Set(combinedLabelsByID.keys).subtracting(comparedIDs)), "
            + "라인에만: \(comparedIDs.subtracting(combinedLabelsByID.keys))")
    }

    private func loadDiagramSpec(_ lineKey: String) throws -> DiagramSpec {
        let data = try Data(contentsOf: diagramSpecURL(lineKey))
        return try loadDiagramSpec(fromData: data, describedAs: lineKey)
    }

    /// `loadDiagramSpec(_:)` 의 파싱 본체. 통합 스펙(`diagrams/digivolution.workflow.json`)처럼
    /// 라인 키로 경로를 못 만드는 파일도 이 함수로 직접 파싱한다 —
    /// `combinedDiagramSpec()`(아래 (g) 섹션)가 사용한다.
    private func loadDiagramSpec(fromData data: Data, describedAs label: String) throws -> DiagramSpec {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodes = json["nodes"] as? [[String: Any]]
        else {
            XCTFail("스펙 '\(label)' 파싱 실패")
            return DiagramSpec(speciesNodeIDs: [], digimentalItemNodes: [], jogressEdges: [], labeledNodes: [])
        }

        var speciesIDs = Set<Int>()
        var itemNodes: [DiagramSpec.Node] = []
        var labeledNodes: [DiagramSpec.LabeledNode] = []
        for node in nodes {
            guard let nodeID = node["id"] as? String else { continue }
            if nodeID.hasPrefix("digimental") {
                if let brand = node["brand"] as? [String: Any], let url = brand["url"] as? String {
                    itemNodes.append(DiagramSpec.Node(id: nodeID, brandURL: url))
                }
            } else if let speciesID = Self.nodeToSpeciesID[nodeID] {
                speciesIDs.insert(speciesID)
                if let label = node["label"] as? String {
                    labeledNodes.append(DiagramSpec.LabeledNode(id: nodeID, speciesID: speciesID, label: label,
                        sublabel: node["sublabel"] as? String))
                }
            } else {
                // nodeToSpeciesID 가 모르는 노드. 조용히 넘기면 새로 추가된 노드가 라벨 대조를
                // 전부 건너뛴다 — species 커버리지 테스트도 이 노드를 못 잡으므로 여기서 잡는다.
                XCTFail("다이어그램 '\(label)' 의 노드 '\(nodeID)' 가 nodeToSpeciesID 테이블에 없음")
            }
        }

        var jogressEdges: [DiagramSpec.JogressEdge] = []
        if let edges = json["edges"] as? [[String: Any]] {
            for edge in edges {
                guard edge["label"] as? String == "죠그레스",
                      let from = edge["from"] as? String,
                      let to = edge["to"] as? String
                else { continue }
                jogressEdges.append(DiagramSpec.JogressEdge(from: from, to: to))
            }
        }

        return DiagramSpec(speciesNodeIDs: speciesIDs, digimentalItemNodes: itemNodes,
            jogressEdges: jogressEdges, labeledNodes: labeledNodes)
    }
}
