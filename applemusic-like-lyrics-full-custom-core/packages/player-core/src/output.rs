#![allow(unused)]

use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU8},
    },
    time::Duration,
};

use super::resampler::SincFixedOutResampler;
use anyhow::Context;
use cpal::{traits::*, *};
use rb::*;
use symphonia::core::{
    audio::{AsAudioBufferRef, AudioBuffer, AudioBufferRef, Channels, RawSample, SignalSpec},
    conv::{ConvertibleSample, IntoSample},
};
use tokio::sync::mpsc::Sender;
use tracing::*;

pub trait AudioOutput {
    fn get_sample_name(&self) -> &'static str;
    fn stream_config(&self) -> &StreamConfig;
    fn sample_format(&self) -> SampleFormat;
    fn stream(&self) -> &Stream;
    fn is_dead(&self) -> bool;
    fn stream_mut(&mut self) -> &mut Stream;
    fn set_volume(&mut self, volume: f64);
    fn volume(&self) -> f64;
    fn write(&mut self, decoded: symphonia::core::audio::AudioBufferRef<'_>);
    fn flush(&mut self);
}

pub struct AudioStreamPlayer<T: AudioOutputSample> {
    config: StreamConfig,
    sample_format: SampleFormat,
    stream: Stream,
    is_dead: Arc<AtomicBool>,
    prod: rb::Producer<T>,
    volume: Arc<std::sync::atomic::AtomicU32>,
    resampler: Option<SincFixedOutResampler<T>>,
    resampler_target_channels: usize,
    resampler_duration: usize,
    resampler_spec: SignalSpec,
}

pub trait AudioOutputSample:
    SizedSample
    + ConvertibleSample
    + IntoSample<f32>
    + RawSample
    + std::marker::Send
    + Default
    + 'static
{
}

impl AudioOutputSample for i8 {}
impl AudioOutputSample for i16 {}
impl AudioOutputSample for i32 {}
// impl AudioOutputSample for i64 {}
impl AudioOutputSample for u8 {}
impl AudioOutputSample for u16 {}
impl AudioOutputSample for u32 {}
// impl AudioOutputSample for u64 {}
impl AudioOutputSample for f32 {}
impl AudioOutputSample for f64 {}

impl<T: AudioOutputSample> AudioOutput for AudioStreamPlayer<T> {
    fn get_sample_name(&self) -> &'static str {
        std::any::type_name::<T>()
    }

    fn stream_config(&self) -> &StreamConfig {
        &self.config
    }

    fn sample_format(&self) -> SampleFormat {
        self.sample_format
    }

    fn stream(&self) -> &Stream {
        &self.stream
    }

    fn stream_mut(&mut self) -> &mut Stream {
        &mut self.stream
    }

    fn is_dead(&self) -> bool {
        self.is_dead.load(std::sync::atomic::Ordering::SeqCst)
    }

    fn set_volume(&mut self, volume: f64) {
        let volume_f32 = volume as f32;
        self.volume
            .store(volume_f32.to_bits(), std::sync::atomic::Ordering::Relaxed);
    }

    fn volume(&self) -> f64 {
        let bits = self.volume.load(std::sync::atomic::Ordering::Relaxed);
        f32::from_bits(bits) as f64
    }

    fn write(&mut self, decoded: symphonia::core::audio::AudioBufferRef<'_>) {
        if decoded.frames() == 0 {
            return;
        }

        let should_replace_resampler = self.resampler.is_none()
            || self.resampler_duration != decoded.capacity()
            || &self.resampler_spec != decoded.spec()
            || self.resampler_target_channels != self.config.channels as usize;

        if should_replace_resampler {
            self.resampler = Some(SincFixedOutResampler::<T>::new_sinc_fixed(
                *decoded.spec(),
                self.config.sample_rate.0 as _,
                self.config.channels as _,
                decoded.capacity() as _,
            ));
            info!(
                "将会重采样 {}hz ({} channels) [{}] -> {}hz ({} channels) [{}]",
                decoded.spec().rate,
                decoded.spec().channels.count(),
                get_buffer_format(&decoded),
                self.config.sample_rate.0,
                self.config.channels,
                self.get_sample_name(),
            );
            self.resampler_duration = decoded.capacity();
            self.resampler_spec = *decoded.spec();
            self.resampler_target_channels = self.config.channels as _;
        }

        let rsp = self.resampler.as_mut().unwrap();

        rsp.resample(&decoded);

        while let Some(mut buf) = rsp.flush() {
            while let Ok(Some(written)) = self
                .prod
                .write_blocking_timeout(buf, Duration::from_secs(1))
            {
                buf = &buf[written..];
            }
        }
    }

    fn flush(&mut self) {}
}

fn get_buffer_format(decoded: &symphonia::core::audio::AudioBufferRef<'_>) -> &'static str {
    match decoded {
        symphonia::core::audio::AudioBufferRef::U8(_) => "u8",
        symphonia::core::audio::AudioBufferRef::U16(_) => "u16",
        symphonia::core::audio::AudioBufferRef::U24(_) => "u24",
        symphonia::core::audio::AudioBufferRef::U32(_) => "u32",
        symphonia::core::audio::AudioBufferRef::S8(_) => "i8",
        symphonia::core::audio::AudioBufferRef::S16(_) => "i16",
        symphonia::core::audio::AudioBufferRef::S24(_) => "i24",
        symphonia::core::audio::AudioBufferRef::S32(_) => "i32",
        symphonia::core::audio::AudioBufferRef::F32(_) => "f32",
        symphonia::core::audio::AudioBufferRef::F64(_) => "f64",
    }
}

#[instrument(skip(output))]
fn init_audio_stream_inner<T: AudioOutputSample + Into<f64>>(
    output: Device,
    ring_buf_size_ms: usize,
    selected_config: StreamConfig,
) -> Box<dyn AudioOutput> {
    let channels = selected_config.channels as usize;
    let ring_len = ((ring_buf_size_ms * selected_config.sample_rate.0 as usize) / 1000) * channels;
    info!(
        "音频输出流环缓冲区大小为 {} 个样本（约为 {}ms 的缓冲）",
        ring_len, ring_buf_size_ms
    );
    let ring = rb::SpscRb::<T>::new(ring_len);
    let prod = ring.producer();
    let mut cons = ring.consumer();
    let is_dead = Arc::new(AtomicBool::new(false));
    let is_dead_c = Arc::clone(&is_dead);
    let volume: Arc<_> = Arc::new(std::sync::atomic::AtomicU32::new((0.5f32).to_bits()));
    let volume_c = volume.clone();
    let mut is_drained = false;

    let mut current_vol = f32::from_bits(volume_c.load(std::sync::atomic::Ordering::Relaxed));

    let stream = output
        .build_output_stream::<T, _, _>(
            &selected_config,
            move |data: &mut [T], _info| {
                let read_len = cons.read(data).unwrap_or(0);

                if read_len > 0 {
                    is_drained = false;

                    let target_vol_bits = volume_c.load(std::sync::atomic::Ordering::Relaxed);
                    let target_vol = f32::from_bits(target_vol_bits);

                    if (target_vol - current_vol).abs() < 1e-6 {
                         if (target_vol - 1.0).abs() > 1e-6 {
                            for sample in data[..read_len].iter_mut() {
                                let s: f32 = (*sample).into_sample();
                                *sample = (s * target_vol).into_sample();
                            }
                        }
                    } else {
                        let frame_count = read_len / channels;
                        if frame_count > 0 {
                            let vol_increment_per_frame = (target_vol - current_vol) / (frame_count as f32);

                            for i in 0..frame_count {
                                current_vol += vol_increment_per_frame;
                                let frame_start = i * channels;
                                let frame_end = frame_start + channels;
                                for sample in data[frame_start..frame_end].iter_mut() {
                                    let s: f32 = (*sample).into_sample();
                                    *sample = (s * current_vol).into_sample();
                                }
                            }
                        }
                        current_vol = target_vol;
                    }
                    if read_len < data.len() {
                        data[read_len..].fill(T::MID);
                    }
                } else {
                    data.fill(T::MID);
                    if !is_drained {
                        is_drained = true;
                        warn!("音频输出流环缓冲区已耗尽（有可能是音频已暂停或音频流因卡顿受阻），正在等待数据填充");
                    }
                }
            },
            move |err| {
                warn!("[WARN][AT] {err}");
                is_dead_c.store(true, std::sync::atomic::Ordering::SeqCst);
            },
            None,
        )
        .unwrap();
    info!("音频输出流准备完毕！");
    Box::new(AudioStreamPlayer {
        config: selected_config,
        sample_format: <T as SizedSample>::FORMAT,
        stream,
        prod,
        is_dead,
        volume,
        resampler: None,
        resampler_duration: 0,
        resampler_target_channels: 0,
        resampler_spec: SignalSpec {
            rate: 0,
            channels: Channels::empty(),
        },
    })
}

fn get_sample_format_quality_level(sample_format: SampleFormat) -> u8 {
    match sample_format {
        SampleFormat::I8 | SampleFormat::U8 => 0,
        SampleFormat::I16 | SampleFormat::U16 => 1,
        SampleFormat::I32 | SampleFormat::U32 => 2,
        SampleFormat::I64 | SampleFormat::U64 => 3,
        SampleFormat::F32 => 4,
        SampleFormat::F64 => 5,
        _ => unreachable!(),
    }
}

#[instrument]
pub fn init_audio_player(
    output_device_name: &str,
    ring_buf_size_ms: Option<usize>,
) -> anyhow::Result<Box<dyn AudioOutput>> {
    let ring_buf_size_ms = ring_buf_size_ms.unwrap_or(100);
    let host = cpal::default_host();
    let output = if output_device_name.is_empty() {
        host.default_output_device().context("找不到默认输出设备")?
    } else {
        host.output_devices()
            .context("无法枚举输出设备")?
            .find(|d| d.name().unwrap_or_default() == output_device_name)
            .context("找不到指定的输出设备")?
    };

    info!(
        "已初始化输出音频设备为 {}",
        output.name().unwrap_or_default()
    );

    let supported_configs = output
        .supported_output_configs()
        .context("无法获取输出配置")?
        .collect::<Vec<_>>();

    let (selected_config, selected_sample_format) = supported_configs
        .into_iter()
        .filter_map(|config_range| {
            let channels = config_range.channels();
            if !(1..=2).contains(&channels) || config_range.max_sample_rate().0 < 22050 {
                return None;
            }

            let sample_rate = if (config_range.min_sample_rate().0
                ..=config_range.max_sample_rate().0)
                .contains(&48000)
            {
                SampleRate(48000)
            } else if (config_range.min_sample_rate().0..=config_range.max_sample_rate().0)
                .contains(&44100)
            {
                SampleRate(44100)
            } else {
                config_range.max_sample_rate()
            };

            let score = {
                let mut s = 0;
                if sample_rate.0 == 48000 {
                    s += 100;
                } else if sample_rate.0 == 44100 {
                    s += 90;
                }

                if channels == 2 {
                    s += 20;
                } else {
                    s += 10;
                }

                s += get_sample_format_quality_level(config_range.sample_format()) as i32 * 5;
                s
            };

            Some((score, config_range.with_sample_rate(sample_rate)))
        })
        .max_by_key(|(score, _)| *score)
        .map(|(_, config)| (config.config(), config.sample_format()))
        .context("未能找到任何适合播放的格式")?;

    info!(
        "尝试通过配置 {}hz {} 通道 {} 格式创建输出流",
        selected_config.sample_rate.0, selected_config.channels, selected_sample_format,
    );

    Ok((match selected_sample_format {
        SampleFormat::I8 => {
            init_audio_stream_inner::<i8>(output, ring_buf_size_ms, selected_config)
        }
        SampleFormat::I16 => {
            init_audio_stream_inner::<i16>(output, ring_buf_size_ms, selected_config)
        }
        SampleFormat::I32 => {
            init_audio_stream_inner::<i32>(output, ring_buf_size_ms, selected_config)
        }
        // SampleFormat::I64 => init_audio_stream_inner::<i64>(output, ring_buf_size_ms, selected_config),
        SampleFormat::U8 => {
            init_audio_stream_inner::<u8>(output, ring_buf_size_ms, selected_config)
        }
        SampleFormat::U16 => {
            init_audio_stream_inner::<u16>(output, ring_buf_size_ms, selected_config)
        }
        SampleFormat::U32 => {
            init_audio_stream_inner::<u32>(output, ring_buf_size_ms, selected_config)
        }
        // SampleFormat::U64 => init_audio_stream_inner::<u64>(output, ring_buf_size_ms, selected_config),
        SampleFormat::F32 => {
            init_audio_stream_inner::<f32>(output, ring_buf_size_ms, selected_config)
        }
        SampleFormat::F64 => {
            init_audio_stream_inner::<f64>(output, ring_buf_size_ms, selected_config)
        }
        _ => unreachable!(),
    }) as _)
}

pub enum OwnedAudioBuffer {
    U8(AudioBuffer<u8>),
    U16(AudioBuffer<u16>),
    U24(AudioBuffer<symphonia::core::sample::u24>),
    U32(AudioBuffer<u32>),
    S8(AudioBuffer<i8>),
    S16(AudioBuffer<i16>),
    S24(AudioBuffer<symphonia::core::sample::i24>),
    S32(AudioBuffer<i32>),
    F32(AudioBuffer<f32>),
    F64(AudioBuffer<f64>),
}

impl AsAudioBufferRef for OwnedAudioBuffer {
    fn as_audio_buffer_ref(&self) -> AudioBufferRef<'_> {
        match self {
            OwnedAudioBuffer::U8(x) => x.as_audio_buffer_ref(),
            OwnedAudioBuffer::U16(x) => x.as_audio_buffer_ref(),
            OwnedAudioBuffer::U24(x) => x.as_audio_buffer_ref(),
            OwnedAudioBuffer::U32(x) => x.as_audio_buffer_ref(),
            OwnedAudioBuffer::S8(x) => x.as_audio_buffer_ref(),
            OwnedAudioBuffer::S16(x) => x.as_audio_buffer_ref(),
            OwnedAudioBuffer::S24(x) => x.as_audio_buffer_ref(),
            OwnedAudioBuffer::S32(x) => x.as_audio_buffer_ref(),
            OwnedAudioBuffer::F32(x) => x.as_audio_buffer_ref(),
            OwnedAudioBuffer::F64(x) => x.as_audio_buffer_ref(),
        }
    }
}

enum AudioOutputMessage {
    ClearBuffer,
    ChangeOutput(String),
    ChangeRingBufSize(usize),
    SetVolume(f64),
}

#[derive(Debug, Clone)]
pub struct AudioOutputSender {
    sender: Sender<AudioOutputMessage>,
    pcm_sender: Sender<OwnedAudioBuffer>,
}

impl AudioOutputSender {
    pub async fn write_ref(&self, decoded: AudioBufferRef<'_>) -> anyhow::Result<()> {
        let buf = match decoded {
            AudioBufferRef::U8(x) => OwnedAudioBuffer::U8(x.into_owned()),
            AudioBufferRef::U16(x) => OwnedAudioBuffer::U16(x.into_owned()),
            AudioBufferRef::U24(x) => OwnedAudioBuffer::U24(x.into_owned()),
            AudioBufferRef::U32(x) => OwnedAudioBuffer::U32(x.into_owned()),
            AudioBufferRef::S8(x) => OwnedAudioBuffer::S8(x.into_owned()),
            AudioBufferRef::S16(x) => OwnedAudioBuffer::S16(x.into_owned()),
            AudioBufferRef::S24(x) => OwnedAudioBuffer::S24(x.into_owned()),
            AudioBufferRef::S32(x) => OwnedAudioBuffer::S32(x.into_owned()),
            AudioBufferRef::F32(x) => OwnedAudioBuffer::F32(x.into_owned()),
            AudioBufferRef::F64(x) => OwnedAudioBuffer::F64(x.into_owned()),
        };
        self.pcm_sender.send(buf).await?;
        Ok(())
    }

    pub async fn wait_empty(&self) {
        self.sender.reserve_many(self.sender.max_capacity()).await;
        self.pcm_sender
            .reserve_many(self.pcm_sender.max_capacity())
            .await;
    }

    pub async fn write(&self, decoded: OwnedAudioBuffer) -> anyhow::Result<()> {
        self.pcm_sender.send(decoded).await?;
        Ok(())
    }

    pub async fn set_volume(&self, volume: f64) -> anyhow::Result<()> {
        self.sender
            .send(AudioOutputMessage::SetVolume(volume))
            .await?;
        Ok(())
    }

    pub async fn clear_buffer(&self) -> anyhow::Result<()> {
        self.sender.send(AudioOutputMessage::ClearBuffer).await?;
        Ok(())
    }
}

// TODO: 允许指定需要的输出设备
pub fn create_audio_output_thread() -> AudioOutputSender {
    let (pcm_tx, mut pcm_rx) = tokio::sync::mpsc::channel::<OwnedAudioBuffer>(2);
    let (tx, mut msg_rx) = tokio::sync::mpsc::channel::<AudioOutputMessage>(128);
    let handle = tokio::runtime::Handle::current();

    let poll_default_tx = tx.clone();
    // 通过轮询检测是否需要重新创建音频输出设备流
    // TODO: 如果 CPAL 支持依照系统默认输出自动更新输出流，那么这段代码就可以删掉了（https://github.com/RustAudio/cpal/issues/740）
    handle.spawn(async move {
        let host = cpal::default_host();
        let get_device_name = || {
            host.default_output_device()
                .map(|x| x.name().unwrap_or_default())
                .unwrap_or_default()
        };
        let mut cur_device_name = get_device_name();
        loop {
            tokio::time::sleep(Duration::from_secs(1)).await;
            let mut def_device_name = get_device_name();
            if cur_device_name != def_device_name {
                cur_device_name = def_device_name;
                info!("默认输出设备发生改变，正在尝试重新创建输出设备");
                poll_default_tx
                    .send(AudioOutputMessage::ChangeOutput("".into()))
                    .await;
            }
        }
    });
    let handle_c = handle.clone();
    handle.spawn_blocking(move || {
        let mut output_name = "".to_string();
        let mut ring_buf_size_ms = None;
        let mut output = init_audio_player(&output_name, ring_buf_size_ms).ok();
        let mut current_volume = 0.5;
        if let Some(output) = &mut output {
            output.set_volume(current_volume);
            output.stream().play().unwrap();
        }
        info!("音频线程正在开始工作！");

        loop {
            let mut process_msg =
                |msg: AudioOutputMessage, output: &mut Option<Box<dyn AudioOutput>>| match msg {
                    AudioOutputMessage::ChangeOutput(new_output_name) => {
                        match init_audio_player(&new_output_name, ring_buf_size_ms) {
                            Ok(mut new_output) => {
                                output_name = new_output_name;
                                new_output.set_volume(current_volume);
                                new_output.stream().play().unwrap();
                                *output = Some(new_output);
                                info!("已切换输出设备")
                            }
                            Err(err) => {
                                warn!("无法切换到输出设备 {new_output_name}: {err}");
                                *output = None;
                            }
                        }
                    }
                    AudioOutputMessage::ChangeRingBufSize(new_size) => {
                        match init_audio_player(&output_name, Some(new_size)) {
                            Ok(mut new_output) => {
                                ring_buf_size_ms = Some(new_size);
                                new_output.set_volume(current_volume);
                                new_output.stream().play().unwrap();
                                *output = Some(new_output);
                                info!("已切换输出设备（设置回环流大小）")
                            }
                            Err(err) => {
                                warn!("无法切换到输出设备（设置回环流大小） {output_name}: {err}");
                                *output = None;
                            }
                        }
                    }
                    AudioOutputMessage::SetVolume(volume) => {
                        current_volume = volume;
                        if let Some(out) = output {
                            out.set_volume(volume);
                        }
                    }
                    AudioOutputMessage::ClearBuffer => {}
                };

            let poll_result = handle_c.block_on(async {
                tokio::select! {
                    biased;
                    Some(msg) = msg_rx.recv() => Some(Err(msg)),
                    Some(pcm) = pcm_rx.recv() => Some(Ok(pcm)),
                    else => None,
                }
            });

            match poll_result {
                Some(Ok(pcm)) => {
                    let mut should_recreate = false;
                    if let Some(out) = &mut output {
                        if out.is_dead() {
                            should_recreate = true;
                            output_name = "".to_string();
                            info!("现有输出设备已断开，正在重新初始化播放器");
                        } else {
                            out.write(pcm.as_audio_buffer_ref());
                        }
                    }
                    if should_recreate {
                        output = init_audio_player("", None).ok();
                        if let Some(out) = &mut output {
                            out.set_volume(current_volume);
                            out.stream().play().unwrap();
                        }
                    }
                }
                Some(Err(first_msg)) => {
                    if matches!(first_msg, AudioOutputMessage::ClearBuffer) {
                        while pcm_rx.try_recv().is_ok() {}
                    }
                    process_msg(first_msg, &mut output);

                    while let Ok(msg) = msg_rx.try_recv() {
                        if matches!(msg, AudioOutputMessage::ClearBuffer) {
                            while pcm_rx.try_recv().is_ok() {}
                        }
                        process_msg(msg, &mut output);
                    }
                }
                None => {
                    break;
                }
            }
        }

        info!("所有接收者已关闭，音频线程即将结束！");
    });
    AudioOutputSender {
        sender: tx,
        pcm_sender: pcm_tx,
    }
}
