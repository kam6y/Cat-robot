import SwiftUI
import UIKit

struct FaceSizeTunerView: View {
    @ObservedObject var model: FaceSizeTuningModel
    @State private var expression: FaceExpression = .neutral
    @State private var showsControls = true
    @State private var copied = false

    var body: some View {
        FaceSizePreview(scale: model.scale, expression: expression)
            .overlay(alignment: .top) {
                if showsControls {
                    ViewThatFits(in: .horizontal) {
                        toolbar
                        toolbar.labelStyle(.iconOnly)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                } else {
                    HStack {
                        Spacer()
                        Button {
                            showsControls = true
                        } label: {
                            Label("調整を表示", systemImage: "slider.horizontal.3")
                                .labelStyle(.iconOnly)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityIdentifier("showTuningControls")
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                }
            }
            .overlay(alignment: .bottom) {
                if showsControls {
                    sizeControls
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                }
            }
            .tint(Color(red: 0.99, green: 0.79, blue: 0.25))
            .onChange(of: model.scale) { _, _ in copied = false }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("顔サイズ").font(.headline)
            Picker("表情", selection: $expression) {
                ForEach(FaceExpression.allCases, id: \.self) { expression in
                    Text(expression.tuningTitle).tag(expression)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("faceExpression")
            Spacer(minLength: 8)
            Button {
                model.reset()
            } label: {
                Label("85%に戻す", systemImage: "arrow.counterclockwise")
            }
            .accessibilityIdentifier("resetFaceSize")
            Button {
                UIPasteboard.general.string = model.copyValue
                copied = true
            } label: {
                Label(copied ? "コピー済み" : "値をコピー", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .accessibilityIdentifier("copyFaceSize")
            Button {
                showsControls = false
            } label: {
                Label("全画面", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityIdentifier("hideTuningControls")
        }
        .font(.callout)
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private var sizeControls: some View {
        HStack(spacing: 10) {
            Button {
                model.setScale(model.scale - FaceSizeTuningModel.step)
            } label: {
                Image(systemName: "minus").frame(width: 44, height: 44)
            }
            .accessibilityLabel("0.5%小さくする")
            .accessibilityIdentifier("decreaseFaceSize")
            .disabled(model.scale <= FaceSizeTuningModel.scaleRange.lowerBound)
            Slider(value: Binding(get: { model.scale }, set: model.setScale),
                   in: FaceSizeTuningModel.scaleRange, step: FaceSizeTuningModel.step)
                .accessibilityLabel("顔の大きさ")
                .accessibilityValue(model.percentageText)
                .accessibilityIdentifier("faceSizeSlider")
            Button {
                model.setScale(model.scale + FaceSizeTuningModel.step)
            } label: {
                Image(systemName: "plus").frame(width: 44, height: 44)
            }
            .accessibilityLabel("0.5%大きくする")
            .accessibilityIdentifier("increaseFaceSize")
            .disabled(model.scale >= FaceSizeTuningModel.scaleRange.upperBound)
            Text(model.percentageText)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(minWidth: 80, alignment: .trailing)
                .accessibilityIdentifier("faceSizeValue")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: Capsule())
    }
}

private extension FaceExpression {
    var tuningTitle: String {
        switch self {
        case .neutral: "通常"
        case .happy: "うれしい"
        case .curious: "興味"
        case .thinking: "考え中"
        case .speaking: "お話し"
        case .sleepy: "眠そう"
        case .surprised: "びっくり"
        case .sorry: "ごめん"
        case .sleeping: "眠り"
        }
    }
}
