// AC Cat Widget v3 — skin-aware, paused state, profile ring.

function CatWidget({ persona, skin, expression, onClick, position = "bottom-right",
                     badge, hint, alarmed, activeProfile, paused }) {
  const theme = PERSONA_THEME[persona];
  const isSleep = expression === "sleep";
  const activeSkin = skin || "bubble";
  const activePaused = !!paused;

  const positionStyles = {
    "bottom-right": { right: 36, bottom: 56 },
    "bottom-left":  { left: 36,  bottom: 56 },
  }[position] || { right: 36, bottom: 56 };

  const prof = activeProfile ? getProfile(activeProfile.id) : null;
  let ringDash = 0, ringCirc = 0;
  if (prof) {
    const r = 36;
    ringCirc = 2 * Math.PI * r;
    const remainFrac = activeProfile.remainingMin / activeProfile.durationMin;
    ringDash = ringCirc * Math.max(0, Math.min(1, remainFrac));
  }

  const displayExpr = activePaused ? "sleep" : expression;

  return (
    <div
      className={`ac-widget ${alarmed && !activePaused ? "ac-widget-alarmed" : ""} ${activePaused ? "ac-widget-paused" : ""}`}
      style={positionStyles}
      onClick={onClick}
    >
      {/* Glow */}
      <div className="ac-widget-glow" style={{
        background: `radial-gradient(50% 50% at 50% 70%, ${prof ? prof.color + "33" : theme.accentSoft} 0%, transparent 70%)`,
      }} />

      {/* Profile timer ring */}
      {prof && (
        <svg className="ac-widget-ring" width="84" height="84" viewBox="0 0 84 84">
          <circle cx="42" cy="42" r="36" fill="none" stroke={prof.color + "22"} strokeWidth="2" />
          <circle cx="42" cy="42" r="36" fill="none"
            stroke={activePaused ? "rgba(0,0,0,0.15)" : prof.color} strokeWidth="2"
            strokeDasharray={`${ringDash} ${ringCirc}`}
            strokeLinecap="round"
            transform="rotate(-90 42 42)"
            style={{ filter: activePaused ? "none" : `drop-shadow(0 0 4px ${prof.color}88)` }}
          />
        </svg>
      )}

      {/* Cat — uses skin system */}
      <div className={`ac-widget-cat ${(isSleep || activePaused) ? "ac-cat-still" : "ac-cat-bob"}`}>
        <CatSkin skin={activeSkin} persona={persona} expression={displayExpr} scale={3} />
        {(isSleep || activePaused) && (
          <>
            <div className="ac-zfloat" style={{ animationDelay: "0s" }}>z</div>
            <div className="ac-zfloat" style={{ animationDelay: "1.4s", right: 0, top: -6 }}>z</div>
          </>
        )}
        {expression === "celebrate" && !activePaused && (
          <>
            <div className="ac-spark" style={{ left: -4, top: 4 }}>✦</div>
            <div className="ac-spark" style={{ right: -4, top: 12, animationDelay: "0.4s" }}>✦</div>
          </>
        )}
      </div>

      {/* Hover hint */}
      {hint && (
        <div className="ac-widget-hint">
          {activePaused
            ? "⏸ paused — click to open"
            : prof
              ? <><span style={{ color: prof.color }}>{prof.emoji}</span> {prof.name} · {activeProfile.remainingMin}m</>
              : hint}
        </div>
      )}

      {/* Paused badge overlay */}
      {activePaused && (
        <div className="ac-widget-pause-badge">⏸</div>
      )}

      {/* Notification dot */}
      {badge && !activePaused && (
        <div className="ac-widget-badge" style={{ background: theme.accent }} />
      )}
    </div>
  );
}

Object.assign(window, { CatWidget });
