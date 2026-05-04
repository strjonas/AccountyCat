// Cats v2 — SVG-based, softer, more expressive. Each persona has its own
// silhouette/colorway; expression is a small set of swappable face features.
// Still feels handmade — flat fills, rounded ears, no gradients on the body.
//
// Sizes: pass `scale` (defaults 4 = 64×64). Internal viewBox is 64×64.

const CAT_PALETTES = {
  // Mochi — warm cream + peach
  mochi: {
    body:   "#F4D9B8",
    inner:  "#FCEDD8",
    shadow: "#D9B188",
    accent: "#E89B7A",
    nose:   "#C77A5A",
    eye:    "#2A1B12",
    voice:  "Mochi",
  },
  // Nova — lighter, slate-violet so she's actually visible
  nova: {
    body:   "#7A6FA0",
    inner:  "#A99CD0",
    shadow: "#574E78",
    accent: "#C7B6FF",
    nose:   "#3A3252",
    eye:    "#F4FF8B",
    voice:  "Nova",
  },
  // Sage — moss + cream
  sage: {
    body:   "#A8B58E",
    inner:  "#CFD8B6",
    shadow: "#7E8C68",
    accent: "#D9C48E",
    nose:   "#5A5238",
    eye:    "#2A2418",
    voice:  "Sage",
  },
};

// Each face renders eye+mouth shapes inside the cat head (centered around 32,32 of 64×64).
function CatFace({ expression, p }) {
  // shared helpers
  const Eye = ({ cx, kind }) => {
    if (kind === "closed") {
      // gentle curve
      return <path d={`M ${cx-3} 30 Q ${cx} 33 ${cx+3} 30`} stroke={p.eye} strokeWidth="1.6" fill="none" strokeLinecap="round" />;
    }
    if (kind === "sleep") {
      return <path d={`M ${cx-3} 31 Q ${cx} 33.5 ${cx+3} 31`} stroke={p.eye} strokeWidth="1.6" fill="none" strokeLinecap="round" />;
    }
    if (kind === "wide") {
      return (<>
        <ellipse cx={cx} cy={30} rx="2.6" ry="3.3" fill={p.eye} />
        <circle cx={cx + 0.7} cy={29} r="0.8" fill="#fff" />
      </>);
    }
    if (kind === "side") {
      return (<>
        <ellipse cx={cx + 1.2} cy={30} rx="1.8" ry="2.6" fill={p.eye} />
        <circle cx={cx + 1.7} cy={29.2} r="0.6" fill="#fff" />
      </>);
    }
    if (kind === "sparkle") {
      return (<>
        <path d={`M ${cx} 27 L ${cx+1.2} 30 L ${cx+4} 31 L ${cx+1.2} 32 L ${cx} 35 L ${cx-1.2} 32 L ${cx-4} 31 L ${cx-1.2} 30 Z`} fill={p.eye} />
      </>);
    }
    if (kind === "worried") {
      return (<>
        <ellipse cx={cx} cy={31} rx="2" ry="2.4" fill={p.eye} />
        <circle cx={cx + 0.5} cy={30.2} r="0.6" fill="#fff" />
      </>);
    }
    // default oval
    return (<>
      <ellipse cx={cx} cy={30.5} rx="2" ry="2.6" fill={p.eye} />
      <circle cx={cx + 0.6} cy={29.6} r="0.6" fill="#fff" />
    </>);
  };

  // Mouth: small w / smile / sleep / 'o' / frown
  const mouths = {
    neutral: <path d="M 30 38 Q 32 39.5 34 38" stroke={p.nose} strokeWidth="1.2" fill="none" strokeLinecap="round" />,
    happy:   <path d="M 28 38 Q 32 42 36 38" stroke={p.nose} strokeWidth="1.4" fill="none" strokeLinecap="round" />,
    sleep:   <path d="M 30 38.5 Q 32 39.5 34 38.5" stroke={p.nose} strokeWidth="1.2" fill="none" strokeLinecap="round" />,
    alert:   <ellipse cx="32" cy="39" rx="1.4" ry="1.6" fill={p.nose} />,
    drift:   <path d="M 29 38 L 35 38" stroke={p.nose} strokeWidth="1.2" fill="none" strokeLinecap="round" />,
    celebrate: <path d="M 27 37 Q 32 43 37 37" stroke={p.nose} strokeWidth="1.5" fill="none" strokeLinecap="round" />,
    concern: <path d="M 28 39.5 Q 32 37 36 39.5" stroke={p.nose} strokeWidth="1.3" fill="none" strokeLinecap="round" />,
  };

  // Brows for emotional emphasis
  const brows = expression === "concern" ? (
    <>
      <path d="M 23 25 L 27 26.5" stroke={p.eye} strokeWidth="1.2" strokeLinecap="round" />
      <path d="M 41 25 L 37 26.5" stroke={p.eye} strokeWidth="1.2" strokeLinecap="round" />
    </>
  ) : expression === "alert" ? (
    <>
      <path d="M 23 25.5 L 27 25" stroke={p.eye} strokeWidth="1.2" strokeLinecap="round" />
      <path d="M 41 25.5 L 37 25" stroke={p.eye} strokeWidth="1.2" strokeLinecap="round" />
    </>
  ) : null;

  // Nose triangle (small, between eyes)
  const nose = expression !== "sleep" ? <path d="M 31 35 L 33 35 L 32 36.5 Z" fill={p.nose} /> : null;

  // Pick eye kind per expression
  const eyeKind =
    expression === "happy" ? "closed" :
    expression === "sleep" ? "sleep" :
    expression === "alert" ? "wide" :
    expression === "drift" ? "side" :
    expression === "celebrate" ? "sparkle" :
    expression === "concern" ? "worried" :
    "default";

  return (
    <>
      <Eye cx={26} kind={eyeKind} />
      <Eye cx={38} kind={eyeKind} />
      {brows}
      {nose}
      {mouths[expression] || mouths.neutral}
      {/* Cheek blush — subtle */}
      {(expression === "happy" || expression === "celebrate") && (
        <>
          <ellipse cx="22" cy="36" rx="2.6" ry="1.4" fill={p.accent} opacity="0.55" />
          <ellipse cx="42" cy="36" rx="2.6" ry="1.4" fill={p.accent} opacity="0.55" />
        </>
      )}
    </>
  );
}

function PixelCat({ persona = "mochi", expression = "neutral", scale = 4, style }) {
  const p = CAT_PALETTES[persona] || CAT_PALETTES.mochi;
  const size = 16 * scale;

  return (
    <div style={{ position: "relative", width: size, height: size, ...style }}>
      <svg viewBox="0 0 64 64" width={size} height={size} shapeRendering="geometricPrecision">
        {/* Sleep z's float */}
        {expression === "sleep" && (
          <g fill={p.shadow} opacity="0.7">
            <text x="48" y="14" fontFamily="ui-monospace, 'SF Mono', monospace" fontSize="8" fontWeight="700">z</text>
            <text x="54" y="9" fontFamily="ui-monospace, 'SF Mono', monospace" fontSize="6" fontWeight="700">z</text>
          </g>
        )}

        {/* Celebration sparkles */}
        {expression === "celebrate" && (
          <g fill={p.accent}>
            <path d="M 8 14 L 9 17 L 12 18 L 9 19 L 8 22 L 7 19 L 4 18 L 7 17 Z" />
            <path d="M 56 12 L 57 14.5 L 59.5 15.5 L 57 16.5 L 56 19 L 55 16.5 L 52.5 15.5 L 55 14.5 Z" />
          </g>
        )}

        {/* Ears (outer + inner) */}
        <path d="M 14 20 L 18 8 L 24 18 Z" fill={p.body} />
        <path d="M 17 18 L 19 12 L 22 17 Z" fill={p.accent} opacity="0.85" />
        <path d="M 50 20 L 46 8 L 40 18 Z" fill={p.body} />
        <path d="M 47 18 L 45 12 L 42 17 Z" fill={p.accent} opacity="0.85" />

        {/* Head — rounded square */}
        <rect x="13" y="16" width="38" height="32" rx="14" ry="13" fill={p.body} />

        {/* Cheek/jaw shading */}
        <path d="M 13 32 Q 16 44 24 47 L 13 47 Z" fill={p.shadow} opacity="0.25" />
        <path d="M 51 32 Q 48 44 40 47 L 51 47 Z" fill={p.shadow} opacity="0.25" />

        {/* Face features */}
        <CatFace expression={expression} p={p} />

        {/* Tiny chest tuft (visual interest below chin) */}
        <ellipse cx="32" cy="50" rx="9" ry="3" fill={p.inner} opacity="0.7" />
      </svg>
    </div>
  );
}

const PERSONA_THEME = {
  mochi: { accent: "#E89B7A", accentSoft: "rgba(232,155,122,0.20)", voice: "Mochi" },
  nova:  { accent: "#A88BFF", accentSoft: "rgba(168,139,255,0.22)", voice: "Nova"  },
  sage:  { accent: "#A8B58E", accentSoft: "rgba(168,181,142,0.22)", voice: "Sage"  },
};

Object.assign(window, { PixelCat, CAT_PALETTES, PERSONA_THEME });
