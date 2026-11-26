import SwiftUI
import WallpaperMacCore

/// Steam account login form. Used both from Settings and as the gate sheet
/// when the user opens Workshop browse without a session.
struct SteamLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Called after a successful login so the caller can continue (e.g. open browse).
    var onLoggedIn: (() -> Void)?
    /// Called when the user cancels or closes the sheet without logging in.
    /// Callers that gate another sheet (browse) should close that sheet too.
    var onCancelled: (() -> Void)?

    @State private var username = UserDefaults.standard.string(forKey: SteamSessionStore.usernameDefaultsKey) ?? ""
    @State private var password = ""
    @State private var steamGuardCode = ""
    @State private var wantsGuardCode = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    private let loginService = SteamLoginService()

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty && !isWorking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("登录 Steam")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭登录窗口")
                .disabled(isWorking)
            }

            Text("下载创意工坊壁纸需要拥有 Wallpaper Engine 的 Steam 账号。密码只通过 stdin 发送给 SteamCMD，不写入磁盘、不出现在进程参数中；登录成功后由 SteamCMD 在本机缓存会话。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Steam 账号名", text: $username)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Steam 账号名")
            SecureField("Steam 密码", text: $password)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Steam 密码")
            Toggle("需要 Steam Guard 验证码", isOn: $wantsGuardCode)
                .toggleStyle(.checkbox)
            if wantsGuardCode {
                TextField("Steam Guard / 两步验证码", text: $steamGuardCode)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Steam Guard 验证码")
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在登录…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("取消") {
                    cancel()
                }
                .disabled(isWorking)
                Button {
                    submit()
                } label: {
                    Text("登录")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled(isWorking)
    }

    private func cancel() {
        guard !isWorking else { return }
        onCancelled?()
        dismiss()
    }

    private func submit() {
        errorMessage = nil
        isWorking = true
        let user = username
        let pass = password
        let guardCode = wantsGuardCode
            ? steamGuardCode.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        Task { @MainActor in
            do {
                try await loginService.login(
                    username: user,
                    password: pass,
                    steamGuardCode: guardCode
                )
                isWorking = false
                onLoggedIn?()
                dismiss()
            } catch {
                isWorking = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
