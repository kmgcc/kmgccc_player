//
//  HighRefreshRateWebViewConfigurator.swift
//  myPlayer2
//
//  Best-effort WebKit configuration for display-native rendering updates.
//

import Foundation
import ObjectiveC.runtime
import WebKit

@MainActor
enum HighRefreshRateWebViewConfigurator {
    private static let targetFeatureKey = "PreferPageRenderingUpdatesNear60FPSEnabled"

    private enum SPISelector {
        static let features = NSSelectorFromString("_features")
        static let featureKey = NSSelectorFromString("key")
        static let setEnabled = NSSelectorFromString("_setEnabled:forFeature:")
        static let isEnabled = NSSelectorFromString("_isEnabledForFeature:")
    }

    private typealias FeatureListGetter = @convention(c) (
        AnyClass,
        Selector
    ) -> Unmanaged<AnyObject>
    private typealias FeatureSetter = @convention(c) (
        AnyObject,
        Selector,
        Bool,
        AnyObject
    ) -> Void
    private typealias FeatureStateGetter = @convention(c) (
        AnyObject,
        Selector,
        AnyObject
    ) -> Bool

    /// Disables WebKit's near-60 FPS preference before the first page load.
    /// Returns `false` when the private runtime surface is unavailable or a
    /// runtime readback confirms that the preference remains enabled.
    @discardableResult
    static func enableHighRefreshRate(in configuration: WKWebViewConfiguration) -> Bool {
        let preferencesClass: AnyClass = WKPreferences.self
        guard let preferencesMetaclass = object_getClass(preferencesClass),
              class_respondsToSelector(preferencesMetaclass, SPISelector.features)
        else {
            Log.warning(
                "[HighRefreshRateWebView] feature-list selector unavailable; using WebKit default refresh rate",
                category: .webview
            )
            return false
        }

        let listGetter = unsafeBitCast(
            class_getMethodImplementation(preferencesMetaclass, SPISelector.features),
            to: FeatureListGetter.self
        )
        let featureListObject = listGetter(
            preferencesClass,
            SPISelector.features
        ).takeUnretainedValue()
        guard let featureList = featureListObject as? NSArray else {
            Log.warning(
                "[HighRefreshRateWebView] feature-list selector returned an unexpected value; using WebKit default refresh rate",
                category: .webview
            )
            return false
        }

        let targetFeature = featureList
            .compactMap { $0 as? NSObject }
            .first { feature in
                guard feature.responds(to: SPISelector.featureKey),
                      let key = feature.perform(SPISelector.featureKey)?
                        .takeUnretainedValue() as? String
                else {
                    return false
                }
                return key == targetFeatureKey
            }

        guard let targetFeature else {
            Log.warning(
                "[HighRefreshRateWebView] feature not found: \(targetFeatureKey); using WebKit default refresh rate",
                category: .webview
            )
            return false
        }

        let preferences = configuration.preferences
        guard preferences.responds(to: SPISelector.setEnabled) else {
            Log.warning(
                "[HighRefreshRateWebView] feature found but setter selector unavailable; using WebKit default refresh rate",
                category: .webview
            )
            return false
        }

        let setter = unsafeBitCast(
            preferences.method(for: SPISelector.setEnabled),
            to: FeatureSetter.self
        )
        setter(preferences, SPISelector.setEnabled, false, targetFeature)

        guard preferences.responds(to: SPISelector.isEnabled) else {
            Log.info(
                "[HighRefreshRateWebView] feature found and setter invoked; verification selector unavailable",
                category: .webview
            )
            return true
        }

        let stateGetter = unsafeBitCast(
            preferences.method(for: SPISelector.isEnabled),
            to: FeatureStateGetter.self
        )
        guard !stateGetter(preferences, SPISelector.isEnabled, targetFeature) else {
            Log.warning(
                "[HighRefreshRateWebView] feature found and setter invoked, but the 60 FPS preference remains enabled; using WebKit default refresh rate",
                category: .webview
            )
            return false
        }

        Log.info(
            "[HighRefreshRateWebView] feature found; setter invoked; 60 FPS preference disabled",
            category: .webview
        )
        return true
    }
}
