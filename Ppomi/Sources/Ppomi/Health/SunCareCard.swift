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
                Image(systemName: "sun.max.fill").font(.ppomi(6)).foregroundStyle(.accentFg)
                VStack(alignment: .leading, spacing: 5) {
                    Text("아침 선크림").font(.ppomi(4, weight: .medium))
                    Text("세안·보습 후, 외출 전").font(.ppomi(2)).foregroundStyle(.fg2)
                }
                Spacer()
                if summary.todayCompleted {
                    Label("오늘 기록됨", systemImage: "checkmark.circle.fill").foregroundStyle(.accentFg)
                        .accessibilityIdentifier("sunscreen-today-status")
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { action(summary); counts(summary) }
                VStack(alignment: .leading, spacing: 10) { action(summary); counts(summary) }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("최근 28일").font(.ppomi(1)).foregroundStyle(.fg2)
                    Spacer()
                    Label("바른 날", systemImage: "circle.fill").foregroundStyle(.fg)
                    Label("미기록", systemImage: "circle").foregroundStyle(.fg2)
                }.font(.ppomi(1))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(summary.cells) { day in dayCell(day) }
                }
            }
            Text("빈 날은 실패 아님")
                .font(.ppomi(1)).foregroundStyle(.fg2)
            DisclosureGroup("피부 변화 보기") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("월 1회 · 같은 카메라·조명·거리·각도 · 편안한 표정 · 원본 사진 (필터·보정 없이)")
                    Text("‘기록 추가 › 컨디션’에 날짜·조건 적고 사진 첨부 · 피부 나이 계산 없음")
                    Text("UV 카메라는 맞는 장비에서만 · 일반 사진 → UV 변환 불가 · SPF 환산 불가")
                    HStack {
                        Link("사진·조명 연구", destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/26893277/")!)
                        Link("UV 연구", destination: URL(string: "https://derma.jmir.org/2021/1/e24653/")!)
                    }.tint(.accentFg)
                }.font(.ppomi(1)).foregroundStyle(.fg2).padding(.top, 8)
            }.font(.ppomi(2))
            HStack(alignment: .top) {
                Text("SPF 30+ · UVA/UVB · 야외 2시간마다 덧바름")
                Link("지침", destination: URL(string: "https://www.aad.org/media/stats-sunscreen")!)
            }.font(.ppomi(1)).foregroundStyle(.fg2).tint(.accentFg)
        }
        .padding(20).background(.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.line))
        .accessibilityIdentifier("sunscreen-habit-card")
    }

    private func dayCell(_ day: SunCare.Day) -> some View {
        Text(day.dayLabel).font(.ppomi(1)).monospacedDigit()
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(day.isCompleted ? Color.fg : Color.surface2, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(day.isCompleted ? Color.fg : Color.line))
            .foregroundStyle(day.isCompleted ? Color.bg : Color.fg2)
            .accessibilityLabel(day.dayKey + (day.isCompleted ? " 선크림 바름 기록" : " 미기록"))
    }

    private func action(_ summary: SunCare.Summary) -> some View {
        HStack(spacing: 10) {
            Button(summary.todayCompleted ? "오늘 기록됨" : "오늘 발랐음", systemImage: "checkmark") {
                let subjectID = model.subjectID
                model.perform { store in
                    _ = try SunCare.logApplication(subjectID: subjectID, at: Date(), to: store)
                    return "기록됨"
                }
            }.buttonStyle(.borderedProminent).foregroundStyle(.onAccent)
                .disabled(model.busy || model.subjectID.isEmpty || summary.todayCompleted)
                .accessibilityIdentifier("sunscreen-log-today")
            if summary.todayCompleted {
                Button("취소") {
                    let subjectID = model.subjectID
                    model.perform { store in
                        _ = try SunCare.retractApplication(subjectID: subjectID, on: Date(), to: store)
                        return "취소됨 · 이력 보관"
                    }
                }.font(.ppomi(1)).disabled(model.busy).accessibilityIdentifier("sunscreen-undo-today")
            }
        }
    }
    private func counts(_ summary: SunCare.Summary) -> some View {
        Text("7일 \(summary.last7DaysCount)일 · 28일 \(summary.last28DaysCount)일")
            .font(.ppomi(2)).foregroundStyle(.fg2)
    }
}
