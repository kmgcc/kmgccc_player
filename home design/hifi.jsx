/* global React, ReactDOM */
const { useState, useEffect, useMemo } = React;
const { ALBUMS, ARTISTS, PLAYLISTS, RANKING, HERO_TRACK, coverStyle } = window;

// ─────────────────────────────────────────────────────────────
// Icons (hand-rolled, tiny, aligned w/ macOS SF-style)
// ─────────────────────────────────────────────────────────────
const I = {
  play: (size = 12, fill = "currentColor") => (
    <svg width={size} height={size} viewBox="0 0 12 12" fill="none">
      <path d="M3 2.2v7.6c0 .5.54.8.98.55l6-3.8a.65.65 0 0 0 0-1.1l-6-3.8A.65.65 0 0 0 3 2.2Z" fill={fill}/>
    </svg>
  ),
  chevR: (size = 14) => (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none">
      <path d="M6 3.5 10.5 8 6 12.5" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round"/>
    </svg>
  ),
  heart: (size = 15) => (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none">
      <path d="M8 13.5s-5-3.1-5-6.6A2.9 2.9 0 0 1 8 5a2.9 2.9 0 0 1 5 1.9c0 3.5-5 6.6-5 6.6Z" stroke="currentColor" strokeWidth="1.3"/>
    </svg>
  ),
  queue: (size = 15) => (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round">
      <path d="M3 5h10M3 8h10M3 11h6"/>
    </svg>
  ),
  more: (size = 15) => (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="currentColor">
      <circle cx="4" cy="8" r="1.1"/><circle cx="8" cy="8" r="1.1"/><circle cx="12" cy="8" r="1.1"/>
    </svg>
  ),
};

// ─────────────────────────────────────────────────────────────
// Cover — renders the artwork with the computed gradient stack
// ─────────────────────────────────────────────────────────────
function Cover({ data, size, radius = 14, style = {}, circle = false }) {
  const cs = coverStyle(data);
  return (
    <div
      className="cover"
      style={{
        width: size,
        height: size,
        borderRadius: circle ? "50%" : radius,
        ...cs,
        ...style,
      }}
    />
  );
}

// ─────────────────────────────────────────────────────────────
// HERO
// ─────────────────────────────────────────────────────────────
function Hero({ heroSize }) {
  const t = HERO_TRACK;
  const h = heroSize === "compact" ? 280 : heroSize === "dominant" ? 380 : 320;
  const cover = h - 56;
  const cs = coverStyle(t);
  return (
    <div className="hero" style={{ height: h }}>
      {/* blurred album art backdrop */}
      <div className="hero-bg" style={cs} />
      <div className="hero-scrim" />
      <div className="hero-inner">
        <Cover data={t} size={cover} radius={18} />
        <div style={{ minWidth: 0, display: "flex", flexDirection: "column", gap: 8 }}>
          <div className="eyebrow">Now playing · from your library</div>
          <h1 className="t-display" style={{ margin: 0, fontSize: 44, lineHeight: 1.02, color: "var(--ink)", letterSpacing: "-0.025em" }}>
            {t.title}
          </h1>
          <div style={{ display: "flex", alignItems: "center", gap: 0, color: "var(--ink-2)", fontSize: 16, fontWeight: 500 }}>
            <span>{t.artist}</span>
            <span className="meta-dot">·</span>
            <span style={{ color: "var(--ink-3)" }}>{t.album}</span>
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: 0, color: "var(--ink-3)", fontSize: 12, marginTop: 2 }}>
            <span>{t.year}</span>
            <span className="meta-dot">·</span>
            <span>{t.genre}</span>
            <span className="meta-dot">·</span>
            <span>{t.duration}</span>
            <span className="meta-dot">·</span>
            <span>{t.quality}</span>
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: 10, marginTop: 18 }}>
            <button className="btn-play">
              <span className="dot">{I.play(11)}</span>
              Play
            </button>
            <button className="btn-ghost">{I.queue()} Add to queue</button>
            <button className="btn-icon" title="Favorite">{I.heart()}</button>
            <button className="btn-icon" title="More">{I.more()}</button>
          </div>
        </div>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// ALBUMS
// ─────────────────────────────────────────────────────────────
function AlbumTile({ a }) {
  const size = 168;
  return (
    <div style={{ width: size, flex: "0 0 auto", display: "flex", flexDirection: "column", gap: 10 }}>
      <Cover data={a} size={size} radius={16} />
      <div style={{ paddingTop: 2 }}>
        <div className="t-display" style={{ fontSize: 14, fontWeight: 600, color: "var(--ink)", letterSpacing: "-0.005em", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
          {a.title}
        </div>
        <div style={{ fontSize: 12, color: "var(--ink-3)", marginTop: 2, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
          {a.artist}
        </div>
        <div style={{ fontSize: 11, color: "var(--ink-4)", marginTop: 4 }}>
          {a.songs} songs<span className="meta-dot">·</span>{a.minutes} min
        </div>
      </div>
    </div>
  );
}

function Albums() {
  return (
    <section>
      <div className="section-hd">
        <div>
          <div className="eyebrow" style={{ marginBottom: 4 }}>From your library</div>
          <div className="section-title">Albums</div>
        </div>
        <a className="section-link" href="#">See all {I.chevR(12)}</a>
      </div>
      <div className="hrow">
        {ALBUMS.map(a => <AlbumTile key={a.id} a={a} />)}
      </div>
    </section>
  );
}

// ─────────────────────────────────────────────────────────────
// ARTISTS
// ─────────────────────────────────────────────────────────────
function ArtistTile({ a }) {
  const size = 148;
  return (
    <div style={{ width: size + 20, flex: "0 0 auto", display: "flex", flexDirection: "column", alignItems: "center", gap: 12 }}>
      <Cover data={a} size={size} circle style={{ boxShadow: "0 0 0 1px rgba(0,0,0,0.06), 0 10px 20px -10px rgba(0,0,0,0.35)" }} />
      <div style={{ textAlign: "center", paddingTop: 2 }}>
        <div className="t-display" style={{ fontSize: 14, fontWeight: 600, color: "var(--ink)", letterSpacing: "-0.005em" }}>
          {a.name}
        </div>
        <div style={{ fontSize: 11, color: "var(--ink-4)", marginTop: 3 }}>
          {a.albums} albums<span className="meta-dot">·</span>{a.songs} songs
        </div>
      </div>
    </div>
  );
}

function Artists() {
  return (
    <section>
      <div className="section-hd">
        <div>
          <div className="eyebrow" style={{ marginBottom: 4 }}>People</div>
          <div className="section-title">Artists</div>
        </div>
        <a className="section-link" href="#">See all {I.chevR(12)}</a>
      </div>
      <div className="hrow" style={{ gap: 28 }}>
        {ARTISTS.map(a => <ArtistTile key={a.id} a={a} />)}
      </div>
    </section>
  );
}

// ─────────────────────────────────────────────────────────────
// PLAYLISTS — compact, 2-col grid, no play button
// ─────────────────────────────────────────────────────────────
function PlaylistCard({ p }) {
  const cs = coverStyle(p);
  return (
    <div className="pcard" style={{ height: 96, flex: "0 0 auto" }}>
      <div className="pcard-bg" style={cs} />
      <div className="pcard-scrim" />
      <div className="pcard-inner">
        <Cover data={p} size={68} radius={12} style={{ flex: "0 0 auto" }} />
        <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", gap: 4 }}>
          <div className="t-display" style={{
            fontSize: 15, fontWeight: 600, color: "var(--ink)",
            letterSpacing: "-0.005em",
            whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis",
          }}>
            {p.name}
          </div>
          <div style={{ fontSize: 12, color: "var(--ink-3)", display: "flex", alignItems: "center", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
            <span>{p.songs} songs</span>
            <span className="meta-dot">·</span>
            <span>{p.hours} hr {p.minutes} min</span>
          </div>
          <div style={{ fontSize: 11, color: "var(--ink-4)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
            {p.note}
          </div>
        </div>
      </div>
    </div>
  );
}

function Playlists() {
  return (
    <section>
      <div className="section-hd">
        <div>
          <div className="eyebrow" style={{ marginBottom: 4 }}>Curated</div>
          <div className="section-title">Playlists</div>
        </div>
        <a className="section-link" href="#">New playlist +</a>
      </div>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: 14 }}>
        {PLAYLISTS.map(p => <PlaylistCard key={p.id} p={p} />)}
      </div>
    </section>
  );
}

// ─────────────────────────────────────────────────────────────
// INSIGHTS — simple stat cards + preference ranking
// ─────────────────────────────────────────────────────────────
function StatCard({ label, value, unit, subtitle }) {
  return (
    <div className="stat">
      <div className="eyebrow" style={{ fontSize: 10 }}>{label}</div>
      <div style={{ display: "flex", alignItems: "baseline", gap: 6, marginTop: "auto" }}>
        <div className="num">{value}</div>
        {unit && <div className="unit">{unit}</div>}
      </div>
      {subtitle && <div className="unit" style={{ color: "var(--ink-4)", fontSize: 11 }}>{subtitle}</div>}
    </div>
  );
}

function FavoriteArtistStat() {
  const a = ARTISTS[0]; // Noa Linden
  return (
    <div className="stat" style={{ justifyContent: "flex-end" }}>
      <div className="eyebrow" style={{ fontSize: 10 }}>Favorite artist</div>
      <div style={{ display: "flex", alignItems: "center", gap: 12, marginTop: "auto" }}>
        <Cover data={a} size={40} circle style={{ flex: "0 0 auto" }} />
        <div style={{ minWidth: 0 }}>
          <div className="t-display" style={{ fontSize: 16, fontWeight: 600, letterSpacing: "-0.01em", color: "var(--ink)" }}>
            {a.name}
          </div>
          <div className="unit">{a.albums} albums · this month</div>
        </div>
      </div>
    </div>
  );
}

function Heatmap() {
  // Year view — 12 months across, ~5 weeks tall. Highlight current month (April).
  const months = ["J","F","M","A","M","J","J","A","S","O","N","D"];
  const currentMonth = 3; // April (0-indexed)
  // Generate 7 rows (days of week) × 53 weeks = GitHub-style, but compact:
  // Use 7 rows × 52 cols. Each column = week.
  const rows = 7;
  const cols = 52;
  const cells = [];
  for (let c = 0; c < cols; c++) {
    for (let r = 0; r < rows; r++) {
      // Estimated month for this week (0-11)
      const m = Math.floor((c / cols) * 12);
      // Pseudo-random intensity with some seasonality
      const base = (Math.sin(c * 0.35 + r * 0.6) + 1) * 0.5;
      const noise = ((c * 7 + r * 13) % 5) / 5;
      let v = Math.floor((base * 0.6 + noise * 0.4) * 5);
      if (v > 4) v = 4;
      // Weekends lightly lower, weekdays a bit higher
      if (r === 5 || r === 6) v = Math.max(0, v - 1);
      cells.push({ c, r, m, v });
    }
  }
  return (
    <div className="rank" style={{ padding: "14px 16px 14px", display: "flex", flexDirection: "column", gap: 10, height: "100%" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline" }}>
        <div className="t-display" style={{ fontSize: 14, fontWeight: 600, color: "var(--ink)", letterSpacing: "-0.005em" }}>Daily listening</div>
        <div className="t-mono" style={{ fontSize: 10, color: "var(--ink-4)" }}>2026 · APR</div>
      </div>
      <div style={{ display: "grid", gridTemplateRows: `repeat(${rows}, 1fr)`, gridAutoFlow: "column", gridTemplateColumns: `repeat(${cols}, 1fr)`, gap: 2, flex: 1, minHeight: 92 }}>
        {cells.map((cell, i) => {
          const inCurrent = cell.m === currentMonth;
          const bg = cell.v === 0
            ? "var(--hair)"
            : `color-mix(in oklab, var(--accent) ${18 + cell.v*16}%, transparent)`;
          return (
            <div key={i} style={{
              borderRadius: 2,
              background: bg,
              outline: inCurrent ? "1px solid color-mix(in oklab, var(--accent) 70%, transparent)" : "none",
              outlineOffset: inCurrent ? "-1px" : 0,
            }}/>
          );
        })}
      </div>
      <div style={{ display: "grid", gridTemplateColumns: `repeat(12, 1fr)`, color: "var(--ink-4)", fontSize: 10, textAlign: "center", marginTop: 2 }}>
        {months.map((m, i) => (
          <div key={i} style={{
            color: i === currentMonth ? "var(--ink)" : "var(--ink-4)",
            fontWeight: i === currentMonth ? 600 : 400,
          }}>{m}</div>
        ))}
      </div>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", color: "var(--ink-4)", fontSize: 10 }}>
        <span>Less</span>
        <div style={{ display: "flex", gap: 3 }}>
          {[0,1,2,3,4].map(v => (
            <div key={v} style={{
              width: 10, height: 10, borderRadius: 2,
              background: v === 0 ? "var(--hair)" : `color-mix(in oklab, var(--accent) ${18 + v*16}%, transparent)`,
            }}/>
          ))}
        </div>
        <span>More</span>
      </div>
    </div>
  );
}

function Ranking() {
  return (
    <div className="rank">
      <div className="rank-row head">
        <div style={{ textAlign: "center" }}>#</div>
        <div></div>
        <div>Song · Artist</div>
        <div>Preference</div>
        <div style={{ textAlign: "right" }}>Plays</div>
      </div>
      {RANKING.map((r, i) => {
        const album = ALBUMS.find(a => a.title === r.title) || ALBUMS[i % ALBUMS.length];
        return (
          <div className="rank-row" key={r.id}>
            <div className="rank-num">{r.id}</div>
            <Cover data={album} size={40} radius={8} />
            <div style={{ minWidth: 0 }}>
              <div className="t-display" style={{ fontSize: 14, fontWeight: 600, letterSpacing: "-0.005em", color: "var(--ink)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
                {r.title}
              </div>
              <div style={{ fontSize: 12, color: "var(--ink-3)", marginTop: 2 }}>{r.artist}</div>
            </div>
            <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
              <div className="bar-track"><div className="bar-fill" style={{ width: `${r.score * 100}%` }}/></div>
              <div className="t-mono" style={{ fontSize: 11, color: "var(--ink-3)", minWidth: 30, textAlign: "right" }}>
                {r.score.toFixed(2)}
              </div>
            </div>
            <div className="t-mono" style={{ fontSize: 12, color: "var(--ink-2)", textAlign: "right" }}>{r.plays}</div>
          </div>
        );
      })}
    </div>
  );
}

function Insights() {
  return (
    <section>
      <div className="section-hd">
        <div>
          <div className="eyebrow" style={{ marginBottom: 4 }}>You</div>
          <div className="section-title">Listening Insights</div>
        </div>
        <a className="section-link" href="#">Last 30 days</a>
      </div>
      <div className="stats" style={{ marginBottom: 14 }}>
        <StatCard label="Total songs"     value="2,418"  unit="tracks" subtitle="in your library" />
        <StatCard label="Total plays"     value="18,204" unit="plays"  subtitle="all-time" />
        <StatCard label="Listening time"  value="412"    unit="hours"  subtitle="this year · +8% vs last" />
        <FavoriteArtistStat />
      </div>
      <div style={{ marginTop: 18, display: "grid", gridTemplateColumns: "1.8fr 1fr", gap: 14, alignItems: "stretch" }}>
        <div>
          <div className="eyebrow" style={{ marginBottom: 10 }}>Preference ranking</div>
          <Ranking />
        </div>
        <div>
          <div className="eyebrow" style={{ marginBottom: 10 }}>Daily listening</div>
          <Heatmap />
        </div>
      </div>
    </section>
  );
}

// ─────────────────────────────────────────────────────────────
// App
// ─────────────────────────────────────────────────────────────
function App() {
  const [tweaks, setTweak] = window.useTweaks(window.__TWEAK_DEFAULTS__);
  const { TweaksPanel, TweakSection, TweakRadio } = window;
  const theme = tweaks.theme;
  const heroSize = tweaks.heroSize;

  useEffect(() => {
    document.documentElement.classList.toggle("theme-dark", theme === "dark");
    document.documentElement.classList.toggle("theme-light", theme !== "dark");
  }, [theme]);

  return (
    <>
      <div className="stage">
        <div className="theme-toolbar">
          <div style={{ fontSize: 12, color: "var(--ink-3)" }}>
            <span className="eyebrow" style={{ fontSize: 10 }}>Music · Home</span>
          </div>
          <div className="pill" role="tablist" aria-label="Theme">
            <button className={theme !== "dark" ? "on" : ""} onClick={() => setTweak("theme", "light")}>Light</button>
            <button className={theme === "dark" ? "on" : ""} onClick={() => setTweak("theme", "dark")}>Dark</button>
          </div>
        </div>

        <div className="window">
          <div className="content" style={{ display: "flex", flexDirection: "column", gap: 36 }}>
            <Hero heroSize={heroSize} />
            <Albums />
            <Artists />
            <Playlists />
            <Insights />
            <footer style={{ padding: "56px 24px 24px", textAlign: "center", display: "flex", flexDirection: "column", gap: 8, alignItems: "center" }}>
              <div className="t-display" style={{ fontSize: 22, fontWeight: 500, color: "var(--ink-2)", letterSpacing: "-0.01em", fontStyle: "italic" }}>
                “Where words fail, music speaks.”
              </div>
              <div style={{ fontSize: 14, color: "var(--ink-3)" }}>
                言所不及处，笙箫相继。
              </div>
              <div className="eyebrow" style={{ fontSize: 10, color: "var(--ink-4)", marginTop: 6 }}>— Hans Christian Andersen</div>
            </footer>
          </div>
        </div>
      </div>

      <TweaksPanel title="Tweaks">
        <TweakSection label="Theme" />
        <TweakRadio
          label="Mode"
          value={theme}
          onChange={(v) => setTweak("theme", v)}
          options={["light", "dark"]}
        />
        <TweakSection label="Hero size" />
        <TweakRadio
          label="Size"
          value={heroSize}
          onChange={(v) => setTweak("heroSize", v)}
          options={["compact", "balanced", "dominant"]}
        />
      </TweaksPanel>
    </>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
