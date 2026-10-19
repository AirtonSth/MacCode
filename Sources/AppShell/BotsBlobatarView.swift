import SwiftUI
import CoreModel
import DesignSystemKit
import Surfaces

/// Studio composer. Control set is blobatar's editor; tiles follow bloub.
struct BotBlobatarEditor: View {
    @Binding var token: String
    var seed: String
    var handle: String = ""
    var columns: Int = 2

    private var spec: BotBlobatarSpec {
        BotBlobatarSpec.parse(token) ?? .default
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            section("shape") {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.sm), count: max(2, columns)),
                    spacing: DS.Space.md
                ) {
                    ForEach(BotBlobatarShape.allCases, id: \.self) { shape in
                        tile(
                            label: shape.rawValue,
                            selected: spec.shape == shape,
                            identifier: "bots.studio.avatar.shape.\(shape.rawValue)",
                            preview: previewing { $0.shape = shape }
                        ) {
                            apply { $0.shape = shape }
                        }
                    }
                }
            }
            section("hue") {
                hueRow
            }
        }
        .padding(DS.Space.xl)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
        .accessibilityIdentifier("bots.studio.avatar")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(title)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
            content()
        }
    }

    private func tile(label: String, selected: Bool, identifier: String, preview: BotBlobatarSpec, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: DS.Space.xs) {
                BotBlobatarView(name: seed, spec: preview, size: 36, motion: .frozen, handle: handle)
                Text(label)
                    .font(DS.Font.caption2)
                    .foregroundColor(selected ? DS.Palette.text : DS.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: BotsChrome.hitTarget)
            .padding(.vertical, DS.Space.sm)
            .background(selected ? DS.Palette.surfaceOverlay : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private var hueRow: some View {
        // Adaptive grid: 15 swatches wrap onto more rows instead of widening the picker.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 24, maximum: 28), spacing: DS.Space.sm)], alignment: .leading, spacing: DS.Space.sm) {
            let autoSelected = spec.hue == .auto
            Button {
                apply { $0.hue = .auto }
            } label: {
                Text("auto")
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(autoSelected ? DS.Palette.onAccent : DS.Palette.textSecondary)
                    .padding(.horizontal, DS.Space.lg)
                    .padding(.vertical, DS.Space.sm)
                    .background(autoSelected ? DS.Palette.text : Color.clear)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("auto")
            .accessibilityAddTraits(autoSelected ? .isSelected : [])
            .accessibilityIdentifier("bots.studio.avatar.hue.auto")
            .gridCellColumns(2)

            ForEach(BotBlobatar.studioHues, id: \.id) { swatch in
                let selected = spec.hue == .named(swatch.id)
                Button {
                    apply { $0.hue = .named(swatch.id) }
                } label: {
                    Circle()
                        .fill(Color(
                            red: Double((swatch.preview >> 16) & 0xFF) / 255,
                            green: Double((swatch.preview >> 8) & 0xFF) / 255,
                            blue: Double(swatch.preview & 0xFF) / 255
                        ))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                        .overlay(
                            Circle()
                                .strokeBorder(selected ? DS.Palette.text : Color.clear, lineWidth: 2)
                                .padding(-3)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(swatch.id)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("bots.studio.avatar.hue.\(swatch.id)")
                .frame(width: 24, height: 24)
            }
        }
        .accessibilityIdentifier("bots.studio.avatar.hue")
    }

    private func previewing(_ mutate: (inout BotBlobatarSpec) -> Void) -> BotBlobatarSpec {
        var next = spec
        mutate(&next)
        return next
    }

    private func apply(_ mutate: (inout BotBlobatarSpec) -> Void) {
        var next = spec
        mutate(&next)
        next.expression = .idle
        next.background = .none
        if next.isDefaultAppearance {
            next.frozenSeed = nil
        } else if next.frozenSeed == nil || next.frozenSeed?.isEmpty == true {
            next.frozenSeed = seed
        }
        token = next.token
    }
}
