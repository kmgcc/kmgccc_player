/* global React */
// ─────────────────────────────────────────────────────────────
// Artwork generator — produces editorial abstract "album covers"
// from a palette of 2-3 colors + a style key. No noisy imagery.
// Each cover is distinct, tasteful, and feeds the hero blur.
// ─────────────────────────────────────────────────────────────

function coverStyle({ palette, style, seed = 0 }) {
  const [a, b, c] = palette;
  const mid = c || b;
  // A few composition archetypes — keep them calm and editorial
  switch (style) {
    case "halo":
      return {
        background: `
          radial-gradient(80% 70% at 30% 30%, ${a} 0%, ${b} 55%, ${mid} 100%)
        `,
      };
    case "horizon":
      return {
        background: `
          linear-gradient(180deg, ${a} 0%, ${a} 45%, ${b} 55%, ${mid} 100%)
        `,
      };
    case "arc":
      return {
        background: `
          radial-gradient(120% 80% at 50% 120%, ${b} 0%, ${a} 60%, ${mid} 100%),
          linear-gradient(180deg, ${a}, ${mid})
        `,
      };
    case "dune":
      return {
        background: `
          radial-gradient(120% 80% at 20% 100%, ${b} 0%, transparent 55%),
          radial-gradient(100% 70% at 100% 0%, ${mid} 0%, transparent 60%),
          linear-gradient(160deg, ${a}, ${mid})
        `,
      };
    case "dusk":
      return {
        background: `
          linear-gradient(180deg, ${a} 0%, ${b} 60%, ${mid} 100%),
          radial-gradient(60% 40% at 80% 20%, rgba(255,255,255,0.18), transparent 60%)
        `,
      };
    case "split":
      return {
        background: `
          linear-gradient(105deg, ${a} 0%, ${a} 48%, ${b} 52%, ${b} 100%)
        `,
      };
    case "veil":
      return {
        background: `
          radial-gradient(80% 60% at 50% 40%, rgba(255,255,255,0.22), transparent 60%),
          conic-gradient(from 210deg at 50% 55%, ${a}, ${b}, ${mid}, ${a})
        `,
      };
    case "wash":
      return {
        background: `
          linear-gradient(200deg, ${a}, ${b} 60%, ${mid})
        `,
      };
    default:
      return { background: `linear-gradient(160deg, ${a}, ${b})` };
  }
}

// Palettes tuned to be calm — low saturation, cinematic
const ALBUMS = [
  { id: "a1", title: "Slow Rivers",      artist: "Noa Linden",      year: 2023, songs: 11, minutes: 42,
    palette: ["#6F8AA3","#2C3947","#C9B79A"], style: "horizon" },
  { id: "a2", title: "Paper Gardens",    artist: "Kōta Mori",       year: 2022, songs: 9,  minutes: 38,
    palette: ["#C7A27A","#7A4A31","#2F1E17"], style: "dune" },
  { id: "a3", title: "Northern Light",   artist: "Ilse Wennberg",   year: 2024, songs: 8,  minutes: 33,
    palette: ["#B8CDD6","#4E6E83","#1E2A35"], style: "halo" },
  { id: "a4", title: "The Long Coast",   artist: "Petar Marinov",   year: 2021, songs: 12, minutes: 49,
    palette: ["#2D3D2F","#89A080","#D5D1B5"], style: "arc" },
  { id: "a5", title: "Softer, Still",    artist: "Evie Harlan",     year: 2023, songs: 10, minutes: 40,
    palette: ["#D9C6C0","#A06A6A","#3B1F1F"], style: "dusk" },
  { id: "a6", title: "Harbour, 4am",     artist: "Arda Selim",      year: 2024, songs: 7,  minutes: 29,
    palette: ["#1B2230","#3A5270","#AEB9C4"], style: "wash" },
  { id: "a7", title: "Orchard Hours",    artist: "Mae Sørensen",    year: 2020, songs: 13, minutes: 52,
    palette: ["#EAD8B5","#B38F4E","#4A3520"], style: "split" },
];

const ARTISTS = [
  { id: "r1", name: "Noa Linden",    albums: 4, songs: 41, palette: ["#6F8AA3","#2C3947","#C9B79A"], style: "horizon" },
  { id: "r2", name: "Kōta Mori",     albums: 3, songs: 27, palette: ["#C7A27A","#7A4A31","#2F1E17"], style: "dune" },
  { id: "r3", name: "Ilse Wennberg", albums: 5, songs: 48, palette: ["#B8CDD6","#4E6E83","#1E2A35"], style: "halo" },
  { id: "r4", name: "Petar Marinov", albums: 2, songs: 19, palette: ["#2D3D2F","#89A080","#D5D1B5"], style: "arc" },
  { id: "r5", name: "Evie Harlan",   albums: 6, songs: 61, palette: ["#D9C6C0","#A06A6A","#3B1F1F"], style: "dusk" },
  { id: "r6", name: "Arda Selim",    albums: 3, songs: 24, palette: ["#1B2230","#3A5270","#AEB9C4"], style: "wash" },
  { id: "r7", name: "Mae Sørensen",  albums: 4, songs: 38, palette: ["#EAD8B5","#B38F4E","#4A3520"], style: "split" },
  { id: "r8", name: "June Asano",    albums: 2, songs: 17, palette: ["#C2D3C0","#5B7A6B","#23302C"], style: "veil" },
];

const PLAYLISTS = [
  { id: "p1", name: "Late drives",       songs: 42, hours: 2, minutes: 48, note: "updated yesterday",
    palette: ["#1C2330","#44607E","#A8B6C3"], style: "wash" },
  { id: "p2", name: "Morning desk",      songs: 31, hours: 2, minutes:  5, note: "mostly acoustic",
    palette: ["#E2D4BC","#B0905E","#4C3924"], style: "dune" },
  { id: "p3", name: "Rainy afternoon",   songs: 56, hours: 3, minutes: 41, note: "mellow · ambient",
    palette: ["#B5C6CC","#586E7B","#1E2A30"], style: "halo" },
  { id: "p4", name: "Kitchen radio",     songs: 24, hours: 1, minutes: 32, note: "upbeat picks",
    palette: ["#D3BFAD","#8C5A47","#2F1B15"], style: "split" },
  { id: "p5", name: "Evenings alone",    songs: 38, hours: 2, minutes: 22, note: "added 3 this week",
    palette: ["#CDC0BA","#8C6A6A","#2C1A1F"], style: "dusk" },
  { id: "p6", name: "Quiet company",     songs: 29, hours: 1, minutes: 58, note: "mostly instrumental",
    palette: ["#C3D0BF","#637968","#1E2A23"], style: "arc" },
  { id: "p7", name: "Long walks",        songs: 47, hours: 3, minutes: 12, note: "mid-tempo folk",
    palette: ["#D6C9B4","#8A7454","#2E2618"], style: "horizon" },
  { id: "p8", name: "Reading corner",    songs: 22, hours: 1, minutes: 28, note: "piano · strings",
    palette: ["#C6C6D1","#6A6A85","#21212E"], style: "veil" },
  { id: "p9", name: "Sunday slow",       songs: 35, hours: 2, minutes: 14, note: "refreshed weekly",
    palette: ["#E6DAC5","#A08456","#3C2E1C"], style: "dusk" },
];

const RANKING = [
  { id: 1, title: "Second Light",    artist: "Noa Linden",    score: 0.96, plays: 142 },
  { id: 2, title: "Paper Garden",    artist: "Kōta Mori",     score: 0.92, plays: 128 },
  { id: 3, title: "Harbour 4am",     artist: "Arda Selim",    score: 0.88, plays: 117 },
  { id: 4, title: "Slow Rivers",     artist: "Noa Linden",    score: 0.84, plays:  98 },
  { id: 5, title: "Orchard Hours",   artist: "Mae Sørensen",  score: 0.80, plays:  86 },
  { id: 6, title: "Hemlock Road",    artist: "Petar Marinov", score: 0.76, plays:  74 },
];

const HERO_TRACK = {
  title: "Second Light",
  artist: "Noa Linden",
  album: "Slow Rivers",
  year: 2023,
  duration: "4:12",
  genre: "Alternative",
  quality: "Lossless · 24-bit / 96 kHz",
  palette: ["#7191AE","#2C3947","#C9B79A"],
  style: "horizon",
};

Object.assign(window, { ALBUMS, ARTISTS, PLAYLISTS, RANKING, HERO_TRACK, coverStyle });
