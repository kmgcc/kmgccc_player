/* global React, ReactDOM */
const { useState, useEffect, useMemo } = React;

// ─────────────────────────────────────────────────────────────
// Primitives — v2, softer radii, calmer chrome
// ─────────────────────────────────────────────────────────────

// Corner radii scale — bumped across the board
const R = {
  card:     14,  // stat cards, playlist cards
  canvas:   20,  // hero panel, insights wrapper
  cover:    14,  // album covers in rows
  coverLg:  18,  // hero cover
  coverSm:  12,  // playlist cover inside card
  pill:     999,
};

function AlbumSquare({ size, hatch = "hatch", label, tag, rounded = R.cover, shadow = true }) {
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
        flex: "0 0 auto",
      }}
    >
      {tag && <div className="blk-tag" style={{ position: "absolute", left: 8, top: 8 }}>{tag}</div>}
      {label && <div className="blk-label" style={{ position: "absolute", right: 8, bottom: 4 }}>{label}</div>}
    </div>
  );
}

function ArtistCircle({ size, hatch = "hatch-b" }) {
  return (
    <div
      className={hatch}
      style={{
        width: size,
        height: size,
        borderRadius: "50%",
        border: "1.25px solid var(--line)",
        boxShadow: "2px 3px 0 rgba(26,28,31,0.06)",
        flex: "0 0 auto",
      }}
    />
  );
}

function TLine({ w, h = 10, dark = false, style }) {
  return (
    <div
      style={{
        width: w,
        height: h,
        borderRadius: 3,
        background: dark ? "var(--ink)" : "var(--line-soft)",
        opacity: dark ? 0.85 : 0.75,
        ...style,
      }}
    />
  );
}

function Meta({ children, style }) {
  return <div className="mono" style={{ fontSize: 10, letterSpacing: "0.04em", color: "var(--ink-faint)", ...style }}>{children}</div>;
}

function SectionHeader({ eyebrow, title, right }) {
  return (
    <div style={{ display: "flex", alignItems: "flex-end", justifyContent: "space-between", marginBottom: 14 }}>
      <div>
        {eyebrow && <div className="h-eyebrow" style={{ marginBottom: 4 }}>{eyebrow}</div>}
        <div className="h-title" style={{ fontWeight: 600 }}>{title}</div>
      </div>
      {right && <div className="mono" style={{ fontSize: 10, color: "var(--ink-faint)" }}>{right}</div>}
    </div>
  );
}

function PlayPill({ label = "Play" }) {
  return (
    <div style={{
      display: "inline-flex", alignItems: "center", gap: 8,
      border: "1.5px solid var(--line)", borderRadius: R.pill,
      padding: "6px 14px 6px 8px", background: "var(--paper)",
    }}>
      <div style={{
        width: 20, height: 20, borderRadius: "50%",
        background: "var(--ink)", display: "inline-flex", alignItems: "center", justifyContent: "center",
      }}>
        <div style={{
          width: 0, height: 0,
          borderLeft: "6px solid var(--paper)",
          borderTop: "4px solid transparent",
          borderBottom: "4px solid transparent",
          marginLeft: 2,
        }}/>
      </div>
      <div className="sketch" style={{ fontSize: 18, lineHeight: 1 }}>{label}</div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// HERO — unchanged structure, softened radii
// ─────────────────────────────────────────────────────────────
function Hero({ heroSize, showAnn }) {
  const h = heroSize === "compact" ? 230 : heroSize === "dominant" ? 340 : 280;
  const cover = h - 40;
  return (
    <div className="stroke" style={{
      position: "relative", height: h, padding: 20,
      display: "flex", gap: 22, overflow: "hidden",
      borderRadius: R.canvas,
    }}>
      <div className="dissolve" style={{ position: "absolute", inset: 0, left: cover + 40 - 80 }} />
      <AlbumSquare size={cover} hatch="hatch-dense" tag="ALBUM ART" label="hero cover" rounded={R.coverLg} />
      <div style={{ position: "relative", flex: 1, display: "flex", flexDirection: "column", justifyContent: "center", gap: 10, paddingLeft: 8 }}>
        <div className="h-eyebrow">Now playing · from your library</div>
        <div className="sketch" style={{ fontSize: 40, lineHeight: 1, fontWeight: 600, color: "var(--ink)" }}>Song title</div>
        <div className="sketch" style={{ fontSize: 22, lineHeight: 1, color: "var(--ink-soft)" }}>Artist name — Album</div>
        <Meta style={{ marginTop: 4 }}>4:12 · 2019 · Alternative · Lossless</Meta>
        <div style={{ marginTop: 14, display: "flex", gap: 10, alignItems: "center" }}>
          <PlayPill />
          <div style={{
            height: 32, padding: "0 14px", display: "inline-flex", alignItems: "center",
            border: "1.25px solid var(--line-soft)", borderRadius: R.pill, color: "var(--ink-soft)",
          }} className="sketch">Queue</div>
          <div style={{
            width: 32, height: 32, display: "inline-flex", alignItems: "center", justifyContent: "center",
            border: "1.25px solid var(--line-soft)", borderRadius: "50%", color: "var(--ink-soft)",
          }} className="sketch">♡</div>
        </div>
      </div>

      {showAnn && (
        <>
          <div className="note-text" style={{ position: "absolute", right: 18, top: 14, width: 220, textAlign: "right" }}>
            blurred artwork dissolves<br/>from cover → right edge
          </div>
          <div className="note-text" style={{ position: "absolute", left: cover + 30, bottom: 10, width: 180 }}>
            text stays high-contrast<br/>over the haze
          </div>
        </>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Albums row
// ─────────────────────────────────────────────────────────────
function AlbumsRow({ density }) {
  const hatches = ["hatch","hatch-b","hatch-dense","hatch","hatch-b","hatch-dense","hatch"];
  const size = density === "tight" ? 110 : density === "airy" ? 170 : 140;
  const n = density === "tight" ? 7 : density === "airy" ? 5 : 6;
  return (
    <div style={{ display: "flex", gap: density === "tight" ? 12 : 18, overflow: "hidden" }}>
      {Array.from({ length: n }).map((_, i) => (
        <div key={i} style={{ display: "flex", flexDirection: "column", gap: 8, width: size, flex: "0 0 auto" }}>
          <AlbumSquare size={size} hatch={hatches[i % hatches.length]} rounded={R.cover} />
          <TLine w={size - 20} h={9} dark />
          <TLine w={size - 50} h={8} />
          <Meta>11 songs · 42 min</Meta>
        </div>
      ))}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Artists row
// ─────────────────────────────────────────────────────────────
function ArtistsRow({ density }) {
  const size = density === "tight" ? 74 : density === "airy" ? 112 : 92;
  const n = density === "tight" ? 10 : density === "airy" ? 7 : 8;
  return (
    <div style={{ display: "flex", gap: density === "tight" ? 16 : 28, overflow: "hidden", alignItems: "flex-start" }}>
      {Array.from({ length: n }).map((_, i) => (
        <div key={i} style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 8, width: size + 20, flex: "0 0 auto" }}>
          <ArtistCircle size={size} hatch={i % 2 ? "hatch" : "hatch-b"} />
          <TLine w={size - 10} h={9} dark style={{ marginTop: 4 }} />
          <Meta>3 albums · 47 songs</Meta>
        </div>
      ))}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Playlists — narrower, no Play button, 2-column grid of compact
// horizontal cards. Still "cover left, info right".
// ─────────────────────────────────────────────────────────────
function PlaylistCard({ density, hatchStyle = "hatch" }) {
  const h = density === "tight" ? 80 : density === "airy" ? 104 : 92;
  const cover = h - 18;
  return (
    <div className="stroke" style={{
      position: "relative",
      height: h,
      padding: 9,
      display: "flex",
      gap: 14,
      alignItems: "center",
      overflow: "hidden",
      borderRadius: R.card,
    }}>
      {/* softened background wash */}
      <div style={{ position: "absolute", inset: 0, opacity: 0.32 }} className={hatchStyle}/>
      <AlbumSquare size={cover} hatch={hatchStyle} rounded={R.coverSm} shadow={false} />
      <div style={{ position: "relative", flex: 1, display: "flex", flexDirection: "column", gap: 5, minWidth: 0 }}>
        <div className="sketch" style={{ fontSize: 20, lineHeight: 1, fontWeight: 600 }}>Playlist name</div>
        <TLine w="72%" h={7} />
        <Meta>42 songs · 2 hr 48 min</Meta>
      </div>
    </div>
  );
}

function PlaylistsGrid({ density }) {
  const hatches = ["hatch", "hatch-b", "hatch-dense", "hatch", "hatch-b", "hatch-dense"];
  return (
    <div style={{
      display: "grid",
      gridTemplateColumns: "1fr 1fr",
      gap: density === "tight" ? 10 : 14,
    }}>
      {hatches.map((h, i) => <PlaylistCard key={i} density={density} hatchStyle={h} />)}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Listening Insights — simpler & quieter
// Just a row of stat cards + a preference ranking list.
// No charts, no sparklines.
// ─────────────────────────────────────────────────────────────
function StatCard({ label, value, unit }) {
  return (
    <div className="stroke" style={{
      padding: "14px 16px",
      minHeight: 92,
      display: "flex",
      flexDirection: "column",
      gap: 6,
      borderRadius: R.card,
    }}>
      <div className="h-eyebrow">{label}</div>
      <div style={{ display: "flex", alignItems: "baseline", gap: 6, marginTop: 2 }}>
        <div className="sketch" style={{ fontSize: 30, lineHeight: 1, fontWeight: 600 }}>{value}</div>
      </div>
      {unit && <Meta style={{ marginTop: "auto" }}>{unit}</Meta>}
    </div>
  );
}

function RankingList({ rows = 6 }) {
  return (
    <div className="stroke" style={{ padding: "16px 20px", borderRadius: R.card }}>
      <div style={{
        display: "grid", gridTemplateColumns: "28px 1fr 160px 72px",
        gap: 16, alignItems: "center",
        paddingBottom: 10, borderBottom: "1px solid var(--line-soft)",
      }}>
        <div className="blk-tag">#</div>
        <div className="blk-tag">Song · Artist</div>
        <div className="blk-tag">Score</div>
        <div className="blk-tag" style={{ textAlign: "right" }}>Plays</div>
      </div>
      {Array.from({ length: rows }).map((_, i) => (
        <div key={i} style={{
          display: "grid", gridTemplateColumns: "28px 1fr 160px 72px",
          gap: 16, alignItems: "center",
          padding: "12px 0",
          borderBottom: i === rows - 1 ? "none" : "1px dashed var(--line-soft)",
        }}>
          <div className="sketch" style={{ fontSize: 22, color: "var(--ink-soft)", fontWeight: 600 }}>{i + 1}</div>
          <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
            <TLine w={`${62 - i*4}%`} h={9} dark />
            <TLine w={`${38 - i*3}%`} h={7} />
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
            <div style={{ flex: 1, height: 5, background: "var(--paper-2)", borderRadius: 3, overflow: "hidden" }}>
              <div style={{ width: `${92 - i * 9}%`, height: "100%", background: "var(--ink)", opacity: 0.72 }} />
            </div>
            <div className="mono" style={{ fontSize: 10 }}>{(0.96 - i * 0.07).toFixed(2)}</div>
          </div>
          <div className="mono" style={{ fontSize: 11, textAlign: "right" }}>{140 - i * 19}</div>
        </div>
      ))}
    </div>
  );
}

function Insights() {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(5, 1fr)", gap: 12 }}>
        <StatCard label="Total songs"     value="2,418"  unit="tracks in library" />
        <StatCard label="Total plays"     value="18,204" unit="all time" />
        <StatCard label="Listening time"  value="412 h"  unit="this year" />
        <StatCard label="Favorite artist" value="—"      unit="47 albums" />
        <StatCard label="Active playlist" value="—"      unit="28 plays / 30d" />
      </div>
      <div>
        <div className="h-eyebrow" style={{ marginBottom: 8 }}>Preference ranking · top 6</div>
        <RankingList rows={6} />
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// App
// ─────────────────────────────────────────────────────────────
function App() {
  const [tweaks, setTweak] = window.useTweaks(window.__TWEAK_DEFAULTS__);
  const { TweaksPanel, TweakSection, TweakRadio, TweakToggle } = window;

  const heroSize = tweaks.heroSize;
  const density  = tweaks.cardDensity;
  const showAnn  = tweaks.showAnnotations;

  return (
    <>
      <div className="page-shell">
        {/* page header */}
        <header className="page-hd">
          <div>
            <div className="h-eyebrow" style={{ marginBottom: 6 }}>macOS music player — wireframe v2</div>
            <h1>Home page · revised direction</h1>
          </div>
          <div className="sub">
            classic editorial, calmer &amp; softer<br/>
            narrower playlist cards · quieter insights · larger radii
          </div>
        </header>

        <section style={{ marginTop: 40 }}>
          <div style={{ display: "flex", alignItems: "flex-end", justifyContent: "space-between", gap: 20, marginBottom: 16 }}>
            <div style={{ display: "flex", alignItems: "baseline", gap: 14 }}>
              <div className="sketch" style={{ fontSize: 52, fontWeight: 700, lineHeight: 0.9, color: "var(--accent)" }}>01</div>
              <div>
                <div className="sketch" style={{ fontSize: 34, lineHeight: 1, fontWeight: 600 }}>Classic Editorial · revised</div>
                <div className="h-sub" style={{ marginTop: 4 }}>Hero · Albums · Artists · Playlists · Insights — softer, calmer, more practical.</div>
              </div>
            </div>
            <div style={{ display: "flex", gap: 6, flexWrap: "wrap", justifyContent: "flex-end", maxWidth: 460 }}>
              {[
                "softer corner radii",
                "narrower playlist cards (2-col)",
                "no play button in playlists",
                "quieter insights — no charts",
              ].map(t => (
                <span key={t} className="mono" style={{ fontSize: 10, letterSpacing: "0.04em", padding: "3px 8px", border: "1px solid var(--line-soft)", borderRadius: 999, color: "var(--ink-soft)" }}>{t}</span>
              ))}
            </div>
          </div>

          <div className="pair">
            <div className="canvas" style={{ borderRadius: R.canvas }}>
              <div className="canvas-tag">light <span className="chip">home · default</span></div>
              <div style={{ display: "flex", flexDirection: "column", gap: 28 }}>
                <Hero heroSize={heroSize} showAnn={showAnn} />
                <div>
                  <SectionHeader eyebrow="FROM YOUR LIBRARY" title="Albums" right="See all →" />
                  <AlbumsRow density={density} />
                </div>
                <div>
                  <SectionHeader eyebrow="PEOPLE" title="Artists" right="See all →" />
                  <ArtistsRow density={density} />
                </div>
                <div style={{ position: "relative" }}>
                  <SectionHeader eyebrow="CURATED" title="Playlists" right="New playlist +" />
                  <PlaylistsGrid density={density} />
                  {showAnn && (
                    <div className="note-text" style={{ position: "absolute", right: -8, top: 36, width: 190, textAlign: "right", transform: "translateX(100%)" }}>
                      ← narrower, 2-column grid<br/>
                      <span style={{ opacity: 0.8 }}>no play button — calm &amp; browsable</span>
                    </div>
                  )}
                </div>
                <div style={{ position: "relative" }}>
                  <SectionHeader eyebrow="YOU" title="Listening Insights" right="Last 30 days ▾" />
                  <Insights />
                  {showAnn && (
                    <div className="note-text" style={{ position: "absolute", right: -8, top: 36, width: 190, textAlign: "right", transform: "translateX(100%)" }}>
                      ← stat cards + ranking only<br/>
                      <span style={{ opacity: 0.8 }}>no charts — quieter, more useful</span>
                    </div>
                  )}
                </div>
              </div>
            </div>
            <div className="canvas dark-card" style={{ borderRadius: R.canvas }}>
              <div className="canvas-tag" style={{ background: "var(--paper)" }}>dark <span className="chip">home · night</span></div>
              <div style={{ display: "flex", flexDirection: "column", gap: 28 }}>
                <Hero heroSize={heroSize} showAnn={showAnn} />
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
                  <PlaylistsGrid density={density} />
                </div>
                <div>
                  <SectionHeader eyebrow="YOU" title="Listening Insights" right="Last 30 days ▾" />
                  <Insights />
                </div>
              </div>
            </div>
          </div>
        </section>

        <footer style={{ marginTop: 72, paddingTop: 20, borderTop: "1px solid var(--line-soft)", display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          <div className="h-eyebrow">v2 · revised from variation 01 · apr 2026</div>
          <div className="mono" style={{ fontSize: 10, color: "var(--ink-faint)" }}>home wireframe</div>
        </footer>
      </div>

      <TweaksPanel title="Tweaks">
        <TweakSection label="Display" />
        <TweakToggle
          label="Annotations"
          value={showAnn}
          onChange={(v) => setTweak("showAnnotations", v)}
        />

        <TweakSection label="Hero size" />
        <TweakRadio
          label="Size"
          value={heroSize}
          onChange={(v) => setTweak("heroSize", v)}
          options={["compact", "balanced", "dominant"]}
        />

        <TweakSection label="Card density" />
        <TweakRadio
          label="Density"
          value={density}
          onChange={(v) => setTweak("cardDensity", v)}
          options={["tight", "standard", "airy"]}
        />
      </TweaksPanel>
    </>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
