/* global React, ReactDOM */
const { useState, useEffect, useMemo } = React;

// ─────────────────────────────────────────────────────────────
// Primitives
// ─────────────────────────────────────────────────────────────

// A rectangle with an inner label and optional eyebrow tag.
function Box({ w, h, tag, label, cls = "stroke", style = {}, children, labelAlign = "br" }) {
  const s = {
    width: w,
    height: h,
    position: "relative",
    overflow: "hidden",
    ...style
  };
  const labelPos = {
    br: { right: 8, bottom: 6 },
    bl: { left: 10, bottom: 6 },
    tl: { left: 10, top: 8 },
    tr: { right: 10, top: 8 },
    c: { left: "50%", top: "50%", transform: "translate(-50%,-50%)" }
  }[labelAlign];
  return (
    <div className={cls} style={s}>
      {children}
      {tag &&
      <div className="blk-tag" style={{ position: "absolute", left: 10, top: 8, opacity: 0.85 }}>{tag}</div>
      }
      {label &&
      <div className="blk-label" style={{ position: "absolute", ...labelPos }}>{label}</div>
      }
    </div>);

}

// Square album cover placeholder
function AlbumSquare({ size, hatch = "hatch", label, tag, rounded = 10, shadow = true }) {
  return (
    <div
      className={hatch}
      style={{
        width: size,
        height: size,
        borderRadius: rounded,
        border: "1.25px solid var(--line)",
        position: "relative",
        boxShadow: shadow ? "3px 5px 0 rgba(26,28,31,0.08)" : "none",
        flex: "0 0 auto"
      }}>
      
      {tag && <div className="blk-tag" style={{ position: "absolute", left: 8, top: 8 }}>{tag}</div>}
      {label && <div className="blk-label" style={{ position: "absolute", right: 8, bottom: 4 }}>{label}</div>}
    </div>);

}

// Circular artist placeholder
function ArtistCircle({ size, hatch = "hatch-b", label }) {
  return (
    <div
      className={hatch}
      style={{
        width: size,
        height: size,
        borderRadius: "50%",
        border: "1.25px solid var(--line)",
        position: "relative",
        boxShadow: "2px 3px 0 rgba(26,28,31,0.06)",
        flex: "0 0 auto"
      }}>
      
      {label &&
      <div className="blk-label" style={{ position: "absolute", inset: 0, display: "flex", alignItems: "center", justifyContent: "center" }}>
          {label}
        </div>
      }
    </div>);

}

// Text-stand-in line (wireframe "lorem" bar)
function TLine({ w, h = 10, dark = false, style }) {
  return (
    <div
      style={{
        width: w,
        height: h,
        borderRadius: 3,
        background: dark ? "var(--ink)" : "var(--line-soft)",
        opacity: dark ? 0.85 : 0.75,
        ...style
      }} />);


}

// Small mono metadata
function Meta({ children, style }) {
  return <div className="mono" style={{ fontSize: 10, letterSpacing: "0.04em", color: "var(--ink-faint)", ...style }}>{children}</div>;
}

// Section header with sketch title + line
function SectionHeader({ eyebrow, title, right }) {
  return (
    <div style={{ display: "flex", alignItems: "flex-end", justifyContent: "space-between", marginBottom: 14 }}>
      <div>
        {eyebrow && <div className="h-eyebrow" style={{ marginBottom: 4 }}>{eyebrow}</div>}
        <div className="h-title" style={{ fontWeight: 600 }}>{title}</div>
      </div>
      {right && <div className="mono" style={{ fontSize: 10, color: "var(--ink-faint)" }}>{right}</div>}
    </div>);

}

// Play button
function PlayPill({ label = "Play" }) {
  return (
    <div style={{
      display: "inline-flex", alignItems: "center", gap: 8,
      border: "1.5px solid var(--line)", borderRadius: 999,
      padding: "6px 14px 6px 8px", background: "var(--paper)"
    }}>
      <div style={{
        width: 20, height: 20, borderRadius: "50%",
        background: "var(--ink)", display: "inline-flex", alignItems: "center", justifyContent: "center"
      }}>
        <div style={{
          width: 0, height: 0,
          borderLeft: "6px solid var(--paper)",
          borderTop: "4px solid transparent",
          borderBottom: "4px solid transparent",
          marginLeft: 2
        }} />
      </div>
      <div className="sketch" style={{ fontSize: 18, lineHeight: 1 }}>{label}</div>
    </div>);

}

// Annotation: a short note + an arrow line connecting a point to the note
function Annotation({ show, x, y, w = 180, text, arrowTo }) {
  if (!show) return null;
  return (
    <>
      <div className="note-text" style={{ position: "absolute", left: x, top: y, width: w }}>
        {text}
      </div>
      {arrowTo &&
      <svg
        style={{ position: "absolute", left: 0, top: 0, width: "100%", height: "100%", overflow: "visible", pointerEvents: "none" }}>
        
          <path
          className="note-line"
          d={`M ${arrowTo.fromX} ${arrowTo.fromY} Q ${arrowTo.cx ?? (arrowTo.fromX + arrowTo.toX) / 2} ${arrowTo.cy ?? (arrowTo.fromY + arrowTo.toY) / 2 - 14} ${arrowTo.toX} ${arrowTo.toY}`} />
        
          {/* arrowhead */}
          <path
          className="note-line"
          d={`M ${arrowTo.toX} ${arrowTo.toY} l ${arrowTo.headDX ?? -8} ${arrowTo.headDY ?? -3} M ${arrowTo.toX} ${arrowTo.toY} l ${arrowTo.head2DX ?? -6} ${arrowTo.head2DY ?? 5}`} />
        
        </svg>
      }
    </>);

}

// ─────────────────────────────────────────────────────────────
// HERO — 3 distinct layouts
// ─────────────────────────────────────────────────────────────

// Hero A: Classic editorial. Square cover on left, blurred dissolve + text on right.
function HeroA({ heroSize, dark, showAnn }) {
  const h = heroSize === "compact" ? 230 : heroSize === "dominant" ? 340 : 280;
  const cover = h - 40;
  return (
    <div className="stroke" style={{ position: "relative", height: h, padding: 20, display: "flex", gap: 22, overflow: "hidden" }}>
      {/* dissolve background covers right 2/3 */}
      <div className="dissolve" style={{ position: "absolute", inset: 0, left: cover + 40 - 80 }} />
      <AlbumSquare size={cover} hatch="hatch-dense" tag="ALBUM ART" label="hero cover" rounded={14} />
      <div style={{ position: "relative", flex: 1, display: "flex", flexDirection: "column", justifyContent: "center", gap: 10, paddingLeft: 8 }}>
        <div className="h-eyebrow">Now playing · from your library</div>
        <div className="sketch" style={{ fontSize: 40, lineHeight: 1, fontWeight: 600, color: "var(--ink)" }}>Song title</div>
        <div className="sketch" style={{ fontSize: 22, lineHeight: 1, color: "var(--ink-soft)" }}>Artist name — Album</div>
        <Meta style={{ marginTop: 4 }}>4:12 · 2019 · Alternative · Lossless</Meta>
        <div style={{ marginTop: 14, display: "flex", gap: 10, alignItems: "center" }}>
          <PlayPill />
          <Box w={96} h={32} cls="stroke-soft" label="Queue" labelAlign="c" />
          <Box w={32} h={32} cls="stroke-soft" label="♡" labelAlign="c" />
        </div>
      </div>

      {/* annotations */}
      {showAnn &&
      <>
          <div className="note-text" style={{ position: "absolute", right: 18, top: 14, width: 220, textAlign: "right" }}>
            blurred artwork dissolves<br />from cover → right edge
          </div>
          <div className="note-text" style={{ position: "absolute", left: cover + 30, bottom: 10, width: 180 }}>
            text stays high-contrast<br />over the haze
          </div>
        </>
      }
    </div>);

}

// Hero B: Wide cinematic strip. Smaller cover, longer copy block, inline metadata strip.
function HeroB({ heroSize, showAnn }) {
  const h = heroSize === "compact" ? 210 : heroSize === "dominant" ? 320 : 260;
  const cover = h - 60;
  return (
    <div className="stroke" style={{ position: "relative", height: h, padding: 18, display: "flex", gap: 20, overflow: "hidden" }}>
      <div className="dissolve" style={{ position: "absolute", inset: 0, left: cover + 20 }} />
      <AlbumSquare size={cover} hatch="hatch" tag="ALBUM ART" rounded={12} />
      <div style={{ position: "relative", flex: 1, display: "flex", flexDirection: "column", justifyContent: "space-between", paddingTop: 6, paddingBottom: 4 }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start" }}>
          <div>
            <div className="h-eyebrow">A random pick from your library</div>
            <div className="sketch" style={{ fontSize: 36, lineHeight: 1.05, fontWeight: 600, marginTop: 6 }}>Song title goes here</div>
            <div className="sketch" style={{ fontSize: 20, lineHeight: 1, color: "var(--ink-soft)", marginTop: 4 }}>Artist · Album · 2022</div>
          </div>
          <div className="mono" style={{ fontSize: 10, color: "var(--ink-faint)", textAlign: "right" }}>
            track 04 / 11<br />added apr 12<br />played 34×
          </div>
        </div>
        <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
          <PlayPill label="Play" />
          <PlayPill label="Shuffle album" />
          <div style={{ flex: 1 }} />
          <div className="mono" style={{ fontSize: 10, color: "var(--ink-faint)" }}>4:12 · LOSSLESS 24/96</div>
        </div>
      </div>
      {showAnn &&
      <div className="note-text" style={{ position: "absolute", right: 16, top: -4, width: 220, textAlign: "right" }}>
          metadata rail →<br /><span style={{ opacity: 0.8 }}>uses mono for numbers</span>
        </div>
      }
    </div>);

}

// Hero C: Creative — diagonal / layered collage. Cover tilted into a soft field, with an overlapping info card.
function HeroC({ heroSize, showAnn }) {
  const h = heroSize === "compact" ? 260 : heroSize === "dominant" ? 360 : 310;
  const cover = h - 80;
  return (
    <div className="stroke" style={{ position: "relative", height: h, padding: 0, overflow: "hidden" }}>
      {/* full-bleed dissolve */}
      <div className="dissolve" style={{ position: "absolute", inset: 0 }} />
      {/* cover — slightly tilted, offset from edge */}
      <div style={{ position: "absolute", left: 28, top: 22 }}>
        <div style={{ transform: "rotate(-3deg)" }}>
          <AlbumSquare size={cover} hatch="hatch-dense" tag="ALBUM ART" rounded={10} />
        </div>
      </div>
      {/* floating info card */}
      <div className="stroke" style={{
        position: "absolute",
        left: cover + 28 + 24,
        top: 30,
        right: 28,
        bottom: 28,
        padding: 18,
        display: "flex",
        flexDirection: "column",
        gap: 8,
        background: "var(--paper)",
        boxShadow: "3px 5px 0 rgba(26,28,31,0.08)"
      }}>
        <div className="h-eyebrow">Today's pick</div>
        <div className="sketch" style={{ fontSize: 34, fontWeight: 600, lineHeight: 1.05, marginTop: 2 }}>Song title</div>
        <div className="sketch" style={{ fontSize: 18, color: "var(--ink-soft)", lineHeight: 1 }}>Artist — Album, 2019</div>

        <div style={{ flex: 1 }} />

        {/* mini "waveform" placeholder */}
        <div style={{ display: "flex", alignItems: "flex-end", gap: 2, height: 22, opacity: 0.6 }}>
          {Array.from({ length: 64 }).map((_, i) => {
            const hh = 4 + Math.abs(Math.sin(i * 0.7) * 16) + i % 7 * 0.6;
            return <div key={i} style={{ width: 2, height: hh, background: "var(--ink)", borderRadius: 1 }} />;
          })}
        </div>
        <Meta>0:00 ──────────── 4:12</Meta>

        <div style={{ marginTop: 8, display: "flex", gap: 10 }}>
          <PlayPill />
          <Box w={90} h={32} cls="stroke-soft" label="Go to album" labelAlign="c" />
        </div>
      </div>
      {showAnn &&
      <>
          <div className="note-text" style={{ position: "absolute", left: 18, bottom: 12, width: 190 }}>
            ↖ cover tilts into the haze<br />(creative take — optional)
          </div>
          <div className="note-text" style={{ position: "absolute", right: 18, top: 8, width: 210, textAlign: "right" }}>
            info floats as a card<br />with its own shadow
          </div>
        </>
      }
    </div>);

}

// ─────────────────────────────────────────────────────────────
// SECTION: Albums row
// ─────────────────────────────────────────────────────────────
function AlbumsRow({ density, hatches = ["hatch", "hatch-b", "hatch-dense", "hatch", "hatch-b", "hatch-dense"], count }) {
  const size = density === "tight" ? 110 : density === "airy" ? 170 : 140;
  const n = count ?? (density === "tight" ? 7 : density === "airy" ? 5 : 6);
  return (
    <div style={{ display: "flex", gap: density === "tight" ? 12 : 18, overflow: "hidden" }}>
      {Array.from({ length: n }).map((_, i) =>
      <div key={i} style={{ display: "flex", flexDirection: "column", gap: 8, width: size, flex: "0 0 auto" }}>
          <AlbumSquare size={size} hatch={hatches[i % hatches.length]} rounded={8} />
          <TLine w={size - 20} h={9} dark />
          <TLine w={size - 50} h={8} />
          <Meta>11 songs · 42 min</Meta>
        </div>
      )}
    </div>);

}

// ─────────────────────────────────────────────────────────────
// SECTION: Artists row
// ─────────────────────────────────────────────────────────────
function ArtistsRow({ density, count }) {
  const size = density === "tight" ? 74 : density === "airy" ? 112 : 92;
  const n = count ?? (density === "tight" ? 10 : density === "airy" ? 7 : 8);
  return (
    <div style={{ display: "flex", gap: density === "tight" ? 16 : 28, overflow: "hidden", alignItems: "flex-start" }}>
      {Array.from({ length: n }).map((_, i) =>
      <div key={i} style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 8, width: size + 20, flex: "0 0 auto" }}>
          <ArtistCircle size={size} hatch={i % 2 ? "hatch" : "hatch-b"} />
          <TLine w={size - 10} h={9} dark style={{ marginTop: 4 }} />
          <Meta>3 albums · 47 songs</Meta>
        </div>
      )}
    </div>);

}

// ─────────────────────────────────────────────────────────────
// SECTION: Playlists (wide horizontal rectangles)
// ─────────────────────────────────────────────────────────────
function PlaylistCard({ density, hatchStyle = "hatch" }) {
  const h = density === "tight" ? 76 : density === "airy" ? 108 : 92;
  const cover = h - 16;
  return (
    <div className="stroke" style={{
      position: "relative",
      height: h,
      padding: 8,
      display: "flex",
      gap: 16,
      alignItems: "center",
      overflow: "hidden"
    }}>
      {/* milky/deepened background — represented by a faint hatch wash */}
      <div style={{ position: "absolute", inset: 0, opacity: 0.35 }} className={hatchStyle} />
      <AlbumSquare size={cover} hatch={hatchStyle} rounded={6} shadow={false} />
      <div style={{ position: "relative", flex: 1, display: "flex", flexDirection: "column", gap: 6 }}>
        <div className="sketch" style={{ fontSize: 20, lineHeight: 1, fontWeight: 600 }}>Playlist name</div>
        <TLine w={240} h={8} />
        <Meta>42 songs · 2 hr 48 min · updated yesterday</Meta>
      </div>
      <div style={{ position: "relative", display: "flex", alignItems: "center", gap: 8, paddingRight: 6 }}>
        <PlayPill label="Play" />
      </div>
    </div>);

}

function PlaylistsStack({ density }) {
  const hatches = ["hatch", "hatch-b", "hatch-dense", "hatch"];
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: density === "tight" ? 8 : 12 }}>
      {hatches.map((h, i) => <PlaylistCard key={i} density={density} hatchStyle={h} />)}
    </div>);

}

// ─────────────────────────────────────────────────────────────
// SECTION: Listening Insights (stat cards + ranking list + mini chart)
// ─────────────────────────────────────────────────────────────
function StatCard({ label, value, unit, sparkline }) {
  return (
    <div className="stroke" style={{ padding: "12px 14px", minHeight: 88, display: "flex", flexDirection: "column", gap: 6 }}>
      <div className="h-eyebrow">{label}</div>
      <div style={{ display: "flex", alignItems: "baseline", gap: 6 }}>
        <div className="sketch" style={{ fontSize: 30, lineHeight: 1, fontWeight: 600 }}>{value}</div>
        {unit && <div className="mono" style={{ fontSize: 10, color: "var(--ink-faint)" }}>{unit}</div>}
      </div>
      {sparkline && <MiniSpark kind={sparkline} />}
    </div>);

}

function MiniSpark({ kind = "line", width = 180, height = 28 }) {
  if (kind === "bars") {
    return (
      <div style={{ display: "flex", alignItems: "flex-end", gap: 3, height, marginTop: 4 }}>
        {Array.from({ length: 18 }).map((_, i) => {
          const h = 3 + Math.abs(Math.sin(i * 0.6) * 20) + i % 5 * 1.2;
          return <div key={i} style={{ width: 5, height: h, background: "var(--ink)", opacity: 0.75, borderRadius: 1 }} />;
        })}
      </div>);

  }
  // line
  const pts = Array.from({ length: 22 }).map((_, i) => {
    const x = i / 21 * width;
    const y = height - 3 - Math.abs(Math.sin(i * 0.55) * (height - 8) * 0.6) - i % 3 * 1.2;
    return `${x},${y}`;
  }).join(" ");
  return (
    <svg width={width} height={height} style={{ marginTop: 4, display: "block" }}>
      <polyline points={pts} fill="none" stroke="var(--ink)" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" opacity="0.8" />
    </svg>);

}

function RankingList({ rows = 5, compact = false }) {
  return (
    <div className="stroke" style={{ padding: compact ? "8px 12px" : "14px 18px" }}>
      <div style={{ display: "grid", gridTemplateColumns: "28px 1fr 140px 100px 72px", gap: 14, alignItems: "center", paddingBottom: 8, borderBottom: "1px solid var(--line-soft)" }}>
        <div className="blk-tag">#</div>
        <div className="blk-tag">Song · Artist</div>
        <div className="blk-tag">Score</div>
        <div className="blk-tag">Plays</div>
        <div className="blk-tag" style={{ textAlign: "right" }}>Trend</div>
      </div>
      {Array.from({ length: rows }).map((_, i) =>
      <div key={i} style={{
        display: "grid", gridTemplateColumns: "28px 1fr 140px 100px 72px",
        gap: 14, alignItems: "center",
        padding: compact ? "8px 0" : "11px 0",
        borderBottom: i === rows - 1 ? "none" : "1px dashed var(--line-soft)"
      }}>
          <div className="sketch" style={{ fontSize: 22, color: "var(--ink-soft)", fontWeight: 600 }}>{i + 1}</div>
          <div style={{ display: "flex", flexDirection: "column", gap: 3 }}>
            <TLine w={`${60 - i * 4}%`} h={9} dark />
            <TLine w={`${40 - i * 3}%`} h={7} />
          </div>
          {/* score bar */}
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <div style={{ flex: 1, height: 6, background: "var(--paper-2)", borderRadius: 3, overflow: "hidden" }}>
              <div style={{ width: `${92 - i * 9}%`, height: "100%", background: "var(--ink)", opacity: 0.75 }} />
            </div>
            <div className="mono" style={{ fontSize: 10 }}>{(0.96 - i * 0.07).toFixed(2)}</div>
          </div>
          <div className="mono" style={{ fontSize: 11 }}>{140 - i * 19}</div>
          <div style={{ textAlign: "right" }}><MiniSpark kind="line" width={64} height={18} /></div>
        </div>
      )}
    </div>);

}

function InsightsA({ density }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(5, 1fr)", gap: 12 }}>
        <StatCard label="Total songs" value="2,418" unit="tracks" />
        <StatCard label="Total plays" value="18,204" unit="all time" sparkline="bars" />
        <StatCard label="Listening time" value="412 h" unit="this year" sparkline="line" />
        <StatCard label="Favorite artist" value="—" unit="47 albums" />
        <StatCard label="Active playlist" value="—" unit="28 plays" />
      </div>
      <div style={{ display: "grid", gridTemplateColumns: "2fr 1fr", gap: 16 }}>
        <div>
          <div className="h-eyebrow" style={{ marginBottom: 8 }}>Song preferences · top 5</div>
          <RankingList rows={5} />
        </div>
        <div className="stroke" style={{ padding: 14, display: "flex", flexDirection: "column", gap: 10 }}>
          <div className="h-eyebrow">Listening · last 30 days</div>
          <MiniSpark kind="bars" width={320} height={90} />
          <Meta>peak day: tue · avg 1 h 24 min</Meta>
        </div>
      </div>
    </div>);

}

// Variation B insights: denser, everything in one card
function InsightsB() {
  return (
    <div className="stroke" style={{ padding: 18 }}>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(5, 1fr)", gap: 18, paddingBottom: 14, borderBottom: "1px solid var(--line-soft)" }}>
        {[
        ["Songs", "2,418"],
        ["Plays", "18,204"],
        ["Listened", "412 h"],
        ["Top artist", "— 47"],
        ["Active list", "— 28×"]].
        map(([l, v]) =>
        <div key={l}>
            <div className="h-eyebrow">{l}</div>
            <div className="sketch" style={{ fontSize: 26, lineHeight: 1.1, fontWeight: 600, marginTop: 2 }}>{v}</div>
          </div>
        )}
      </div>
      <div style={{ display: "grid", gridTemplateColumns: "1.6fr 1fr", gap: 24, marginTop: 16 }}>
        <div>
          <div className="h-eyebrow" style={{ marginBottom: 8 }}>Preference ranking</div>
          <RankingList rows={6} compact />
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
          <div className="h-eyebrow">Weekly listening</div>
          <MiniSpark kind="bars" width={260} height={90} />
          <Meta>mon — sun</Meta>
          <div className="h-eyebrow" style={{ marginTop: 10 }}>Genre mix</div>
          <div style={{ display: "flex", gap: 4, height: 14, borderRadius: 3, overflow: "hidden", border: "1px solid var(--line-soft)" }}>
            <div style={{ flex: 5, background: "var(--ink)", opacity: 0.85 }} />
            <div style={{ flex: 3, background: "var(--ink)", opacity: 0.55 }} />
            <div style={{ flex: 2, background: "var(--ink)", opacity: 0.3 }} />
            <div style={{ flex: 1, background: "var(--ink)", opacity: 0.18 }} />
          </div>
          <Meta>indie · jazz · classical · other</Meta>
        </div>
      </div>
    </div>);

}

// Variation C insights: editorial, a "dashboard card" + vertical ranking
function InsightsC() {
  return (
    <div style={{ display: "grid", gridTemplateColumns: "1.1fr 1fr", gap: 20 }}>
      <div className="stroke" style={{ padding: 18, display: "flex", flexDirection: "column", gap: 12 }}>
        <div className="h-eyebrow">This month in music</div>
        <div className="sketch" style={{ fontSize: 30, lineHeight: 1.05, fontWeight: 600 }}>
          You listened for <span style={{ color: "var(--accent)" }}>34 h 12 m</span><br />
          across 241 songs
        </div>
        <MiniSpark kind="bars" width={420} height={70} />
        <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: 14, marginTop: 6 }}>
          <div>
            <div className="h-eyebrow">Top artist</div>
            <TLine w="80%" h={10} dark style={{ marginTop: 4 }} />
            <Meta style={{ marginTop: 4 }}>112 plays</Meta>
          </div>
          <div>
            <div className="h-eyebrow">Top album</div>
            <TLine w="80%" h={10} dark style={{ marginTop: 4 }} />
            <Meta style={{ marginTop: 4 }}>64 plays</Meta>
          </div>
          <div>
            <div className="h-eyebrow">New adds</div>
            <div className="sketch" style={{ fontSize: 24, lineHeight: 1, fontWeight: 600, marginTop: 2 }}>+ 38</div>
            <Meta>songs this month</Meta>
          </div>
        </div>
      </div>
      <div className="stroke" style={{ padding: 0, overflow: "hidden" }}>
        <div style={{ padding: "12px 16px 8px", borderBottom: "1px solid var(--line-soft)" }}>
          <div className="h-eyebrow">Preference ranking</div>
          <Meta style={{ marginTop: 2 }}>ordered by score · updated weekly</Meta>
        </div>
        <RankingList rows={5} compact />
      </div>
    </div>);

}

// ─────────────────────────────────────────────────────────────
// Variation wrappers — each wraps its content in a card with
// a light and dark preview side-by-side
// ─────────────────────────────────────────────────────────────

function VariationShell({ title, index, subtitle, tags, children, notes }) {
  return (
    <section style={{ marginTop: 56 }}>
      {/* title row */}
      <div style={{ display: "flex", alignItems: "flex-end", justifyContent: "space-between", gap: 20, marginBottom: 16 }}>
        <div style={{ display: "flex", alignItems: "baseline", gap: 14 }}>
          <div className="sketch" style={{ fontSize: 52, fontWeight: 700, lineHeight: 0.9, color: "var(--accent)" }}>0{index}</div>
          <div>
            <div className="sketch" style={{ fontSize: 34, lineHeight: 1, fontWeight: 600 }}>{title}</div>
            <div className="h-sub" style={{ marginTop: 4 }}>{subtitle}</div>
          </div>
        </div>
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap", justifyContent: "flex-end", maxWidth: 420 }}>
          {tags.map((t) =>
          <span key={t} className="mono" style={{ fontSize: 10, letterSpacing: "0.04em", padding: "3px 8px", border: "1px solid var(--line-soft)", borderRadius: 999, color: "var(--ink-soft)" }}>{t}</span>
          )}
        </div>
      </div>

      {notes && <div className="h-sub" style={{ marginBottom: 14, maxWidth: 880 }}>{notes}</div>}

      <div className="pair">
        <div className="canvas" style={{ width: "70px" }}>
          <div className="canvas-tag">light <span className="chip">home · default</span></div>
          {children(false)}
        </div>
        <div className="canvas dark-card" style={{ width: "7px" }}>
          <div className="canvas-tag" style={{ background: "var(--paper)" }}>dark <span className="chip">home · night</span></div>
          {children(true)}
        </div>
      </div>
    </section>);

}

// ─────────────────────────────────────────────────────────────
// VARIATION A — Classic editorial (conventional)
// Hero: large left cover, blurred right field
// Sections: Albums row → Artists row → Playlists → Insights
// ─────────────────────────────────────────────────────────────
function VariationA({ heroSize, density, showAnn }) {
  return (
    <VariationShell
      index={1}
      title="Classic Editorial"
      subtitle="Hero · Albums · Artists · Playlists · Insights — the expected, refined order."
      tags={["hero: left cover + right dissolve", "sections: vertical, full-width", "conventional"]}
      notes="Straightforward vertical rhythm. The hero establishes mood, then horizontal rows for browsing, then the stacked playlist cards provide a calmer pause before the data section at the bottom. This is the 'safe, premium' take.">
      
      {(dark) =>
      <div style={{ display: "flex", flexDirection: "column", gap: 28 }}>
          <HeroA heroSize={heroSize} dark={dark} showAnn={showAnn} />
          <div>
            <SectionHeader eyebrow="FROM YOUR LIBRARY" title="Albums" right="See all →" />
            <AlbumsRow density={density} />
          </div>
          <div>
            <SectionHeader eyebrow="PEOPLE" title="Artists" right="See all →" />
            <ArtistsRow density={density} />
          </div>
          <div>
            <SectionHeader eyebrow="CURATED" title="Playlists" right="New playlist +" />
            <PlaylistsStack density={density} />
          </div>
          <div>
            <SectionHeader eyebrow="YOU" title="Listening Insights" right="Last 30 days ▾" />
            <InsightsA density={density} />
          </div>
        </div>
      }
    </VariationShell>);

}

// ─────────────────────────────────────────────────────────────
// VARIATION B — Split column, dense (conventional)
// Hero on top, then two-column body: left = Albums + Artists;
// right = Playlists. Insights full-width below.
// ─────────────────────────────────────────────────────────────
function VariationB({ heroSize, density, showAnn }) {
  return (
    <VariationShell
      index={2}
      title="Split Column"
      subtitle="Hero · then a two-column body so playlists sit beside browsing rows — useful quicker."
      tags={["hero: wide cinematic strip", "two-column body", "denser, but still refined"]}
      notes="More content visible in the first 1–2 screens. Albums and artists stay to the left as browsing rails, playlists anchor the right column as a persistent 'pick something to play' list. Insights gets its own full-width band at the bottom.">
      
      {(dark) =>
      <div style={{ display: "flex", flexDirection: "column", gap: 28 }}>
          <HeroB heroSize={heroSize} showAnn={showAnn} />
          <div style={{ display: "grid", gridTemplateColumns: "1.4fr 1fr", gap: 28 }}>
            <div style={{ display: "flex", flexDirection: "column", gap: 24 }}>
              <div>
                <SectionHeader eyebrow="FROM YOUR LIBRARY" title="Albums" right="See all →" />
                <AlbumsRow density={density === "airy" ? "standard" : "tight"} count={4} />
              </div>
              <div>
                <SectionHeader eyebrow="PEOPLE" title="Artists" right="See all →" />
                <ArtistsRow density={density === "airy" ? "standard" : "tight"} count={6} />
              </div>
            </div>
            <div style={{ position: "relative" }}>
              <SectionHeader eyebrow="CURATED" title="Playlists" right="New +" />
              <div style={{ display: "flex", flexDirection: "column", gap: density === "tight" ? 8 : 12 }}>
                <PlaylistCard density={density} hatchStyle="hatch" />
                <PlaylistCard density={density} hatchStyle="hatch-b" />
                <PlaylistCard density={density} hatchStyle="hatch-dense" />
                <PlaylistCard density={density} hatchStyle="hatch" />
              </div>
              {showAnn &&
            <div className="note-text" style={{ position: "absolute", right: -4, bottom: -28, width: 220, textAlign: "right" }}>
                  playlists flank the rails<br />→ always one click from play
                </div>
            }
            </div>
          </div>
          <div>
            <SectionHeader eyebrow="YOU" title="Listening Insights" right="Last 30 days ▾" />
            <InsightsB />
          </div>
        </div>
      }
    </VariationShell>);

}

// ─────────────────────────────────────────────────────────────
// VARIATION C — Editorial collage (creative take)
// Hero: layered / tilted. Below: a "Today" strip mixing one
// featured album + a few artist circles, then a mixed row
// of playlists & albums, then editorial insights.
// ─────────────────────────────────────────────────────────────
function VariationC({ heroSize, density, showAnn }) {
  return (
    <VariationShell
      index={3}
      title="Editorial Collage"
      subtitle="Hero · a 'Today' strip · mixed browse row · editorial insights — more magazine, less list."
      tags={["hero: layered collage card", "mixed-media browse", "editorial", "creative take"]}
      notes="The more adventurous option. Treats Home less like a catalog and more like a personal front page of the library. Still grounded in the same content types — just recomposed.">
      
      {(dark) =>
      <div style={{ display: "flex", flexDirection: "column", gap: 28 }}>
          <HeroC heroSize={heroSize} showAnn={showAnn} />

          {/* Today strip: featured album + artist moments */}
          <div>
            <SectionHeader eyebrow="TODAY" title="From your library" right="Shuffle all ⤳" />
            <div style={{ display: "grid", gridTemplateColumns: "1.1fr 2fr", gap: 20 }}>
              <div className="stroke" style={{ padding: 14, display: "flex", gap: 14, alignItems: "center" }}>
                <AlbumSquare size={120} hatch="hatch-dense" rounded={8} />
                <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
                  <div className="h-eyebrow">Featured album</div>
                  <div className="sketch" style={{ fontSize: 22, fontWeight: 600, lineHeight: 1 }}>Album title</div>
                  <div className="sketch" style={{ fontSize: 16, color: "var(--ink-soft)", lineHeight: 1 }}>Artist · 11 songs</div>
                  <Meta style={{ marginTop: 4 }}>last played 3 days ago</Meta>
                  <div style={{ marginTop: 6 }}><PlayPill /></div>
                </div>
              </div>
              <div>
                <div className="h-eyebrow" style={{ marginBottom: 10 }}>Artists in rotation</div>
                <ArtistsRow density="tight" count={7} />
              </div>
            </div>
          </div>

          {/* Mixed browse */}
          <div>
            <SectionHeader eyebrow="BROWSE" title="Albums & playlists" right="Filter ⌄" />
            <div style={{ display: "grid", gridTemplateColumns: "repeat(6, 1fr)", gap: density === "tight" ? 10 : 14 }}>
              {/* 3 albums */}
              {["hatch", "hatch-b", "hatch-dense"].map((h, i) =>
            <div key={"a" + i} style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                  <AlbumSquare size="100%" hatch={h} rounded={8} />
                  <div style={{ padding: "0 2px" }}>
                    <TLine w="80%" h={9} dark />
                    <TLine w="55%" h={7} style={{ marginTop: 4 }} />
                    <Meta style={{ marginTop: 4 }}>album · 11 songs</Meta>
                  </div>
                </div>
            )}
              {/* 3 playlists with distinct treatment */}
              {["hatch-b", "hatch-dense", "hatch"].map((h, i) =>
            <div key={"p" + i} className="stroke" style={{ padding: 10, display: "flex", flexDirection: "column", gap: 8, position: "relative", overflow: "hidden" }}>
                  <div className={h} style={{ position: "absolute", inset: 0, opacity: 0.4 }} />
                  <AlbumSquare size="100%" hatch={h} rounded={6} shadow={false} />
                  <div style={{ position: "relative" }}>
                    <div className="h-eyebrow">PLAYLIST</div>
                    <TLine w="80%" h={9} dark style={{ marginTop: 4 }} />
                    <Meta style={{ marginTop: 4 }}>42 songs · 2h 48m</Meta>
                  </div>
                </div>
            )}
            </div>
            {showAnn &&
          <div className="note-text" style={{ marginTop: 8 }}>
                ↑ playlists &amp; albums share one grid — cards distinguish themselves by chrome, not section.
              </div>
          }
          </div>

          {/* Editorial insights */}
          <div>
            <SectionHeader eyebrow="YOU" title="Listening Insights" right="Open report →" />
            <InsightsC />
          </div>
        </div>
      }
    </VariationShell>);

}

// ─────────────────────────────────────────────────────────────
// App
// ─────────────────────────────────────────────────────────────
function App() {
  const [tweaks, setTweak] = window.useTweaks(window.__TWEAK_DEFAULTS__);
  const { TweaksPanel, TweakSection, TweakRadio, TweakToggle } = window;

  const heroSize = tweaks.heroSize;
  const density = tweaks.cardDensity;
  const showAnn = tweaks.showAnnotations;

  return (
    <>
      <div className="page-shell">
        {/* page header */}
        <header className="page-hd">
          <div>
            <div className="h-eyebrow" style={{ marginBottom: 6 }}>macOS music player — wireframes</div>
            <h1>Home page · 3 directions</h1>
          </div>
          <div className="sub">
            low-fi structural sketches · light + dark per variation<br />
            for exploring hero scale, section order, and density
          </div>
        </header>

        <VariationA heroSize={heroSize} density={density} showAnn={showAnn} />
        <VariationB heroSize={heroSize} density={density} showAnn={showAnn} />
        <VariationC heroSize={heroSize} density={density} showAnn={showAnn} />

        <footer style={{ marginTop: 72, paddingTop: 20, borderTop: "1px solid var(--line-soft)", display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          <div className="h-eyebrow">end of wireframes · next — pick a direction to refine</div>
          <div className="mono" style={{ fontSize: 10, color: "var(--ink-faint)" }}>v1 · apr 2026</div>
        </footer>
      </div>

      <TweaksPanel title="Tweaks">
        <TweakSection label="Display" />
        <TweakToggle
          label="Annotations"
          value={showAnn}
          onChange={(v) => setTweak("showAnnotations", v)} />
        

        <TweakSection label="Hero size" />
        <TweakRadio
          label="Size"
          value={heroSize}
          onChange={(v) => setTweak("heroSize", v)}
          options={["compact", "balanced", "dominant"]} />
        

        <TweakSection label="Card density" />
        <TweakRadio
          label="Density"
          value={density}
          onChange={(v) => setTweak("cardDensity", v)}
          options={["tight", "standard", "airy"]} />
        
      </TweaksPanel>
    </>);

}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);