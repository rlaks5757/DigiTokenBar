import SwiftUI

/// 부화할 유아기 종 직접 선택 — 랜덤 롤을 기다리는 대신 도감에 등록된 유아기 중 하나를 지정한다.
///
/// 팝오버 **내부 화면 전환**이다(`PopoverNavigation.showEggPicker`). `.sheet`/`.alert` 를 쓰지 않는
/// 이유는 `PopoverView` 의 NOTE 와 같다 — transient 팝오버가 닫히면 고아 시트가 남아 이후 클릭을
/// 전부 먹는다.
///
/// 판정은 하나도 여기 없다 — 후보 목록·게이트·문구는 전부 `CompanionStore` 에 있다. SwiftUI `body`
/// 안은 XCTest 가 볼 수 없어서, 여기 로직을 두면 그만큼이 테스트 밖으로 새어나간다
/// (`CompanionHeader.jogressControl` 주석과 같은 이유).
@MainActor
struct EggPickerView: View {
    let store: CompanionStore
    /// 팝오버 내부 화면 전환 방식 — sheet/dismiss 를 쓰지 않는다(`SettingsView.onClose` 와 같은 패턴).
    let onBack: () -> Void

    private var l: L { store.l }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    hints
                    let picks = store.babyPicks
                    if picks.isEmpty {
                        // 진입점(`canPickHatchSpecies`)이 빈 목록을 숨기므로 보통 도달하지 않는다.
                        // 화면을 띄운 뒤 부화가 끝나 후보가 사라지는 경우의 안전망이다.
                        Text(l.eggPickEmpty)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(picks) { pick in
                            BabyPickRow(store: store, pick: pick, onPicked: onBack)
                        }
                    }
                }
                // 팝오버 콘텐츠 폭 고정 — 넘으면 좌우로 잘린다(PopoverMetrics 단일 소스).
                .frame(width: PopoverMetrics.contentWidth, alignment: .leading)
                .padding(PopoverMetrics.padding)
            }
        }
        .frame(height: 460)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.backward")
                    Text(l.back)
                }
            }
            .buttonStyle(.borderless)
            Spacer()
            Text(l.eggPickTitle).font(.callout.weight(.semibold))
            Spacer()
            // 좌우 균형용 — 뒤로 버튼 폭만큼 비워 제목이 가운데에 오게 한다.
            Text(l.back).opacity(0).accessibilityHidden(true)
        }
        .padding(.horizontal, PopoverMetrics.padding)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var hints: some View {
        Text(l.eggPickHint)
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        // 보증 알은 후보가 좁혀져 있다 — 목록이 짧은 이유를 화면에서 말한다.
        if let tier = store.eggGuarantee {
            Text(l.eggPickGuaranteeNote(l.rarityLabel(tier)))
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 후보 한 줄 — 스프라이트 + 이름/등급 + 확정 버튼.
@MainActor
private struct BabyPickRow: View {
    let store: CompanionStore
    let pick: CompanionStore.BabyPick
    let onPicked: () -> Void

    /// 이미 이 종으로 선택돼 있나 — 재선택이 무의미한 행을 강조로 구분한다.
    ///
    /// **후보 목록 안의 종일 때만 true 다**(`pickedHatchName` 의 계약). 프리패치가 미리 롤해 둔
    /// 종까지 이 행에 표시하면 랜덤 부화의 정답을 알이 스스로 알려주게 된다.
    private var isChosen: Bool { store.pickedHatchBaseID == pick.baseID }

    var body: some View {
        let l = store.l
        HStack(spacing: 10) {
            SpriteView(speciesID: pick.baseID, size: 40)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(pick.name).font(.callout.weight(.semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
                HStack(spacing: 5) {
                    Text(l.rarityLabel(pick.rarity).uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(rarityColor(pick.rarity)).foregroundStyle(.white)
                        .clipShape(Capsule())
                    Text("#\(pick.baseID)")
                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            Spacer(minLength: 4)
            if isChosen {
                Text(l.eggPickChosen(pick.name))
                    .font(.caption2).foregroundStyle(Color.accentColor)
                    .lineLimit(2).frame(maxWidth: 120, alignment: .trailing)
            } else {
                Button(l.eggPickConfirm) { pickNow() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(10)
        .background(isChosen ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// 선택이 반영됐을 때만 화면을 닫는다 — 거절(부화 진행 중 등)이면 목록에 남아 다시 누를 수 있다.
    private func pickNow() {
        if store.pickHatchSpecies(baseID: pick.baseID) { onPicked() }
    }
}
