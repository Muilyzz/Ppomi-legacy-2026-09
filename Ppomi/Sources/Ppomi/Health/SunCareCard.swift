import SwiftUI

struct SunCareCard: View {
    @ObservedObject var model: HealthModel

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: Date(), by: 60)) { clock in
            content(SunCare.summary(records: model.allHealthRecords, subjectID: model.subjectID, now: clock.date))
        }
    }

    private func content(_ summary: SunCare.Summary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "sun.max.fill").font(.system(size: 28)).foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 5) {
                    Text("아침 선크림").font(.title3.bold())
                    Text("세안·보습 다음에, 외출 전에").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if summary.todayCompleted {
                    Label("오늘 기록됨", systemImage: "checkmark.circle.fill").foregroundStyle(.mint)
                        .accessibilityIdentifier("sunscreen-today-status")
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { action(summary); counts(summary) }
                VStack(alignment: .leading, spacing: 10) { action(summary); counts(summary) }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("최근 28일").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Label("바른 날", systemImage: "circle.fill").foregroundStyle(.mint)
                    Label("미기록", systemImage: "circle").foregroundStyle(.secondary)
                }.font(.caption2)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(summary.cells) { day in dayCell(day) }
                }
            }
            Text("빈 날은 실패가 아닙니다. 실제로 바른 날만 채우고, 하루를 놓쳐도 다음 날부터 이어가세요.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("피부 변화는 어떻게 볼까요?") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("월 1회, 같은 카메라·조명·거리·각도와 편안한 표정으로 원본 사진을 남겨 보세요. 뷰티 필터와 자동 보정 차이가 결과를 바꿀 수 있습니다.")
                    Text("‘기록 추가 → 컨디션’에 촬영 날짜와 조건을 적고 사진을 첨부할 수 있습니다. 현재는 원본을 보관하며 피부 나이·노화 방지량을 계산하지 않습니다.")
                    Text("UV 카메라는 제품과 장비가 맞을 때 선크림을 빠뜨린 부위를 보여줄 수 있습니다. 일반 사진을 UV 영상처럼 바꾸거나 화면의 어두운 정도를 SPF로 환산할 수는 없습니다.")
                    HStack {
                        Link("사진·조명 연구", destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/26893277/")!)
                        Link("UV 도포 확인 연구", destination: URL(string: "https://derma.jmir.org/2021/1/e24653/")!)
                    }
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }.font(.callout)
            HStack(alignment: .top) {
                Text("SPF 30 이상·UVA/UVB 차단 제품을 노출 부위에 사용하세요. 야외에서는 약 2시간마다, 수영·땀을 흘린 뒤에는 덧바르세요.")
                Link("사용 지침", destination: URL(string: "https://www.aad.org/media/stats-sunscreen")!)
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20).background(Color(red: 0.11, green: 0.12, blue: 0.085), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("sunscreen-habit-card")
    }

    private func dayCell(_ day: SunCare.Day) -> some View {
        let fill: Color = day.isCompleted ? .mint.opacity(0.18) : .white.opacity(0.025)
        let stroke: Color = day.isCompleted ? .mint.opacity(0.55) : .white.opacity(0.1)
        let foreground: Color = day.isCompleted ? .mint : .secondary
        return Text(day.dayLabel).font(.caption.monospacedDigit())
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(stroke))
            .foregroundStyle(foreground)
            .accessibilityLabel(day.dayKey + (day.isCompleted ? " 선크림 바름 기록" : " 미기록"))
    }

    private func action(_ summary: SunCare.Summary) -> some View {
        HStack(spacing: 10) {
            Button(summary.todayCompleted ? "오늘 바른 기록이 있어요" : "오늘 발랐어요", systemImage: "checkmark") {
                let subjectID = model.subjectID
                model.perform { store in
                    _ = try SunCare.logApplication(subjectID: subjectID, at: Date(), to: store)
                    return "오늘 선크림을 바른 기록을 남겼습니다."
                }
            }.buttonStyle(.borderedProminent).tint(.mint)
                .disabled(model.busy || model.subjectID.isEmpty || summary.todayCompleted)
                .accessibilityIdentifier("sunscreen-log-today")
            if summary.todayCompleted {
                Button("잘못 눌렀어요") {
                    let subjectID = model.subjectID
                    model.perform { store in
                        _ = try SunCare.retractApplication(subjectID: subjectID, on: Date(), to: store)
                        return "오늘 완료 표시를 취소했습니다. 변경 이력은 보관됩니다."
                    }
                }.font(.caption).disabled(model.busy).accessibilityIdentifier("sunscreen-undo-today")
            }
        }
    }
    private func counts(_ summary: SunCare.Summary) -> some View {
        Text("최근 7일 \(summary.last7DaysCount)일 · 최근 28일 \(summary.last28DaysCount)일 기록")
            .font(.callout).foregroundStyle(.secondary)
    }
}
