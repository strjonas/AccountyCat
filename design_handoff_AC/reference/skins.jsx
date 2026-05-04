// Cat Skins — visual styles decoupled from persona/character.
// User picks: persona (voice/personality) × skin (look). Each skin re-renders
// the same cat in its own visual language.
//
// Skins:
//   pixel  — chunky pixel art (8-bit handmade)
//   line   — single-stroke vector, minimal
//   liquid — glass/translucent (Tahoe vibe), the cat is a glass blob
//   bubble — solid sticker, modern emoji-ish
//   mono   — flat monochrome silhouette

const SKIN_DEFS = [
  { id: "pixel",  name: "Pixel",  blurb: "chunky retro 8-bit" },
  { id: "line",   name: "Line",   blurb: "minimal single stroke" },
  { id: "liquid", name: "Liquid", blurb: "glass blob, macOS Tahoe" },
  { id: "bubble", name: "Bubble", blurb: "soft sticker" },
  { id: "mono",   name: "Mono",   blurb: "flat monochrome" },
];

// ─── PIXEL SKIN (handmade pixel art, retro) ──────────────────────────────
function PixelSkin({ p, expression, size }) {
  // 16×16 grid drawn as rects, scaled up. 1 cell = size/16 px.
  const px = size / 16;
  const cell = (x, y, w = 1, h = 1, fill) => (
    <rect key={`${x}-${y}-${fill}`} x={x * px} y={y * px} width={w * px} height={h * px} fill={fill} shapeRendering="crispEdges" />
  );
  const eyeY = expression === "sleep" ? 7 : 6;
  const eyeOpen = expression !== "sleep" && expression !== "happy";
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} shapeRendering="crispEdges">
      {/* ears */}
      {cell(3, 2, 1, 2, p.body)}{cell(4, 1, 1, 2, p.body)}{cell(4, 3, 1, 1, p.accent)}
      {cell(11, 1, 1, 2, p.body)}{cell(12, 2, 1, 2, p.body)}{cell(11, 3, 1, 1, p.accent)}
      {/* head — fill 3..12 x 4..12 */}
      {cell(3, 4, 10, 8, p.body)}
      {/* shading */}
      {cell(3, 11, 10, 1, p.shadow)}
      {/* eyes */}
      {eyeOpen ? <>{cell(5, eyeY, 1, 2, p.eye)}{cell(10, eyeY, 1, 2, p.eye)}</>
               : <>{cell(5, eyeY+1, 2, 1, p.eye)}{cell(9, eyeY+1, 2, 1, p.eye)}</>}
      {/* nose */}
      {cell(7, 8, 2, 1, p.nose)}
      {/* mouth */}
      {expression === "happy" || expression === "celebrate"
        ? <>{cell(6, 9, 1, 1, p.nose)}{cell(7, 10, 2, 1, p.nose)}{cell(9, 9, 1, 1, p.nose)}</>
        : expression === "concern"
          ? <>{cell(6, 10, 1, 1, p.nose)}{cell(7, 9, 2, 1, p.nose)}{cell(9, 10, 1, 1, p.nose)}</>
          : <>{cell(7, 9, 2, 1, p.nose)}</>
      }
      {/* sparkle */}
      {expression === "celebrate" && <>{cell(13, 4, 1, 1, p.accent)}{cell(2, 5, 1, 1, p.accent)}</>}
      {/* sleep z */}
      {expression === "sleep" && (
        <text x={size * 0.78} y={size * 0.22} fontFamily="ui-monospace,monospace" fontSize={size * 0.13} fontWeight="700" fill={p.shadow}>z</text>
      )}
    </svg>
  );
}

// ─── LINE SKIN (single-stroke minimalist) ────────────────────────────────
function LineSkin({ p, expression, size }) {
  const stroke = p.eye;
  const sw = Math.max(1.2, size * 0.025);
  const eyeKind = expression;
  return (
    <svg width={size} height={size} viewBox="0 0 64 64" fill="none" stroke={stroke} strokeWidth={sw} strokeLinecap="round" strokeLinejoin="round">
      {/* head — rounded square outline */}
      <path d="M 16 22 Q 16 14 24 14 L 40 14 Q 48 14 48 22 L 48 40 Q 48 50 32 50 Q 16 50 16 40 Z" />
      {/* ears */}
      <path d="M 18 20 L 22 8 L 28 18" />
      <path d="M 46 20 L 42 8 L 36 18" />
      {/* eyes */}
      {eyeKind === "sleep" || eyeKind === "happy"
        ? <>
            <path d="M 24 28 Q 26 31 28 28" fill="none" />
            <path d="M 36 28 Q 38 31 40 28" fill="none" />
          </>
        : <>
            <circle cx="26" cy="29" r={sw * 1.3} fill={stroke} stroke="none" />
            <circle cx="38" cy="29" r={sw * 1.3} fill={stroke} stroke="none" />
          </>
      }
      {/* nose */}
      <path d="M 31 36 L 33 36 L 32 38 Z" fill={stroke} stroke="none" />
      {/* mouth */}
      {expression === "happy" || expression === "celebrate"
        ? <path d="M 28 40 Q 32 44 36 40" />
        : expression === "concern"
          ? <path d="M 28 42 Q 32 39 36 42" />
          : <path d="M 30 40 Q 32 41.5 34 40" />
      }
      {/* whiskers */}
      <path d="M 18 36 L 24 36 M 18 39 L 24 38 M 46 36 L 40 36 M 46 39 L 40 38" opacity="0.5" strokeWidth={sw * 0.6} />
      {/* sparkles */}
      {expression === "celebrate" && (
        <>
          <path d="M 8 16 L 10 18 M 9 16 L 9 18" />
          <path d="M 56 14 L 58 16 M 57 14 L 57 16" />
        </>
      )}
    </svg>
  );
}

// ─── LIQUID SKIN (glass blob, macOS Tahoe vibe) ──────────────────────────
function LiquidSkin({ p, expression, size }) {
  const id = `liquid-${p.body.replace('#','')}`;
  return (
    <svg width={size} height={size} viewBox="0 0 64 64">
      <defs>
        <radialGradient id={id} cx="35%" cy="30%" r="70%">
          <stop offset="0%" stopColor="#fff" stopOpacity="0.95" />
          <stop offset="40%" stopColor={p.body} stopOpacity="0.55" />
          <stop offset="100%" stopColor={p.shadow} stopOpacity="0.85" />
        </radialGradient>
        <filter id={`blur-${id}`}>
          <feGaussianBlur stdDeviation="0.4" />
        </filter>
      </defs>
      {/* soft halo */}
      <ellipse cx="32" cy="36" rx="22" ry="20" fill={p.accent} opacity="0.18" filter={`url(#blur-${id})`} />
      {/* ears (small glassy triangles) */}
      <path d="M 16 22 L 20 10 L 26 19 Z" fill={`url(#${id})`} stroke={p.shadow} strokeWidth="0.4" strokeOpacity="0.3" />
      <path d="M 48 22 L 44 10 L 38 19 Z" fill={`url(#${id})`} stroke={p.shadow} strokeWidth="0.4" strokeOpacity="0.3" />
      {/* head — glassy blob */}
      <ellipse cx="32" cy="34" rx="20" ry="18" fill={`url(#${id})`} stroke={p.shadow} strokeWidth="0.5" strokeOpacity="0.35" />
      {/* highlight (top-left specular) */}
      <ellipse cx="24" cy="24" rx="6" ry="3.5" fill="#fff" opacity="0.55" />
      <ellipse cx="42" cy="22" rx="3" ry="1.6" fill="#fff" opacity="0.4" />
      {/* eyes — dark glassy dots with reflection */}
      {expression === "sleep" || expression === "happy"
        ? <>
            <path d="M 24 31 Q 26 34 28 31" stroke={p.eye} strokeWidth="1.6" fill="none" strokeLinecap="round" />
            <path d="M 36 31 Q 38 34 40 31" stroke={p.eye} strokeWidth="1.6" fill="none" strokeLinecap="round" />
          </>
        : <>
            <ellipse cx="26" cy="32" rx="2.4" ry="3" fill={p.eye} />
            <ellipse cx="38" cy="32" rx="2.4" ry="3" fill={p.eye} />
            <circle cx="26.8" cy="31" r="0.9" fill="#fff" />
            <circle cx="38.8" cy="31" r="0.9" fill="#fff" />
          </>
      }
      {/* tiny nose */}
      <path d="M 31 38 L 33 38 L 32 39.5 Z" fill={p.nose} opacity="0.7" />
      {/* mouth */}
      {expression === "happy" || expression === "celebrate"
        ? <path d="M 28 41 Q 32 44 36 41" stroke={p.nose} strokeWidth="1.4" fill="none" strokeLinecap="round" />
        : expression === "concern"
          ? <path d="M 28 42 Q 32 40 36 42" stroke={p.nose} strokeWidth="1.4" fill="none" strokeLinecap="round" />
          : <path d="M 30 41 Q 32 42.5 34 41" stroke={p.nose} strokeWidth="1.3" fill="none" strokeLinecap="round" />
      }
    </svg>
  );
}

// ─── BUBBLE SKIN (sticker) ───────────────────────────────────────────────
function BubbleSkin({ p, expression, size }) {
  return (
    <svg width={size} height={size} viewBox="0 0 64 64">
      {/* drop shadow under */}
      <ellipse cx="32" cy="54" rx="14" ry="2.2" fill={p.shadow} opacity="0.35" />
      {/* ears */}
      <path d="M 14 22 Q 14 8 22 8 Q 26 14 26 22 Z" fill={p.body} stroke={p.shadow} strokeWidth="1.2" />
      <path d="M 50 22 Q 50 8 42 8 Q 38 14 38 22 Z" fill={p.body} stroke={p.shadow} strokeWidth="1.2" />
      <path d="M 18 18 Q 18 12 21 12 Q 23 14 23 19 Z" fill={p.accent} />
      <path d="M 46 18 Q 46 12 43 12 Q 41 14 41 19 Z" fill={p.accent} />
      {/* head */}
      <path d="M 12 34 Q 12 18 32 18 Q 52 18 52 34 Q 52 50 32 50 Q 12 50 12 34 Z"
            fill={p.body} stroke={p.shadow} strokeWidth="1.2" />
      {/* belly highlight */}
      <ellipse cx="32" cy="42" rx="14" ry="6" fill={p.inner} opacity="0.6" />
      {/* shine */}
      <ellipse cx="22" cy="26" rx="5" ry="2" fill="#fff" opacity="0.5" />
      {/* eyes */}
      {expression === "sleep" || expression === "happy"
        ? <>
            <path d="M 23 32 Q 26 36 29 32" stroke={p.eye} strokeWidth="2" fill="none" strokeLinecap="round" />
            <path d="M 35 32 Q 38 36 41 32" stroke={p.eye} strokeWidth="2" fill="none" strokeLinecap="round" />
          </>
        : <>
            <circle cx="26" cy="33" r="2.6" fill={p.eye} />
            <circle cx="38" cy="33" r="2.6" fill={p.eye} />
            <circle cx="27" cy="32" r="0.9" fill="#fff" />
            <circle cx="39" cy="32" r="0.9" fill="#fff" />
          </>
      }
      {/* cheeks */}
      {(expression === "happy" || expression === "celebrate" || expression === "neutral") && (
        <>
          <ellipse cx="20" cy="38" rx="2.6" ry="1.4" fill={p.accent} opacity="0.7" />
          <ellipse cx="44" cy="38" rx="2.6" ry="1.4" fill={p.accent} opacity="0.7" />
        </>
      )}
      {/* nose */}
      <path d="M 30 38 L 34 38 L 32 41 Z" fill={p.nose} />
      {/* mouth */}
      {expression === "happy" || expression === "celebrate"
        ? <path d="M 27 42 Q 32 47 37 42" stroke={p.nose} strokeWidth="1.6" fill="none" strokeLinecap="round" />
        : expression === "concern"
          ? <path d="M 27 44 Q 32 41 37 44" stroke={p.nose} strokeWidth="1.5" fill="none" strokeLinecap="round" />
          : <path d="M 30 42 Q 32 44 34 42" stroke={p.nose} strokeWidth="1.4" fill="none" strokeLinecap="round" />
      }
    </svg>
  );
}

// ─── MONO SKIN (flat silhouette) ─────────────────────────────────────────
function MonoSkin({ p, expression, size }) {
  // single accent color silhouette
  const c = p.accent;
  return (
    <svg width={size} height={size} viewBox="0 0 64 64">
      {/* ears */}
      <path d="M 16 22 L 20 10 L 26 20 Z" fill={c} />
      <path d="M 48 22 L 44 10 L 38 20 Z" fill={c} />
      {/* head */}
      <path d="M 14 32 Q 14 18 32 18 Q 50 18 50 32 Q 50 48 32 48 Q 14 48 14 32 Z" fill={c} />
      {/* face cut-outs (white) */}
      {expression === "sleep" || expression === "happy"
        ? <>
            <path d="M 23 30 Q 26 33 29 30" stroke="#fff" strokeWidth="1.8" fill="none" strokeLinecap="round" />
            <path d="M 35 30 Q 38 33 41 30" stroke="#fff" strokeWidth="1.8" fill="none" strokeLinecap="round" />
          </>
        : <>
            <ellipse cx="26" cy="31" rx="2" ry="2.6" fill="#fff" />
            <ellipse cx="38" cy="31" rx="2" ry="2.6" fill="#fff" />
          </>
      }
      <path d="M 30 36 L 34 36 L 32 38 Z" fill="#fff" />
      {expression === "happy" || expression === "celebrate"
        ? <path d="M 28 39 Q 32 43 36 39" stroke="#fff" strokeWidth="1.6" fill="none" strokeLinecap="round" />
        : expression === "concern"
          ? <path d="M 28 41 Q 32 38 36 41" stroke="#fff" strokeWidth="1.5" fill="none" strokeLinecap="round" />
          : <path d="M 30 39 Q 32 40.5 34 39" stroke="#fff" strokeWidth="1.4" fill="none" strokeLinecap="round" />
      }
    </svg>
  );
}

// Unified component — pass skin id, persona id, expression, scale.
function CatSkin({ skin = "pixel", persona = "mochi", expression = "neutral", scale = 4 }) {
  const p = CAT_PALETTES[persona] || CAT_PALETTES.mochi;
  const size = 16 * scale;
  const Comp = {
    pixel: PixelSkin, line: LineSkin, liquid: LiquidSkin,
    bubble: BubbleSkin, mono: MonoSkin,
  }[skin] || PixelSkin;
  return (
    <div style={{ position: "relative", width: size, height: size, lineHeight: 0 }}>
      <Comp p={p} expression={expression} size={size} />
    </div>
  );
}

Object.assign(window, { CatSkin, SKIN_DEFS });
