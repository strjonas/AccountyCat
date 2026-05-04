// Nudge — small tooltip near the widget. First-level intervention. Disappears
// on its own. Friendly, never alarming.

function Nudge({ persona, text, onDismiss, onAcknowledge }) {
  const theme = PERSONA_THEME[persona];
  return (
    <div className="ac-nudge" style={{ borderTopColor: theme.accent }}>
      <div className="ac-nudge-arrow" />
      <div className="ac-nudge-head">
        <PixelCat persona={persona} expression="drift" scale={1.5} />
        <span className="ac-nudge-name">{PERSONA_THEME[persona].voice.toLowerCase()}</span>
      </div>
      <div className="ac-nudge-text">{text}</div>
      <div className="ac-nudge-row">
        <button className="ac-nudge-btn" style={{ background: theme.accent }} onClick={onAcknowledge}>
          back to work
        </button>
        <button className="ac-nudge-btn ac-nudge-btn-ghost" onClick={onDismiss}>
          it's fine
        </button>
      </div>
    </div>
  );
}

// Overlay — second-level escalation. Appears when nudges are ignored.
// Visual-novel aesthetic: warm vignette, the cat large and expressive on the
// left, dialogue panel on the right, reason chips at the bottom.

function Overlay({ persona, activeProfile, onDismiss, onSnooze, onExplain }) {
  const theme = PERSONA_THEME[persona];
  const prof = activeProfile ? getProfile(activeProfile.id) : null;
  const [reason, setReason] = React.useState(null);
  const [text, setText] = React.useState("");

  const reasons = [
    "actually working — leave me",
    "research, related to my work",
    "5 minute break, on purpose",
    "you're right, going back",
  ];

  const accusation = prof
    ? `you started ${prof.name} focus — but you've been on r/programming for 22 minutes. that site isn't on the safelist. i nudged. you didn't answer.`
    : `you've been on r/programming for 22 minutes and clicked through three sub-threads. i nudged. you didn't answer.`;

  return (
    <div className="ac-overlay">
      {/* Soft vignette */}
      <div className="ac-overlay-bg" />

      <div className="ac-overlay-stage">
        {/* Persona portrait — big, dramatic */}
        <div className="ac-overlay-portrait">
          <div className="ac-overlay-portrait-shadow" style={{ background: theme.accentSoft }} />
          <div className="ac-overlay-cat-wrap">
            <PixelCat persona={persona} expression="concern" scale={9} />
          </div>
          <div className="ac-overlay-name" style={{ color: theme.accent }}>
            {PERSONA_THEME[persona].voice.toLowerCase()}
          </div>
        </div>

        {/* Visual-novel dialog box */}
        <div className="ac-overlay-dialog">
          <div className="ac-overlay-dialog-name" style={{ color: theme.accent }}>
            {PERSONA_THEME[persona].voice}
          </div>
          <div className="ac-overlay-dialog-text">
            <span className="ac-typewriter">
              {accusation}
            </span>
          </div>
          <div className="ac-overlay-dialog-text-2">
            tell me what's going on, or close this and i'll trust you.
          </div>

          <div className="ac-overlay-reasons">
            {reasons.map((r, i) => (
              <button
                key={i}
                className={`ac-reason-chip ${reason === i ? "ac-reason-chip-on" : ""}`}
                onClick={() => setReason(i)}
                style={reason === i ? { borderColor: theme.accent, background: theme.accent + "1f", color: theme.accent } : {}}
              >
                {r}
              </button>
            ))}
          </div>

          <div className="ac-overlay-text-row">
            <input
              className="ac-overlay-input"
              placeholder="…or tell me in your own words"
              value={text}
              onChange={(e) => setText(e.target.value)}
            />
          </div>

          <div className="ac-overlay-actions">
            <button className="ac-overlay-btn ac-overlay-btn-ghost" onClick={onSnooze}>
              snooze 5 min
            </button>
            <button
              className="ac-overlay-btn ac-overlay-btn-primary"
              style={{ background: theme.accent }}
              onClick={onExplain}
            >
              {reason !== null || text.length ? "got it — back to work" : "back to work"}
            </button>
          </div>
        </div>
      </div>

      {/* Tiny dismiss in corner — quiet, not advertised */}
      <button className="ac-overlay-x" onClick={onDismiss} title="dismiss">×</button>
    </div>
  );
}

Object.assign(window, { Nudge, Overlay });
