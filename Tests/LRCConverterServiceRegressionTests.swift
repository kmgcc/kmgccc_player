//
//  LRCConverterServiceRegressionTests.swift
//  myPlayer2/Tests
//
//  Standalone regression checks for LRCConverterService.
//  Run with:
//    swiftc -parse-as-library myPlayer2/Services/LDDC/LRCConverterService.swift Tests/LRCConverterServiceRegressionTests.swift -o /tmp/lrc_regression && /tmp/lrc_regression
//

import Foundation

@main
struct LRCConverterServiceRegressionTests {
    static func main() async throws {
        try await testWordTimedLineWithAsteriskIsKept()
        try await testNearbyTranslationsAreKept()
        try await testEarlyTranslationOffsetFallback()
        try await testIntroCreditsAreStripped()
        try await testHyphenatedIntroAdlibsDoNotShiftTranslations()
        print("LRCConverterServiceRegressionTests passed")
    }

    private static func testWordTimedLineWithAsteriskIsKept() async throws {
        let original = """
        [00:32.330]But [00:32.480]if [00:32.600]I [00:32.750]could [00:32.930]ask [00:33.320]you [00:33.440]one [00:33.890]thing[00:34.580], [00:34.580]one [00:35.720]thing[00:36.710]?[00:36.710]
        [00:36.710]"[00:37.100]Why [00:37.280]can't [00:37.580]we [00:37.760]*[00:37.830]*[00:37.900]*[00:37.970]*[00:38.040]*[00:38.110]*[00:38.180]* [00:38.300]get [00:38.630]along[00:40.220]?[00:40.220]"[00:40.250]
        [00:40.640]Forget [00:41.360]everything [00:41.990]we [00:42.230]did [00:42.500]wrong[00:43.880]
        """
        let translation = """
        [00:32.180]但我能否请求你一件事 就一件事
        [00:36.930]为什么我们不能融洽相处？
        [00:40.350]忘记我们做过的一切错事
        """

        let ttml = try await LRCConverterService.shared.convertToTTMLWithTranslation(
            origContent: original,
            transContent: translation,
            stripMetadata: true
        )

        expect(ttml.contains("Why"), "Expected the word-timed line containing asterisk spans to be preserved")
        expect(ttml.contains("get</span>"), "Expected words after asterisk spans to be preserved")
        expect(ttml.contains("为什么我们不能融洽相处？"), "Expected translation for the preserved asterisk line")
    }

    private static func testNearbyTranslationsAreKept() async throws {
        let original = """
        [00:15.598]I'll [00:15.798]say [00:15.973]the [00:16.165]wrong [00:16.357]thing[00:16.759]
        [00:18.805]My [00:19.021]apartment's [00:19.403]been [00:19.714]shaking[00:20.378]
        [00:21.029]From [00:21.237]the [00:21.413]weight [00:21.589]of [00:21.782]a [00:21.957]heart [00:22.245]that's [00:22.453]breaking[00:23.060]
        """
        let translation = """
        [00:15.590]我怕说错什么话
        [00:18.800]感觉整个房间都在摇晃
        [00:21.020]因为心里承受了太多压力 几乎要崩溃
        """

        let ttml = try await LRCConverterService.shared.convertToTTMLWithTranslation(
            origContent: original,
            transContent: translation,
            stripMetadata: true
        )

        expect(ttml.contains("apartment&apos;s"), "Expected the middle word-timed lyric line to be preserved")
        expect(ttml.contains("感觉整个房间都在摇晃"), "Expected the middle translation line to be preserved")
    }

    private static func testEarlyTranslationOffsetFallback() async throws {
        let original = """
        [01:26.700]Rush [01:27.990]over[01:28.650], [01:28.650]rush [01:29.820]over [01:30.240]me[01:31.530]
        [01:31.560]Cause [01:32.160]I [01:32.520]will [01:32.970]miss [01:33.480]you[01:35.400]
        [01:38.790]Cause [01:39.570]I [01:39.930]will [01:40.350]miss [01:40.830]you[01:42.690]
        [02:03.450]Hold [02:04.560]on[02:05.880]
        [02:08.280]Cause [02:09.150]I [02:09.840]will [02:09.930]miss [02:10.410]you[02:14.610]
        """
        let translation = """
        [01:26.572]就请奔向我吧 奔我而来
        [01:32.071]因为我会对你思念成疾
        [01:39.316]因为我难以将你忘怀
        [01:57.821]坚守此刻
        [02:01.071]因为我会对你深深思念
        """

        let ttml = try await LRCConverterService.shared.convertToTTMLWithTranslation(
            origContent: original,
            transContent: translation,
            stripMetadata: true
        )

        expect(ttml.contains("坚守此刻"), "Expected early-offset Hold on translation to be matched")
        expect(ttml.contains("因为我会对你深深思念"), "Expected early-offset Cause translation to be matched")
    }

    private static func testIntroCreditsAreStripped() async throws {
        let original = """
        [ti:天空天空]
        [ar:刘思鉴]
        [00:00.000]天[00:01.322]空[00:01.825]天[00:01.862]空 [00:01.885]- [00:01.920]刘[00:01.943]思[00:01.991]鉴[00:02.026]
        [00:02.030]词 [00:02.054]Lyrics：[00:02.089]刘[00:02.112]思[00:02.152]鉴[00:02.187]
        [00:02.191]曲 [00:02.215]Composer：[00:02.262]刘[00:02.275]思[00:02.322]鉴[00:02.345]
        [00:02.774]钢[00:02.821]弦[00:02.845]吉[00:02.881]他 [00:02.904]Steel [00:02.939]Guitar：[00:02.986]John [00:02.998]Liu[00:03.046]
        [00:13.862]天[00:14.163]空[00:14.591]天[00:15.032]空[00:15.325]你[00:15.619]在[00:15.938]哪[00:16.619]
        """

        let ttml = try await LRCConverterService.shared.convertToTTML(
            lrcContent: original,
            stripMetadata: true
        )

        expect(!ttml.contains("Composer"), "Expected Composer credit line to be stripped")
        expect(!ttml.contains("Steel"), "Expected Steel Guitar credit line to be stripped")
        expect(ttml.contains(">天</span>"), "Expected real lyric content to remain")
    }

    private static func testHyphenatedIntroAdlibsDoNotShiftTranslations() async throws {
        let original = """
        [00:02.190]Noo[00:02.310]-[00:02.340]nah[00:02.670]-[00:02.730]nah[00:04.740]
        [00:06.360]Yeah[00:07.260]-[00:07.320]yeah[00:08.850]
        [00:08.850]Noo[00:10.470]-[00:10.560]nah[00:12.720]-[00:12.810]nah[00:13.200]
        [00:14.130]Yeah[00:15.780]
        [00:15.810]My [00:16.080]mama [00:16.500]called[00:17.760], [00:17.760]seen [00:18.180]you [00:18.330]on [00:18.480]TV[00:19.440], [00:19.440]son[00:19.740]
        [00:19.740]Said [00:20.070]*[00:20.070]*[00:20.070]*[00:20.070]*[00:20.070]*[00:20.070]*[00:20.070]*[00:20.070]t [00:20.220]done [00:20.460]changed [00:22.080]ever [00:22.290]since [00:22.740]we [00:22.920]was [00:23.520]on[00:23.730]
        [00:23.730]I [00:23.880]dreamed [00:24.270]it [00:24.480]all [00:25.920]ever [00:26.220]since [00:26.670]I [00:26.850]was [00:27.360]young[00:27.600]
        """
        let translation = """
        [00:02.560]孬 呐呐
        [00:06.750]耶耶
        [00:10.400]孬 呐呐
        [00:14.550]耶
        [00:16.260]老妈来电话说在电视上看见你了儿子
        [00:20.110]她说在电视上看见你们觉得你们变了许多
        [00:24.010]我小时候就梦想着这一切
        """

        let ttml = try await LRCConverterService.shared.convertToTTMLWithTranslation(
            origContent: original,
            transContent: translation,
            stripMetadata: true
        )

        expect(paragraph(containing: "Noo", in: ttml)?.contains("孬 呐呐") == true,
               "Expected hyphenated Noo-nah intro line to be kept with its translation")
        expect(ttml.components(separatedBy: "孬 呐呐").count - 1 == 2,
               "Expected both Noo-nah intro translations to be preserved")
        expect(paragraph(containing: "mama", in: ttml)?.contains("老妈来电话说在电视上看见你了儿子") == true,
               "Expected My mama line to keep its own translation")
        expect(paragraph(containing: "Said", in: ttml)?.contains("她说在电视上看见你们觉得你们变了许多") == true,
               "Expected Said line to keep its own translation")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            fputs("FAIL: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func paragraph(containing text: String, in ttml: String) -> String? {
        var searchStart = ttml.startIndex
        while let openRange = ttml.range(of: "<p", range: searchStart..<ttml.endIndex),
              let closeRange = ttml.range(of: "</p>", range: openRange.lowerBound..<ttml.endIndex) {
            let paragraphRange = openRange.lowerBound..<closeRange.upperBound
            let candidate = String(ttml[paragraphRange])
            if candidate.contains(text) {
                return candidate
            }
            searchStart = closeRange.upperBound
        }
        return nil
    }
}
