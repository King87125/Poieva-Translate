import TypeBridgeCore
import SwiftUI

struct SelectionOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
    init(_ value: Value, _ title: String) { self.value = value; self.title = title }
}

struct SelectionFieldStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .padding(.horizontal, 11).frame(height: 32)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.075), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5) }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? 1 : 0.45)
    }
}

/// Let macOS draw the menu, checkmarks, highlight, keyboard navigation and dismissal.
struct SelectionField<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [SelectionOption<Value>]
    private var selectedTitle: String { options.first { $0.value == selection }?.title ?? L10n.tr("选择…") }
    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options) { option in Text(option.title).tag(option.value) }
            }.labelsHidden().pickerStyle(.inline)
        } label: {
            HStack(spacing: 10) {
                Text(selectedTitle).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button).menuIndicator(.hidden).labelsVisibility(.visible)
        .buttonStyle(SelectionFieldStyle())
        .accessibilityLabel(title).accessibilityValue(selectedTitle)
    }
}

struct ConfigurationField<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .medium))
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConfigurationEntry: View {
    let title: String
    @Binding var text: String
    var prompt = ""
    var secure = false
    @FocusState private var focused: Bool
    var body: some View {
        Group {
            if secure { SecureField(title, text: $text, prompt: Text(prompt)) }
            else { TextField(title, text: $text, prompt: Text(prompt)).autocorrectionDisabled() }
        }
        .textFieldStyle(.plain).font(.system(size: 13)).focused($focused)
        .padding(.horizontal, 11).frame(height: 34)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.16), lineWidth: focused ? 1.5 : 0.5) }
        .accessibilityLabel(title)
    }
}

struct ConfigurationGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
    }
}
