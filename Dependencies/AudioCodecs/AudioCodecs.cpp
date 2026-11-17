// SPDX-License-Identifier: AGPL-3.0-or-later
// Bundle-owned decoding boundary. Each handle belongs to one serial consumer.
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/codec_desc.h>
#include <libavformat/avformat.h>
#include <libavutil/base64.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libsacd/sacd.h>
#include <libswresample/swresample.h>
#include <wavpack.h>
}
namespace {
std::string quote(const std::string &s) {
  std::ostringstream out;
  out << '"';
  for (unsigned char c : s) {
    switch (c) {
    case '"':
      out << "\\\"";
      break;
    case '\\':
      out << "\\\\";
      break;
    case '\n':
      out << "\\n";
      break;
    case '\r':
      out << "\\r";
      break;
    case '\t':
      out << "\\t";
      break;
    default:
      if (c < 32) {
        const char *hex = "0123456789abcdef";
        out << "\\u00" << hex[c >> 4] << hex[c & 15];
      } else
        out << c;
    }
  }
  out << '"';
  return out.str();
}
void require(int code, const char *context) {
  if (code < 0) {
    char message[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(code, message, sizeof(message));
    throw std::runtime_error(std::string(context) + ": " + message);
  }
}
struct Decoder {
  AVFormatContext *format = nullptr;
  AVCodecContext *codec = nullptr;
  SwrContext *resampler = nullptr;
  AVPacket *packet = av_packet_alloc();
  AVFrame *frame = av_frame_alloc();
  WavpackContext *wavpack = nullptr;
  sacd_t *sacd = nullptr;
  int stream = -1, rate = 0, channels = 0, sourceRate = 0, bits = 0, area = 0;
  uint32_t sacdStart = 0, sacdLength = 0, sacdPosition = 0;
  int64_t length = 0, target = 0, convertedPosition = 0;
  int wavpackRate = 0, wavpackBits = 0;
  bool eof = false, drained = false, isDSD = false, isWMA = false, positionPending = false;
  std::vector<float> pending;
  size_t pendingOffset = 0;
  std::string json;
  ~Decoder() {
    if (wavpack)
      WavpackCloseFile(wavpack);
    if (sacd)
      sacd_destroy(sacd);
    swr_free(&resampler);
    avcodec_free_context(&codec);
    avformat_close_input(&format);
    av_packet_free(&packet);
    av_frame_free(&frame);
  }
  std::string tag(const char *key) const {
    AVDictionaryEntry *entry =
        format ? av_dict_get(format->metadata, key, nullptr, 0) : nullptr;
    if (!entry && format && std::string(key) == "album_artist") {
      entry = av_dict_get(format->metadata, "Album Artist", nullptr, 0);
      if (!entry)
        entry = av_dict_get(format->metadata, "albumartist", nullptr, 0);
    }
    return entry ? entry->value : "";
  }
  std::string albumText(album_text_type_t type) const {
    const char *value = nullptr;
    if (sacd_get_album_text(sacd, 1, type, &value) != SACD_OK || !value)
      return "";
    return value;
  }
  std::string trackText(int number, track_type_t type) const {
    const char *value = nullptr;
    if (sacd_get_track_text(sacd, number, 1, type, &value) != SACD_OK || !value)
      return "";
    return value;
  }
  void configureResampler() {
    AVChannelLayout layout{};
    av_channel_layout_copy(&layout, &codec->ch_layout);
    require(swr_alloc_set_opts2(&resampler, &layout, AV_SAMPLE_FMT_FLT, rate,
                                &codec->ch_layout, codec->sample_fmt,
                                codec->sample_rate, 0, nullptr),
            "Create resampler");
    av_channel_layout_uninit(&layout);
    require(swr_init(resampler), "Initialize resampler");
  }
  void open(const char *path, int requestedArea, int track) {
    std::string extension = path;
    auto dot = extension.find_last_of('.');
    extension = dot == std::string::npos ? "" : extension.substr(dot + 1);
    std::transform(extension.begin(), extension.end(), extension.begin(),
                   ::tolower);
    if (!packet || !frame)
      throw std::bad_alloc();
    if (extension == "iso")
      openSACD(path, requestedArea, track);
    else if (extension == "wv")
      openWavPack(path);
    else
      openAV(path);
    if (rate <= 0 || channels <= 0 || channels > 32 || length <= 0)
      throw std::runtime_error("Audio has no valid sample range");
  }
  void openAV(const char *path) {
    require(avformat_open_input(&format, path, nullptr, nullptr), "Open audio");
    require(avformat_find_stream_info(format, nullptr), "Read streams");
    stream =
        av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
    require(stream, "Find audio stream");
    auto parameters = format->streams[stream]->codecpar;
    const AVCodec *implementation = avcodec_find_decoder(parameters->codec_id);
    if (!implementation)
      throw std::runtime_error("Audio decoder is unavailable");
    codec = avcodec_alloc_context3(implementation);
    if (!codec)
      throw std::bad_alloc();
    require(avcodec_parameters_to_context(codec, parameters),
            "Read audio parameters");
    require(avcodec_open2(codec, implementation, nullptr), "Open decoder");
    channels = codec->ch_layout.nb_channels;
    isDSD = parameters->codec_id == AV_CODEC_ID_DSD_LSBF ||
            parameters->codec_id == AV_CODEC_ID_DSD_MSBF ||
            parameters->codec_id == AV_CODEC_ID_DSD_LSBF_PLANAR ||
            parameters->codec_id == AV_CODEC_ID_DSD_MSBF_PLANAR ||
            parameters->codec_id == AV_CODEC_ID_DST;
    isWMA = parameters->codec_id == AV_CODEC_ID_WMAV1 ||
            parameters->codec_id == AV_CODEC_ID_WMAV2 ||
            parameters->codec_id == AV_CODEC_ID_WMAPRO ||
            parameters->codec_id == AV_CODEC_ID_WMALOSSLESS ||
            parameters->codec_id == AV_CODEC_ID_WMAVOICE;
    sourceRate = codec->sample_rate * (isDSD ? 8 : 1);
    rate = isDSD ? 176400 : codec->sample_rate;
    if (codec->sample_rate <= 0 || channels <= 0 || channels > 32)
      throw std::runtime_error("Audio parameters are invalid");
    bits = isDSD ? 1 : parameters->bits_per_raw_sample;
    if (!bits)
      bits = av_get_bits_per_sample(parameters->codec_id);
    if (!bits && parameters->codec_id == AV_CODEC_ID_WMALOSSLESS)
      bits = parameters->bits_per_coded_sample;
    const auto audioStream = format->streams[stream];
    double duration =
        audioStream->duration != AV_NOPTS_VALUE
            ? audioStream->duration * av_q2d(audioStream->time_base)
            : double(format->duration) / AV_TIME_BASE;
    if (std::string(format->iformat->name) == "dsf") {
      const int64_t savedPosition = avio_tell(format->pb);
      if (avio_seek(format->pb, 64, SEEK_SET) < 0)
        throw std::runtime_error("Cannot read DSF sample count");
      const uint64_t samples = avio_rl64(format->pb);
      if (!samples || samples > INT64_MAX)
        throw std::runtime_error("DSF sample count is invalid");
      duration = double(samples) / sourceRate;
      if (avio_seek(format->pb, savedPosition, SEEK_SET) < 0)
        throw std::runtime_error("Cannot restore DSF read position");
    }
    if (!std::isfinite(duration) || duration <= 0 ||
        duration > double(INT64_MAX) / rate) {
      throw std::runtime_error("Audio duration is invalid");
    }
    length = std::llround(duration * rate);
    if (parameters->initial_padding > 0 && !isDSD)
      length -= parameters->initial_padding;
    configureResampler();
    if (isWMA) {
      // ASF timestamps use milliseconds and include codec delay. Count the
      // decoded program once to publish an exact logical range.
      std::vector<float> scratch(size_t(32768) * channels);
      int count = 0;
      int64_t decodedLength = 0;
      while ((count = read(scratch.data(), 32768)) > 0)
        decodedLength += count;
      length = decodedLength;
      seek(0);
    }
    std::ostringstream out;
    out << "{\"sampleRate\":" << rate << ",\"sourceSampleRate\":" << sourceRate
        << ",\"channels\":" << channels << ",\"bitDepth\":" << bits
        << ",\"frames\":" << length
        << ",\"codec\":" << quote(avcodec_get_name(parameters->codec_id));
    const auto descriptor = avcodec_descriptor_get(parameters->codec_id);
    if (descriptor)
      out << ",\"lossless\":"
          << ((isDSD || (descriptor->props & AV_CODEC_PROP_LOSSLESS)) ? "true" : "false");
    if (codec->ch_layout.order == AV_CHANNEL_ORDER_NATIVE)
      out << ",\"channelMask\":" << codec->ch_layout.u.mask;
    for (auto key :
         {"title", "artist", "album", "album_artist", "lyrics", "cuesheet",
          "track", "date", "musicbrainz_albumid", "compilation"})
      out << ',' << quote(key) << ':' << quote(tag(key));
    for (unsigned i = 0; i < format->nb_streams; i++) {
      auto picture = format->streams[i];
      if ((picture->disposition & AV_DISPOSITION_ATTACHED_PIC) &&
          picture->attached_pic.size > 0 &&
          picture->attached_pic.size <= 16 * 1024 * 1024) {
        std::vector<char> encoded(AV_BASE64_SIZE(picture->attached_pic.size));
        av_base64_encode(encoded.data(), int(encoded.size()),
                         picture->attached_pic.data,
                         picture->attached_pic.size);
        out << ",\"artwork\":" << quote(encoded.data());
        break;
      }
    }
    out << '}';
    json = out.str();
  }
  void openWavPack(const char *path) {
    char error[256] = {};
    wavpack = WavpackOpenFileInput(
        path, error, OPEN_WVC | OPEN_TAGS | OPEN_NORMALIZE | OPEN_DSD_AS_PCM,
        0);
    if (!wavpack)
      throw std::runtime_error(error);
    wavpackRate = WavpackGetSampleRate(wavpack);
    sourceRate = WavpackGetNativeSampleRate(wavpack);
    isDSD = sourceRate != wavpackRate;
    rate = isDSD ? 176400 : wavpackRate;
    channels = WavpackGetNumChannels(wavpack);
    wavpackBits = WavpackGetBitsPerSample(wavpack);
    if (wavpackRate <= 0 || channels <= 0 || channels > 32)
      throw std::runtime_error("WavPack parameters are invalid");
    bits = isDSD ? 1 : wavpackBits;
    length = av_rescale_q(WavpackGetNumSamples64(wavpack),
                          AVRational{1, wavpackRate}, AVRational{1, rate});
    if (isDSD)
      configureWavPackResampler();
    std::ostringstream out;
    out << "{\"sampleRate\":" << rate << ",\"sourceSampleRate\":" << sourceRate
        << ",\"channels\":" << channels << ",\"bitDepth\":" << bits
        << ",\"frames\":" << length << ",\"codec\":\"wavpack\",\"lossless\":"
        << ((WavpackGetMode(wavpack) & MODE_LOSSLESS) ? "true" : "false");
    out << ",\"channelMask\":" << uint32_t(WavpackGetChannelMask(wavpack));
    for (auto key : {"Title", "Artist", "Album", "Album Artist", "Lyrics",
                     "Track", "Year", "MUSICBRAINZ_ALBUMID"}) {
      int size = WavpackGetTagItem(wavpack, key, nullptr, 0);
      if (size > 0 && size < 1024 * 1024) {
        std::vector<char> value(size + 1);
        WavpackGetTagItem(wavpack, key, value.data(), size + 1);
        std::string name = key;
        std::transform(name.begin(), name.end(), name.begin(), ::tolower);
        if (name == "album artist")
          name = "album_artist";
        if (name == "year")
          name = "date";
        out << ',' << quote(name) << ':' << quote(value.data());
      }
    }
    int pictureSize =
        WavpackGetBinaryTagItem(wavpack, "Cover Art (Front)", nullptr, 0);
    if (pictureSize > 0 && pictureSize <= 16 * 1024 * 1024) {
      std::vector<char> picture(pictureSize);
      if (WavpackGetBinaryTagItem(wavpack, "Cover Art (Front)", picture.data(),
                                  pictureSize) == pictureSize) {
        auto start = std::find(picture.begin(), picture.end(), '\0');
        if (start != picture.end() && ++start != picture.end()) {
          int size = int(picture.end() - start);
          std::vector<char> encoded(AV_BASE64_SIZE(size));
          av_base64_encode(encoded.data(), int(encoded.size()),
                           reinterpret_cast<const uint8_t *>(&*start), size);
          out << ",\"artwork\":" << quote(encoded.data());
        }
      }
    }
    out << '}';
    json = out.str();
  }
  void openSACD(const char *path, int requestedArea, int number) {
    sacd = sacd_create();
    if (!sacd)
      throw std::bad_alloc();
    if (sacd_init(sacd, path, 1, 1) != SACD_OK)
      throw std::runtime_error("Cannot read SACD image");
    channel_t areas[2];
    uint16_t count = 2;
    if (sacd_get_available_channel_types(sacd, areas, &count) != SACD_OK ||
        !count)
      throw std::runtime_error("SACD contains no audio area");
    area = requestedArea;
    if (requestedArea < 0) {
      area = areas[0];
      for (unsigned i = 0; i < count; i++)
        if (areas[i] == TWO_CHANNEL)
          area = TWO_CHANNEL;
    }
    if (sacd_select_channel_type(sacd, static_cast<channel_t>(area)) != SACD_OK)
      throw std::runtime_error("SACD audio area is unavailable");
    uint16_t channelCount = 0;
    uint8_t tracks = 0;
    sacd_get_area_channel_count(sacd, &channelCount);
    sacd_get_track_count(sacd, &tracks);
    bool wholeArea = number == 0;
    number = number > 0 ? number : 1;
    if (number > tracks)
      throw std::runtime_error("SACD track is unavailable");
    sacd_get_track_index_start(sacd, number, 1, &sacdStart);
    sacd_get_track_frame_length(sacd, number, &sacdLength);
    if (wholeArea) {
      uint32_t lastStart = 0, lastLength = 0;
      sacd_get_track_index_start(sacd, tracks, 1, &lastStart);
      sacd_get_track_frame_length(sacd, tracks, &lastLength);
      sacdLength = lastStart + lastLength - sacdStart;
    }
    channels = channelCount;
    if (channels <= 0 || channels > MAX_CHANNEL_COUNT)
      throw std::runtime_error("SACD channel layout is invalid");
    rate = 176400;
    sourceRate = 2822400;
    bits = 1;
    isDSD = true;
    length = int64_t(sacdLength) * rate / 75;
    frame_format_t encoding;
    sacd_get_area_frame_format_enum(sacd, &encoding);
    const AVCodec *implementation = avcodec_find_decoder(
        encoding == FRAME_FORMAT_DST ? AV_CODEC_ID_DST : AV_CODEC_ID_DSD_MSBF);
    if (!implementation)
      throw std::runtime_error("SACD audio decoder is unavailable");
    codec = avcodec_alloc_context3(implementation);
    if (!codec)
      throw std::bad_alloc();
    codec->sample_rate = 352800;
    av_channel_layout_default(&codec->ch_layout, channels);
    require(avcodec_open2(codec, implementation, nullptr), "Open SACD decoder");
    configureResampler();
    const auto album = albumText(ALBUM_TEXT_TYPE_TITLE),
               artist = albumText(ALBUM_TEXT_TYPE_ARTIST);
    std::ostringstream out;
    out << "{\"sampleRate\":" << rate << ",\"sourceSampleRate\":" << sourceRate
        << ",\"channels\":" << channels
        << ",\"bitDepth\":1,\"frames\":" << length
        << ",\"codec\":" << quote(encoding == FRAME_FORMAT_DST ? "DST" : "DSD")
        << ",\"album\":" << quote(album)
        << ",\"album_artist\":" << quote(artist)
        << ",\"title\":" << quote(trackText(number, TRACK_TYPE_TITLE))
        << ",\"artist\":" << quote(trackText(number, TRACK_TYPE_PERFORMER))
        << ",\"channelMask\":" << codec->ch_layout.u.mask
        << ",\"lossless\":true,\"programStart\":" << sacdStart
        << ",\"area\":" << area << ",\"availableAreas\":[";
    for (unsigned i = 0; i < count; i++) {
      if (i)
        out << ',';
      out << int(areas[i]);
    }
    out << "],\"tracks\":[";
    for (int i = 1; i <= tracks; i++) {
      uint32_t duration = 0, start = 0;
      sacd_get_track_frame_length(sacd, i, &duration);
      sacd_get_track_index_start(sacd, i, 1, &start);
      if (i > 1)
        out << ',';
      out << "{\"number\":" << i
          << ",\"title\":" << quote(trackText(i, TRACK_TYPE_TITLE))
          << ",\"artist\":" << quote(trackText(i, TRACK_TYPE_PERFORMER))
          << ",\"start\":" << start << ",\"length\":" << duration << '}';
    }
    out << "]}";
    json = out.str();
  }
  bool nextPacket() {
    av_packet_unref(packet);
    if (sacd) {
      if (sacdPosition >= sacdLength)
        return false;
      require(av_new_packet(packet, SACD_MAX_DST_SIZE + MAX_CHANNEL_COUNT),
              "Allocate SACD packet");
      uint32_t count = 1;
      uint16_t size = 0;
      const uint32_t absoluteFrame = sacdStart + sacdPosition;
      int status = sacd_get_sound_data(sacd, packet->data, absoluteFrame,
                                       &count, &size);
      if (status != SACD_OK || count != 1 || !size)
        throw std::runtime_error("Cannot read SACD audio frame " +
                                 std::to_string(absoluteFrame) + " (" +
                                 std::to_string(status) + ")");
      packet->size = size;
      packet->pts = int64_t(sacdPosition) * 352800 / 75;
      sacdPosition++;
      return true;
    }
    for (;;) {
      int result = av_read_frame(format, packet);
      if (result == AVERROR_EOF)
        return false;
      require(result, "Read audio packet");
      if (packet->stream_index == stream)
        return true;
      av_packet_unref(packet);
    }
  }
  void configureWavPackResampler() {
    AVChannelLayout layout{};
    uint64_t mask = uint32_t(WavpackGetChannelMask(wavpack));
    if (mask)
      require(av_channel_layout_from_mask(&layout, mask),
              "Read WavPack channel layout");
    else
      av_channel_layout_default(&layout, channels);
    require(swr_alloc_set_opts2(&resampler, &layout, AV_SAMPLE_FMT_FLT, rate,
                                &layout, AV_SAMPLE_FMT_FLT, wavpackRate, 0,
                                nullptr),
            "Create WavPack conversion");
    av_channel_layout_uninit(&layout);
    require(swr_init(resampler), "Initialize WavPack conversion");
  }
  int readWavPackPCM(float *output, int maximum) {
    std::vector<int32_t> raw(size_t(maximum) * channels);
    int count = WavpackUnpackSamples(wavpack, raw.data(), maximum);
    if (WavpackGetNumErrors(wavpack))
      throw std::runtime_error("WavPack decode failed");
    bool floating = WavpackGetMode(wavpack) & MODE_FLOAT;
    double scale = std::ldexp(1.0, 1 - wavpackBits);
    for (int i = 0; i < count * channels; i++) {
      if (floating)
        std::memcpy(output + i, raw.data() + i, sizeof(float));
      else
        output[i] = float(raw[i] * scale);
    }
    return count;
  }
  void trimPending(int64_t start, int count) {
    convertedPosition = start + count;
    if (!positionPending)
      return;
    int64_t drop = std::clamp(target - start, int64_t(0), int64_t(count));
    pendingOffset = size_t(drop) * channels;
    if (convertedPosition > target)
      positionPending = false;
  }
  void flushResampler() {
    int capacity = swr_get_out_samples(resampler, 0);
    pending.resize(size_t(capacity) * channels);
    uint8_t *destination = reinterpret_cast<uint8_t *>(pending.data());
    int count = swr_convert(resampler, &destination, capacity, nullptr, 0);
    require(count, "Flush PCM conversion");
    pending.resize(size_t(count) * channels);
    trimPending(convertedPosition, count);
    drained = true;
  }
  int read(float *output, int maximum) {
    if (wavpack && !isDSD)
      return readWavPackPCM(output, maximum);
    int written = 0;
    while (written < maximum) {
      if (pendingOffset < pending.size()) {
        size_t n = std::min(pending.size() - pendingOffset,
                            size_t(maximum - written) * channels);
        std::copy_n(pending.data() + pendingOffset, n,
                    output + size_t(written) * channels);
        pendingOffset += n;
        written += int(n / channels);
        continue;
      }
      pending.clear();
      pendingOffset = 0;
      if (drained)
        break;
      if (wavpack) {
        std::vector<float> input(size_t(4096) * channels);
        int inputCount = readWavPackPCM(input.data(), 4096);
        if (!inputCount) {
          flushResampler();
          continue;
        }
        int capacity = swr_get_out_samples(resampler, inputCount);
        pending.resize(size_t(capacity) * channels);
        uint8_t *destination = reinterpret_cast<uint8_t *>(pending.data());
        const uint8_t *source = reinterpret_cast<const uint8_t *>(input.data());
        int count =
            swr_convert(resampler, &destination, capacity, &source, inputCount);
        require(count, "Convert WavPack DSD");
        pending.resize(size_t(count) * channels);
        trimPending(convertedPosition, count);
        continue;
      }
      int status = avcodec_receive_frame(codec, frame);
      if (status == AVERROR(EAGAIN)) {
        if (eof) {
          require(avcodec_send_packet(codec, nullptr), "Flush audio decoder");
        } else if (nextPacket())
          require(avcodec_send_packet(codec, packet), "Decode audio packet");
        else {
          eof = true;
          require(avcodec_send_packet(codec, nullptr), "Flush audio decoder");
        }
        continue;
      }
      if (status == AVERROR_EOF) {
        flushResampler();
        continue;
      }
      require(status, "Read decoded audio");
      int64_t delay = swr_get_delay(resampler, rate);
      int capacity = swr_get_out_samples(resampler, frame->nb_samples);
      pending.resize(size_t(capacity) * channels);
      uint8_t *destination = reinterpret_cast<uint8_t *>(pending.data());
      int count =
          swr_convert(resampler, &destination, capacity,
                      const_cast<const uint8_t **>(frame->extended_data),
                      frame->nb_samples);
      require(count, "Convert PCM");
      pending.resize(size_t(count) * channels);
      int64_t start = convertedPosition;
      if (sacd)
        start = int64_t(sacdPosition - 1) * rate / 75 - delay;
      else if (!isWMA && frame->best_effort_timestamp != AV_NOPTS_VALUE) {
        auto audioStream = format->streams[stream];
        int64_t origin = audioStream->start_time == AV_NOPTS_VALUE
                             ? 0
                             : audioStream->start_time;
        start = av_rescale_q(frame->best_effort_timestamp - origin,
                             audioStream->time_base, AVRational{1, rate}) -
                delay;
      }
      trimPending(start, count);
      av_frame_unref(frame);
    }
    return written;
  }
  void seek(int64_t position) {
    if (position < 0 || position > length)
      throw std::runtime_error("Audio seek is outside its range");
    int64_t preroll = isWMA ? 0 : std::max<int64_t>(0, position - rate / 4);
    if (wavpack) {
      int64_t sourcePosition = isDSD
                                   ? av_rescale_q(preroll, AVRational{1, rate},
                                                  AVRational{1, wavpackRate})
                                   : position;
      if (!WavpackSeekSample64(wavpack, sourcePosition))
        throw std::runtime_error("WavPack seek failed");
      if (!isDSD)
        return;
      swr_free(&resampler);
      configureWavPackResampler();
      pending.clear();
      pendingOffset = 0;
      eof = drained = false;
      target = position;
      positionPending = position > 0;
      convertedPosition = preroll;
      return;
    }
    if (sacd)
      sacdPosition = uint32_t(preroll * 75 / rate);
    else {
      int64_t timestamp = av_rescale_q(preroll, AVRational{1, rate},
                                       format->streams[stream]->time_base);
      auto origin = format->streams[stream]->start_time;
      if (origin != AV_NOPTS_VALUE)
        timestamp += origin;
      require(avformat_seek_file(format, stream, INT64_MIN, timestamp,
                                 timestamp, AVSEEK_FLAG_BACKWARD),
              "Seek audio");
    }
    if (isDSD) {
      // The DSD and DST codecs keep their FIR history in private codec state.
      // Their FFmpeg implementation supplies no flush callback.
      auto parameters =
          std::unique_ptr<AVCodecParameters, void (*)(AVCodecParameters *)>(
              avcodec_parameters_alloc(), [](AVCodecParameters *value) {
                avcodec_parameters_free(&value);
              });
      if (!parameters)
        throw std::bad_alloc();
      require(avcodec_parameters_from_context(parameters.get(), codec),
              "Save DSD parameters");
      const AVCodec *implementation = codec->codec;
      avcodec_free_context(&codec);
      codec = avcodec_alloc_context3(implementation);
      if (!codec)
        throw std::bad_alloc();
      require(avcodec_parameters_to_context(codec, parameters.get()),
              "Restore DSD parameters");
      require(avcodec_open2(codec, implementation, nullptr),
              "Reset DSD conversion");
    } else {
      avcodec_flush_buffers(codec);
    }
    av_frame_unref(frame);
    swr_free(&resampler);
    configureResampler();
    pending.clear();
    pendingOffset = 0;
    eof = drained = false;
    target = position;
    convertedPosition = preroll;
    positionPending = position > 0;
  }
};
thread_local std::string lastError;
} // namespace
extern "C" {
__attribute__((visibility("default"))) void *
kmg_audio_open(const char *path, int area, int track) {
  try {
    auto decoder = std::make_unique<Decoder>();
    decoder->open(path, area, track);
    return decoder.release();
  } catch (const std::exception &e) {
    lastError = e.what();
    return nullptr;
  }
}
__attribute__((visibility("default"))) const char *
kmg_audio_info(void *handle) {
  return static_cast<Decoder *>(handle)->json.c_str();
}
__attribute__((visibility("default"))) int
kmg_audio_read(void *handle, float *output, int frames) {
  try {
    return static_cast<Decoder *>(handle)->read(output, frames);
  } catch (const std::exception &e) {
    lastError = e.what();
    return -1;
  }
}
__attribute__((visibility("default"))) int kmg_audio_seek(void *handle,
                                                          int64_t position) {
  try {
    static_cast<Decoder *>(handle)->seek(position);
    return 0;
  } catch (const std::exception &e) {
    lastError = e.what();
    return -1;
  }
}
__attribute__((visibility("default"))) const char *kmg_audio_error() {
  return lastError.c_str();
}
__attribute__((visibility("default"))) void kmg_audio_close(void *handle) {
  delete static_cast<Decoder *>(handle);
}
}
