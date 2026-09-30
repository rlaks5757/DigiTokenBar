import SwiftUI

/// 보관함 — 알을 새로 사면서 맡겨 둔 개체를 꺼내거나 놓아준다.
///
/// 팝오버 **내부 화면 전환**이다(`PopoverNavigation.showStorage`). `.sheet`/`.alert` 를 쓰지 않는
/// 이유는 `PopoverView` 의 NOTE 와 같다 — transient 팝오버가 닫히면 고아 시트가 남아 이후 클릭을
/// 전부 먹는다. 방생 확인도 그래서 **행 안의 인라인 2단계**다(`EggCard` 의 `stage` 와 같은 패턴).
///
/// 판정은 하나도 여기 없다 — 목록(`storedMons`)·게이트(`canRetrieveStored`)·불가 사유
/// (`storedRetrieveBlockReason`)·문구는 전부 `CompanionStore` 와 `Localization` 에 있다.
/// SwiftUI `body` 안은 XCTest 가 볼 수 없어서, 여기 로직을 두면 그만큼이 테스트 밖으로 새어나간다
/// (`EggPickerView` 주석과 같은 이유).
@MainActor
struct StorageView: View {
    let store: CompanionStore
    /// 팝오버 내부 화면 전환 방식 — sheet/dismiss 를 쓰지 않는다(`EggPickerView.onBack` 과 같은 패턴).
    let onBack: () -> Void

    private var l: L { store.l }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(l.storageHint)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    let mons = store.storedMons
                    if mons.isEmpty {
                        // 진입점(`canOpenStorage`)이 빈 목록을 숨기므로 보통 도달하지 않는다.
                        // 화면을 열어 둔 채 마지막 개체를 꺼내거나 놓아준 경우의 안전망이다.
                        Text(l.storageEmpty)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(mons) { stored in
                            StoredMonRow(store: store, stored: stored, onRetrieved: onBack)
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
            Text(l.storageTitle).font(.callout.weight(.semibold))
            Spacer()
            // 좌우 균형용 — 뒤로 버튼 폭만큼 비워 제목이 가운데에 오게 한다.
            Text(l.back).opacity(0).accessibilityHidden(true)
        }
        .padding(.horizontal, PopoverMetrics.padding)
        .padding(.vertical, 10)
    }
}

/// 보관 개체 한 줄 — 스프라이트 + 이름/단계/보관 시각 + 꺼내기·놓아주기.
@MainActor
private struct StoredMonRow: View {
    let store: CompanionStore
    let stored: StoredMon
    let onRetrieved: () -> Void

    /// 방생 확인 단계 — 인라인 2단계(`EggCard.Stage` 와 같은 패턴). `.alert` 를 쓰지 않는다.
    @State private var stage: Stage = .idle
    private enum Stage { case idle, confirming }

    /// **사다리 종**으로 표시한다 — 아머는 표시 오버레이일 뿐이고, 꺼내면 사다리 기준으로 이어서
    /// 키운다(`EggCard` 의 확인 문구·`releaseStored` 의 `finalID` 와 같은 축).
    private var speciesID: Int { stored.mon.currentID }
    private var name: String { CompanionStore.dataName(speciesID, store.language) }

    var body: some View {
        let l = store.l
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // 기존 행과 같은 로더 — 새 네트워크 경로를 만들지 않는다(캐시를 그대로 공유).
                SpriteView(speciesID: speciesID, size: 40)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.callout.weight(.semibold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    HStack(spacing: 5) {
                        Text(l.rarityLabel(stored.mon.rarity).uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(rarityColor(stored.mon.rarity)).foregroundStyle(.white)
                            .clipShape(Capsule())
                        Text(l.stage(stored.mon.stageIndex + 1, stored.mon.totalForms))
                            .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    }
                    (Text("\(l.storageStoredAt) ") + Text(stored.storedAt, style: .relative))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
            }
            controls(l)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func controls(_ l: L) -> some View {
        switch stage {
        case .idle:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(l.storageRelease) { stage = .confirming }
                        .buttonStyle(.borderless).controlSize(.small).foregroundStyle(.secondary)
                    Button(l.storageRetrieve) { retrieveNow() }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(!store.canRetrieveStored(stored.id))
                }
                // 왜 못 꺼내는지 — 비활성 버튼만 두면 사용자가 할 일을 알 수 없다.
                if let reason = store.storedRetrieveBlockReason(stored.id) {
                    Text(reason)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .confirming:
            VStack(alignment: .leading, spacing: 4) {
                Text(l.storageReleaseConfirm(name))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(l.cancel) { stage = .idle }
                        .buttonStyle(.borderless).controlSize(.small)
                    Button(l.storageRelease) { releaseNow() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
        }
    }

    /// 꺼내기가 반영됐을 때만 화면을 닫는다 — 거절(활성 개체·부화 중·보증)이면 목록에 남아 사유를
    /// 읽고 다시 누를 수 있다(`BabyPickRow.pickNow` 와 같은 태도).
    private func retrieveNow() {
        if store.retrieveStored(id: stored.id) { onRetrieved() }
    }

    /// 방생은 화면을 닫지 않는다 — 여러 마리를 정리하는 도중일 수 있고, 행 자체가 목록에서 사라져
    /// 이미 충분한 피드백이 된다. 확인 단계는 되돌려 둔다(같은 id 의 행이 다시 뜰 일은 없지만,
    /// 실패 반환값에 대해 확인 상태가 남지 않게).
    private func releaseNow() {
        stage = .idle
        store.releaseStored(id: stored.id)
    }
}
