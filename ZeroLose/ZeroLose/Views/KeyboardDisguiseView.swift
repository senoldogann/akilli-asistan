import SwiftUI

/// Gizleme amacıyla kullanılan, zararsız görünümlü bir "Klavye" tercihler sayfası.
///
/// ZeroLose mülakat/sınavlar için gizli modda çalışır. Birisi bilgisayarı kısa
/// süreliğine kullanırsa, üst çubuktaki klavye simgesine dokunmak gerçek macOS
/// klavye ayarları gibi görünen bir şey açmalı — bir AI asistanı değil. Buradaki
/// her kontrol, kapatma düğmesi ve pencereyi gizleyen zararsız "Klavye
/// Ayarlarını Sıfırla…" eylemi dışında bilerek işlevsizdir.
struct KeyboardDisguiseView: View {
    @Binding var isPresented: Bool
    @AppStorage("selectedThemeName") private var selectedTheme: String = "Red"

    private var accent: Color {
        ThemeStore.accent(for: selectedTheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            Header

            ScrollView {
                VStack(spacing: 0) {
                    GroupSection(
                        title: "Keyboard Shortcuts",
                        icon: "command",
                        rows: [
                            ("Show Emoji & Symbols", "⌃⌘Space"),
                            ("Show Keyboard Viewer", "—"),
                            ("Screenshot", "⌘Shift4")
                        ]
                    )

                    GroupSection(
                        title: "Text Input",
                        icon: "keyboard",
                        rows: [
                            ("Automatic capitalization", "On"),
                            ("Smart quotes", "On"),
                            ("Press-and-hold for accented", "On")
                        ]
                    )

                    GroupSection(
                        title: "Keyboard Brightness",
                        icon: "sun.max",
                        rows: [
                            ("Backlight", "Medium"),
                            ("Turn off after inactivity", "10 sec")
                        ]
                    )

                    HStack {
                        Spacer()
                        Button(action: { withAnimation { isPresented = false } }) {
                            Text("Done")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 9)
                                .background(accent)
                                .cornerRadius(20)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                    .padding(.top, 18)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(width: 420, height: 520)
        .background {
            ZStack {
                if #available(macOS 26.0, *) {
                    Rectangle().fill(.ultraThinMaterial)
                } else {
                    Rectangle().fill(Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.96))
                }
                Color.white.opacity(0.022).blendMode(.overlay)
            }
            .ignoresSafeArea()
        }
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.glassStroke, lineWidth: 0.8)
        )
    }

    private var Header: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(accent)
            Text("Keyboard")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Spacer()
            Button(action: { withAnimation { isPresented = false } }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(18)
        .overlay(
            Rectangle().frame(height: 0.8).foregroundColor(Color.glassStroke),
            alignment: .bottom
        )
    }
}

private struct GroupSection: View {
    let title: String
    let icon: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack {
                        Text(row.0)
                            .font(.system(size: 13))
                            .foregroundColor(.primary.opacity(0.9))
                        Spacer()
                        Text(row.1)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    if index < rows.count - 1 {
                        Divider().overlay(Color.glassStroke)
                    }
                }
            }
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.glassStroke, lineWidth: 0.6)
            )
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
    }
}
