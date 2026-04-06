//
//  UpdateAlertView.swift
//  myPlayer2
//

import SwiftUI
import AppKit

struct UpdateAlertView: View {
    let versionInfo: RemoteVersionInfo?
    let error: Error?
    let onDismiss: () -> Void
    let onGoToRelease: () -> Void
    
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 16)
            
            Divider()
                .opacity(0.25)
            
            contentView
                .padding(20)
            
            Divider()
                .opacity(0.25)
            
            footerView
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 28)
        }
        .frame(width: 440, height: 500)
    }
    
    private var headerView: some View {
        HStack(spacing: 16) {
            if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .cornerRadius(16)
                    .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("发现新版本")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                
                Text("请前往 GitHub Release 下载 .app 文件")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                
                Text("并手动替换")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
    }
    
    private var contentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if error != nil {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("版本信息获取失败")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    .padding(.bottom, 8)
                    
                    Text("测试模式：继续显示弹窗用于调试")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let notes = versionInfo?.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: 14))
                        .lineSpacing(5)
                        .foregroundStyle(.primary)
                } else {
                    Text("有新版本可用，建议更新以获得最新功能和修复。")
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    private var footerView: some View {
        HStack(spacing: 12) {
            if let remoteVersion = versionInfo?.latestVersion {
                HStack(spacing: 6) {
                    Text(UpdateChecker.shared.localVersion)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(themeStore.accentColor)
                    
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    
                    Text(remoteVersion)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassEffect(.clear, in: Capsule())
                .background(
                    Capsule()
                        .fill(colorScheme == .dark
                            ? Color.black.opacity(0.18)
                            : Color.black.opacity(0.05))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(GlassStyleTokens.glassBorderColor, lineWidth: 0.5)
                )
            }
            
            Spacer()
            
            Button(action: onDismiss) {
                Text("关闭")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .glassEffect(.clear, in: Capsule())
            .background(
                Capsule()
                    .fill(colorScheme == .dark
                        ? Color.white.opacity(0.08)
                        : Color.black.opacity(0.08))
            )
            .overlay(
                Capsule()
                    .strokeBorder(GlassStyleTokens.glassBorderColor, lineWidth: 0.5)
            )
            
            Button(action: onGoToRelease) {
                Text("前往下载")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .glassEffect(.clear, in: Capsule())
            .background(
                Capsule()
                    .fill(themeStore.accentColor.opacity(colorScheme == .dark ? 0.96 : 0.88))
            )
            .overlay(
                Capsule()
                    .strokeBorder(GlassStyleTokens.glassBorderColor, lineWidth: 0.5)
            )
            .subtleFloatingShadow()
        }
    }
}

#Preview {
    UpdateAlertView(
        versionInfo: RemoteVersionInfo(
            latestVersion: "1.2.2",
            releaseURL: "https://github.com/kmgcc/kmgccc_player/releases/latest",
            notes: "重要修复，建议更新"
        ),
        error: nil,
        onDismiss: {},
        onGoToRelease: {}
    )
    .environmentObject(ThemeStore.shared)
    .frame(width: 440, height: 500)
}
