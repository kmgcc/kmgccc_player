use std::collections::HashSet;

use skia_safe::{
    textlayout::{
        FontCollection, Paragraph, ParagraphBuilder, ParagraphStyle, TextStyle,
        TypefaceFontProvider,
    },
    Canvas, Color4f, FontMgr, Paint, Point, Rect, Size, Typeface,
};

use super::spring::Spring;

#[derive(Debug)]
struct LyricLineElement {
    pub line: ws_protocol::LyricLine,

    pub active: bool,
    pub position: Spring,
    pub scale: Spring,
    pub alpha: Spring,

    pub size: Size,
    pub paragraph: Option<Paragraph>,
    pub sub_paragraph: Option<Paragraph>,
}

impl LyricLineElement {
    pub fn is_visible(&self, region: &Rect, point: &Point) -> bool {
        let rect = Rect::from_xywh(point.x, point.y, self.size.width, self.size.height);
        region.intersects(rect)
    }
}

#[derive(Debug)]
pub struct LyricRenderer {
    current_time: u64,
    rect: Rect,
    lines: Vec<LyricLineElement>,

    hot_lines: HashSet<usize>,
    buffered_lines: HashSet<usize>,

    // 绘图相关
    tf_provider: TypefaceFontProvider,
    pingfang_type_face: Typeface,
    sf_pro_type_face: Typeface,
}

impl LyricRenderer {
    pub fn new(pingfang_type_face: Typeface, sf_pro_type_face: Typeface) -> Self {
        let mut tf_provider = TypefaceFontProvider::new();
        tf_provider.register_typeface(
            pingfang_type_face.clone(),
            Some(pingfang_type_face.family_name().as_str()),
        );
        tf_provider.register_typeface(
            sf_pro_type_face.clone(),
            Some(sf_pro_type_face.family_name().as_str()),
        );

        Self {
            pingfang_type_face,
            sf_pro_type_face,
            tf_provider,
            current_time: 0,
            rect: Rect::new_empty(),
            lines: Vec::with_capacity(1024),
            hot_lines: HashSet::new(),
            buffered_lines: HashSet::new(),
        }
    }

    pub fn set_current_time(&mut self, current_time: u64) {
        // 我在这里定义了歌词的选择状态：
        // 普通行：当前不处于时间范围内的歌词行
        // 热行：当前绝对处于播放时间内的歌词行，且一般会被立刻加入到缓冲行中
        // 缓冲行：一般处于播放时间后的歌词行，会因为当前播放状态的缘故推迟解除状态

        // 然后我们需要让歌词行为如下：
        // 如果当前仍有缓冲行的情况下加入新热行，则不会解除当前缓冲行，且也不会修改当前滚动位置
        // 如果当前所有缓冲行都将被删除且没有新热行加入，则删除所有缓冲行，且也不会修改当前滚动位置
        // 如果当前所有缓冲行都将被删除且有新热行加入，则删除所有缓冲行并加入新热行作为缓冲行，然后修改当前滚动位置

        self.current_time = current_time;

        let mut removed_hot_lines = HashSet::with_capacity(self.lines.len());
        let mut removed_lines = HashSet::with_capacity(self.lines.len());
        let mut added_lines = HashSet::with_capacity(self.lines.len());

        // 先检索当前已经超出时间范围的缓冲行，列入待删除集内
        for &hot_id in &self.hot_lines {
            let line = if let Some(line) = self.lines.get(hot_id) {
                line
            } else {
                removed_hot_lines.insert(hot_id);
                continue;
            };

            if line.line.is_bg {
                continue;
            }

            // 对于带背景歌词的歌词行，将二者的始末时间综合考虑
            if let Some(next_line) = self.lines.get(hot_id + 1) {
                if next_line.line.is_bg {
                    let start_time = line.line.start_time.min(next_line.line.start_time);
                    let end_time = line.line.end_time.max(next_line.line.end_time);
                    if (end_time < current_time) || (start_time > current_time) {
                        removed_hot_lines.insert(hot_id);
                        removed_hot_lines.insert(hot_id + 1);
                    }
                    continue;
                }
            }

            if (line.line.start_time > current_time) || (line.line.end_time < current_time) {
                removed_hot_lines.insert(hot_id);
            }
        }

        for removed_hot_id in removed_hot_lines {
            self.hot_lines.remove(&removed_hot_id);
        }

        for line_id in &self.buffered_lines {
            if !self.hot_lines.contains(line_id) {
                removed_lines.insert(*line_id);
            }
        }

        // 对于在时间范围内的歌词行，如果不在热行中，则加入热行
        for (i, line) in self.lines.iter().enumerate() {
            if line.line.is_bg {
                continue;
            }

            if (line.line.start_time <= current_time)
                && (line.line.end_time > current_time)
                && !self.hot_lines.contains(&i)
            {
                added_lines.insert(i);
            }
        }
    }

    pub fn set_current_time_for_seek(&mut self, current_time: u64) {
        self.hot_lines.clear();
        self.buffered_lines.clear();
        self.set_current_time(current_time);
    }

    pub fn set_lines(&mut self, lines: Vec<ws_protocol::LyricLine>) {
        self.lines.clear();
        for line in lines {
            self.lines.push(LyricLineElement {
                line,
                active: false,
                position: Spring::new(0.0).with_damper(0.7),
                scale: Spring::new(100.0).with_damper(0.99),
                alpha: Spring::new(0.0).with_damper(0.99),
                size: Size::new_empty(),
                paragraph: None,
                sub_paragraph: None,
            });
        }
        self.hot_lines.clear();
        self.hot_lines.reserve(self.lines.len());
        self.buffered_lines.clear();
        self.buffered_lines.reserve(self.lines.len());
        self.set_current_time(0);
        self.layout_text();
        self.calc_layout();
    }

    fn draw_debug_text(&self, canvas: &Canvas, text: &str, pos: Point) {
        let mut param_style = ParagraphStyle::new();
        param_style.set_text_style(
            TextStyle::new()
                .set_font_size(16.)
                .set_foreground_paint(&Paint::new(Color4f::new(1.0, 0.0, 0.0, 1.0), None)),
        );
        let mut font_collection = FontCollection::new();
        let font_mgr = FontMgr::new();
        font_collection
            .set_default_font_manager_and_family_names(font_mgr, &["SF Pro", "PingFang SC"]);
        let mut param = ParagraphBuilder::new(&param_style, font_collection);
        param.add_text(text);
        let mut paragraph = param.build();
        paragraph.layout(self.rect.width());
        paragraph.paint(canvas, pos);
    }

    pub fn render(&mut self, canvas: &Canvas) {
        canvas.save();

        let mut point = Point::new(self.rect.left, self.rect.top + self.rect.height() / 2.0);

        // if let Some((i, first_active_line)) = self.lines.iter().enumerate().rev().find(|x| {
        //     let start_time = x.1.line.words.first().map(|x| x.start_time);
        //     if let Some(start_time) = start_time {
        //         start_time <= self.current_time as u32
        //     } else {
        //         false
        //     }
        // }) {
        //     point.y -= self
        //         .lines
        //         .iter()
        //         .take(i)
        //         .map(|x| x.size.height + self.rect.height() * 0.05)
        //         .sum::<f32>();
        //     point.y -= (first_active_line.size.height + self.rect.height() * 0.05) / 2.0;
        // }

        for line in &self.lines {
            if !line.is_visible(&self.rect, &point) {
                point.y += self.rect.height() * 0.05;
                if let Some(param) = &line.paragraph {
                    point.y += param.height();
                }
                if let Some(param) = &line.sub_paragraph {
                    point.y += param.height();
                }
                continue;
            }
            // self.draw_debug_text(canvas, &format!("{line:#?}"), point);
            point.y += self.rect.height() * 0.025;
            if let Some(param) = &line.paragraph {
                param.paint(canvas, point);
                canvas.draw_rect(
                    Rect::from_xywh(point.x, point.y, param.max_width(), param.height()),
                    Paint::new(Color4f::new(1., 0., 0., 1.), None)
                        .set_stroke(true)
                        .set_stroke_width(1.),
                );
                point.y += param.height();
            }
            if let Some(param) = &line.sub_paragraph {
                param.paint(canvas, point);
                canvas.draw_rect(
                    Rect::from_xywh(point.x, point.y, param.max_width(), param.height()),
                    Paint::new(Color4f::new(0., 1., 0., 1.), None)
                        .set_stroke(true)
                        .set_stroke_width(1.),
                );
                point.y += param.height();
            }
            point.y += self.rect.height() * 0.025;
        }
        canvas.restore();
    }

    pub fn set_rect(&mut self, rect: Rect) {
        self.rect = rect;
        self.layout_text();
    }

    pub fn calc_layout(&mut self) {}

    pub fn layout_text(&mut self) {
        let width = self.rect.width() * 0.8;
        let mut font_collection = FontCollection::new();
        let font_mgr = FontMgr::new();
        font_collection
            .set_default_font_manager_and_family_names(font_mgr, &["SF Pro", "PingFang SC"]);
        let mut param_style = ParagraphStyle::new();
        param_style.set_text_style(
            TextStyle::new()
                .set_font_size(self.rect.height() * 0.05)
                .set_foreground_paint(
                    Paint::new(Color4f::new(1.0, 1.0, 1.0, 0.4), None)
                        .set_blend_mode(skia_safe::BlendMode::Plus),
                ),
        );
        let mut sub_param_style = ParagraphStyle::new();
        sub_param_style.set_text_style(
            TextStyle::new()
                .set_font_size(self.rect.height() * 0.025)
                .set_foreground_paint(
                    Paint::new(Color4f::new(1.0, 1.0, 1.0, 0.2), None)
                        .set_blend_mode(skia_safe::BlendMode::Plus),
                ),
        );

        font_collection.set_asset_font_manager(Some(self.tf_provider.clone().into()));
        for line in &mut self.lines {
            let mut param = ParagraphBuilder::new(&param_style, font_collection.clone());
            for word in &line.line.words {
                // TODO: 增加颜色样式等
                param.add_text(&word.word);
            }
            let mut paragraph = param.build();
            paragraph.layout(width);
            line.size = Size::new(width, paragraph.height());
            line.paragraph = Some(paragraph);
            let sub_line = line.line.translated_lyric.as_ref().to_string()
                + "\n"
                + line.line.roman_lyric.as_ref();
            if sub_line.trim().is_empty() {
                line.sub_paragraph = None;
            } else {
                let mut param = ParagraphBuilder::new(&sub_param_style, font_collection.clone());
                param.add_text(sub_line.trim());
                let mut paragraph = param.build();
                paragraph.layout(width);
                line.size.height += paragraph.height();
                line.sub_paragraph = Some(paragraph);
            }
            // debug!("Layouted line: {:?}", line);
        }
    }
}
