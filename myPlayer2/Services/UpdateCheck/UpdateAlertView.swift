//
//  UpdateAlertView.swift
//  myPlayer2
//

import SwiftUI
import AppKit

enum UpdateAlertKind: Equatable {
    case updateAvailable
    case upToDate
    case failed
}

struct UpdateAlertView: View {
    let kind: UpdateAlertKind
    let versionInfo: RemoteVersionInfo?
    let error: Error?
    let onDismiss: () -> Void
    let onDownload: () -> Void
    let onOpenGitHubRelease: () -> Void
    
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
                Text(headerTitle)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                
                Text(headerDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
    
    private var contentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if kind == .failed || error != nil {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("检查更新失败")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    .padding(.bottom, 8)
                    
                    Text("请稍后再试，或直接前往 GitHub Release 查看最新版本。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if kind == .upToDate {
                    Text("当前已是最新版本。")
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
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
                .lineLimit(1)
                .layoutPriority(1)
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

            if kind == .updateAvailable {
                Button("GitHub Release", action: onOpenGitHubRelease)
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
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
            
            if kind == .updateAvailable {
                Button(action: onDownload) {
                    Text("下载")
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

    private var headerTitle: String {
        switch kind {
        case .updateAvailable: return "发现新版本"
        case .upToDate: return "当前已是最新版本"
        case .failed: return "检查更新失败"
        }
    }

    private var headerSubtitle: String {
        switch kind {
        case .updateAvailable: return "可通过后端下载链接获取安装包"
        case .upToDate: return "无需更新"
        case .failed: return "暂时无法获取版本信息"
        }
    }

    private var headerDetail: String {
        switch kind {
        case .updateAvailable: return "也可使用 GitHub Release 作为备用下载"
        case .upToDate: return "你可以稍后再次手动检查"
        case .failed: return "请检查网络后重试"
        }
    }
}

#Preview {
    UpdateAlertView(
        kind: .updateAvailable,
        versionInfo: RemoteVersionInfo(
            latestVersion: "1.2.2",
            releaseURL: "https://github.com/kmgcc/kmgccc_player/releases",
            downloadURL: "https://player.kmgccc.cn/api/v1/updates/download/latest",
            notes: "重要修复，建议更新"
        ),
        error: nil,
        onDismiss: {},
        onDownload: {},
        onOpenGitHubRelease: {}
    )
    .environmentObject(ThemeStore.shared)
    .frame(width: 440, height: 500)
}
