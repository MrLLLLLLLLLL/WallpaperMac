import SwiftUI
import WallpaperMacCore

struct HiddenWallpaperAuthRequest: Identifiable {
    enum Mode: Equatable {
        case setPassword
        case unlock
    }

    enum Purpose: Equatable {
        case enableVisibility
        case hide(Set<UUID>)
    }

    let id = UUID()
    let mode: Mode
    let purpose: Purpose
}

struct HiddenWallpaperAuthSheet: View {
    @ObservedObject var model: LibraryViewModel
    let request: HiddenWallpaperAuthRequest
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var isSubmitting = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case password
        case confirmation
    }

    private var isSettingPassword: Bool {
        request.mode == .setPassword
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: isSettingPassword ? "lock.badge.plus" : "lock.open")
                    .font(.title2)
                Text(isSettingPassword ? "设置隐藏壁纸密码" : "解锁隐藏壁纸")
                    .font(.title3.weight(.semibold))
            }

            if isSettingPassword {
                Text("首次隐藏壁纸需要设置密码。密码只保存在当前壁纸库中，打开“显示隐藏壁纸”时必须输入。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("隐藏只影响应用内显示，不会加密文件；密码无法找回。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("输入密码后才能显示隐藏壁纸和编辑相关队列。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .password)
                .onSubmit {
                    if isSettingPassword, !password.isEmpty {
                        focusedField = .confirmation
                    } else {
                        submit()
                    }
                }

            if isSettingPassword {
                SecureField("确认密码", text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .confirmation)
                    .onSubmit(submit)
                Text("至少 \(HiddenWallpaperLock.minimumPasswordLength) 个字符")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = model.hiddenAuthError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") {
                    model.cancelHiddenAuth()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(isSettingPassword ? "设置并继续" : "解锁") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting || password.isEmpty || (isSettingPassword && confirmation.isEmpty))
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear {
            focusedField = .password
        }
        .onChange(of: model.hiddenAuthRequest?.id) { requestID in
            if requestID == nil {
                dismiss()
            }
        }
        .onChange(of: model.hiddenAuthError) { error in
            if error != nil {
                isSubmitting = false
            }
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        model.submitHiddenPassword(
            password,
            confirmation: isSettingPassword ? confirmation : nil
        )
    }
}
