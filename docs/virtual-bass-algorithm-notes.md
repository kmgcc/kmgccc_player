# 虚拟低音（Virtual Bass / Missing Fundamental）算法调研与文献参考

本文档记录虚拟低音算法的核心原理、学术界与工业界经典文献、开源实现以及消除爆音（“噗噗噗”马达声、削波失真）的关键工程准则。

---

## 1. 核心声学原理：缺失基频（The Missing Fundamental）

人耳与听觉大脑皮层具有强大的非线性音高感知能力。当一段复合声音包含一系列以基频 $f_0$ 为公约数的等间距高阶谐波（例如 $2f_0, 3f_0, 4f_0, 5f_0$）时，即使基频 $f_0$ 本身被物理切除或无法被小型扬声器（手机、笔记本、平头耳机）播放出来，听觉神经系统仍会自动重构出基频 $f_0$ 的音高感知。

虚拟低音技术正是利用这一心理声学特性，将扬声器无法发出的超低频分量（如 30Hz ~ 80Hz）提取出来，生成位于扬声器可播放区间（如 100Hz ~ 300Hz）的对应谐波系列，从而在不增加振膜物理负荷的情况下，使听者获得深沉的低音下潜感。

---

## 2. 经典学术文献与工业界专利

### 2.1 工业界里程碑：Waves MaxxBass
- **发明人**：Meir Shashoua, Daniel Glotter (Waves Audio)
- **专利文献**：
  - **US Patent US5930373A**: *"Method and system for enhancing quality of sound signal"* (1999)
- **AES 会议论文**：
  - D. Ben-Tzur and M. Colloms, *"The Effect of the MaxxBass Psychoacoustic Bass Enhancement System on Loudspeaker Design,"* AES 106th Convention, Preprint 4892 (1999).
- **核心贡献**：
  - 确立了现代虚拟低音的标准工业级架构：**前级分频（Pre-LPF） $\to$ 非线性谐波发生器（NLD） $\to$ 后级带通/高通（Post-BPF/HPF） $\to$ 动态等响度向上压缩（Upward Compression） $\to$ 混音输出**。
  - 强调了等响度曲线匹配与平滑动态压缩的重要性，避免强音爆音、弱音无感。

### 2.2 飞利浦研究院系统性理论：Aarts & Larsen
- **专著**：
  - Erik Larsen & Ronald M. Aarts, *"Audio Bandwidth Extension: Application of Psychoacoustics, Signal Processing and Loudspeaker Design"*, John Wiley & Sons, 2004.
- **JAES 核心期刊论文**：
  - E. Larsen and R. M. Aarts, *"Reproducing low-pitched signals through small loudspeakers,"* Journal of the Audio Engineering Society (JAES), vol. 50, no. 3, pp. 147–164, 2002.
- **核心贡献**：
  - 深入分析了各类非线性器件（全波整流 FWR、半波整流 HWR、平方发生器、积分器）在单音与复音信号下的傅里叶展开与谐波结构。
  - 首次从理论上证明了复音互调失真（IMD）是导致虚拟低音浑浊与次声波抖动的物理根源。

### 2.3 南洋理工大学关于失真与人耳感知的量化评估：Gan & Oo
- **JAES 核心期刊论文**：
  - Nay Oo, Woon-Seng Gan, and Malcolm O. J. Hawksford, *"Perceptually-Motivated Objective Grading of Nonlinear Processing in Virtual-Bass Systems,"* JAES, vol. 59, no. 11, pp. 804–824, 2011.
- **AES 会议论文**：
  - Nay Oo and Woon-Seng Gan, *"Harmonic and Intermodulation Analysis of Nonlinear Devices Used in Virtual Bass Systems,"* AES 128th Convention, 2010.
- **核心结论**：
  - 人耳对缺失基频的感知主要取决于 **2次谐波（$2f_0$）与 3次谐波（$3f_0$）**。
  - 4次以上的高次谐波对音高感知贡献急剧下降，但引入的互调失真和中频音染却呈指数级上升。高次多项式是导致“塑料音”、“发脏”、“刺耳”的罪魁祸首。

### 2.4 阿尔托大学模糊时频分解法（Hybrid 方案出处）：Moliner & Välimäki
- **DAFx 会议论文**：
  - Eloi Moliner, Jussi Rämö, and Vesa Välimäki, *"Virtual Bass System with Fuzzy Separation of Tones and Transients,"* 23rd International Conference on Digital Audio Effects (DAFx-20), Sept. 2020.
- **开源代码仓库**：
  - GitHub: [`eloimoliner/virtualbass`](https://github.com/eloimoliner/virtualbass) (MATLAB 实现)
- **核心思想**：
  - 利用中值滤波（Fitzgerald 算法）在 STFT 频域将信号分解为稳态乐音（Tonal）、瞬态冲击（Transient）和噪声（Noise）。
  - 稳态乐音用自适应频域声码器提升和补充谐波；瞬态冲击经过带通后走轻量软饱和，保持鼓点打击感；噪声不处理，保持背景干净。

---

## 3. “噗噗噗”马达声与破音的四大根本病因诊断

| 现象与病灶 | 物理与数学根因 | 为什么现有代码会破音？ |
| :--- | :--- | :--- |
| **低频“噗噗噗”马达声 (Motorboating / Flutter)** | **复音频的差频互调失真 (Difference Frequency IMD)**：真实音乐由多个频率组成（如 50Hz 底鼓 + 65Hz 贝斯），非线性处理必产生 $|f_1 - f_2| = 15\text{Hz}$ 的极低频次声波。 | 现有代码后级高通不足，次声波调制未被彻底斩除；且包络除法使用了 `max(envelope, amplitude)`，拍频在峰顶导数不连续，直接激发脉冲波。 |
| **突发性碎裂破音 (Popping / Glitch)** | **单样本瞬时波形硬限幅 (Sample-by-Sample Clipping)** | `DSPBassPeakControl.mix` 在每一采样点瞬时计算可用空间并硬截断，波形被削成方角，激发全频段数字破音。 |
| **声音浑浊、发脏、单薄** | **高阶多项式展开 ($z^4, z^5, z^6$) 的二项式交叉互调** | 多项式阶数过高，复音频展开产生数十个不谐和互调分量，淹没音乐原有细节。 |
| **混音过载削波** | **湿声谐波再次送入低架滤波 (`bassShelf`)** | 谐波生成后本应直接与原声混合，代码中却再次送进 low-shelf 提升数 dB，严重吃掉 Headroom。 |

---

## 4. 工业级免杂音虚拟低音设计黄金法则

1. **后级高通（Post-HPF）是生命线**：
   - 谐波生成后，必须接 **4阶（24dB/oct）Butterworth 高通滤波器**，截止频率严格设在 $f_c$（如 70Hz~100Hz），彻底把 $< f_c$ 的差频次声波与直流偏移衰减 40dB 以上！
2. **后级低通（Post-LPF）压制毛刺**：
   - 串联 2阶低通滤波器（截止频率设在 350Hz~500Hz），防止谐波窜入中频人声区。
3. **只用 2 次与 3 次谐波**：
   - 2次谐波（八度）：占 65%~70%，负责厚度、温暖度与基频感知；
   - 3次谐波（十二度）：占 30%~35%，负责打击感与清晰度；
   - 彻底废除 4~6 次高阶项。
4. **平滑动态限幅替代瞬时削波**：
   - 采用带平滑 Attack（1~5ms）与 Release（50~100ms）的增益衰减器，严禁使用逐样本瞬时硬截断。
5. **湿声与干声独立分离**：
   - 干声可进行适度 Low-Cut 或维持原样，湿声绝不重复进入低频搁架滤波。
