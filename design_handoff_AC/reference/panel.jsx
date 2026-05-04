// Main Panel v3 — profile bar top, skin-aware cat, mic+send composer,
// clear settings back navigation, pause in footer, % focused stat.

const SAMPLE_CHAT = {
  monitoring: [
    { kind: "day", label: "Today" },
    { kind: "cat", t: "10:00", text: "writing focus started. 1 hour. i'll watch against your safelist — ia writer, notes, and safari for research are all fine." },
    { kind: "you", t: "10:00", text: "yep. drafting the launch post." },
    { kind: "cat", t: "10:01", text: "noted. quiet now." },
  ],
  drift: [
    { kind: "day", label: "Today" },
    { kind: "cat", t: "10:00", text: "writing focus, 1 hour. ia writer, notes, safari for research." },
    { kind: "you", t: "10:00", text: "go." },
    { kind: "cat", t: "10:42", text: "you're on r/programming for 11 min. not on writing's safelist. anything i should know?" },
    { kind: "nudge_card", reason: "r/programming · 11 min · outside writing safelist" },
  ],
  celebrating: [
    { kind: "day", label: "Yesterday" },
    { kind: "cat", t: "16:48", text: "well — 2h 14m of unbroken writing. longest block this week." },
    { kind: "win_card", title: "2h 14m", subtitle: "longest writing block this week", emoji: "✦" },
    { kind: "you", t: "16:50", text: "felt good. didn't even notice the time." },
    { kind: "cat", t: "16:51", text: "best kind." },
    { kind: "day", label: "Today" },
    { kind: "cat", t: "10:00", text: "writing again? want me to aim for a similar window?" },
  ],
  explaining: [
    { kind: "day", label: "Today" },
    { kind: "cat", t: "10:42", text: "you've been on r/programming ~11min. anything i should know?" },
    { kind: "you", t: "10:43", text: "this is research — looking at how other dev tools handle menubar windows" },
    { kind: "cat", t: "10:43", text: "got it. saving that. i'll trust you on this one." },
    { kind: "context_card", text: "\u201cr/programming \u2192 research for AC menu bar\u201d", until: "until 11:30" },
  ],
  noProfile: [
    { kind: "day", label: "Today" },
    { kind: "cat", t: "9:14", text: "morning. no focus active — i'm watching but won't nudge unless you want me to. start a profile when you're ready." },
    { kind: "you", t: "9:15", text: "just checking mail first." },
    { kind: "cat", t: "9:16", text: "sure. i'll be here." },
  ],
};

function StatStrip({ persona, scenario }) {
  const theme = PERSONA_THEME[persona];
  // Replace "longest block" with "% focused"
  const stats = scenario === "celebrating"
    ? { focus: "3h 47m", pct: "79%", streak: 12, trend: "+1 vs last wk" }
    : scenario === "drift"
      ? { focus: "1h 18m", pct: "54%", streak: 11, trend: "same as last wk" }
      : scenario === "explaining"
        ? { focus: "1h 22m", pct: "57%", streak: 11, trend: "same as last wk" }
        : scenario === "noProfile"
          ? { focus: "0m", pct: "—", streak: 11, trend: "+2 vs last wk" }
          : { focus: "2h 04m", pct: "68%", streak: 11, trend: "+2 vs last wk" };

  const isMilestone = stats.streak % 7 === 0 || stats.streak === 12;

  return (
    <div className="ac-stat-strip">
      <div className="ac-stat">
        <div className="ac-stat-num">{stats.focus}</div>
        <div className="ac-stat-lbl">focused today</div>
      </div>
      <div className="ac-stat-div" />
      <div className="ac-stat">
        <div className="ac-stat-num">{stats.pct}</div>
        <div className="ac-stat-lbl">% of day</div>
      </div>
      <div className="ac-stat-div" />
      <div className={`ac-stat ac-stat-streak ${isMilestone ? "ac-stat-streak-milestone" : ""}`}>
        <div className="ac-stat-streak-row">
          <span className="ac-flame" style={{ color: theme.accent }}>𖤍</span>
          <span className="ac-stat-num" style={{ color: theme.accent }}>{stats.streak}</span>
          <span className="ac-stat-streak-unit">days</span>
        </div>
        <div className="ac-stat-lbl ac-stat-trend">{stats.trend}</div>
        {isMilestone && (
          <div className="ac-stat-streak-glow" style={{ background: `radial-gradient(60% 60% at 50% 60%, ${theme.accent}33, transparent 70%)` }} />
        )}
      </div>
    </div>
  );
}

function ChatBubble({ msg, persona, skin }) {
  const theme = PERSONA_THEME[persona];
  if (msg.kind === "day") {
    return (
      <div className="ac-day-sep">
        <span className="ac-day-line" />
        <span className="ac-day-lbl">{msg.label}</span>
        <span className="ac-day-line" />
      </div>
    );
  }
  if (msg.kind === "win_card") {
    return (
      <div className="ac-win-card" style={{ borderColor: theme.accent + "55", background: theme.accent + "10" }}>
        <div className="ac-win-emoji" style={{ color: theme.accent }}>{msg.emoji}</div>
        <div>
          <div className="ac-win-num" style={{ color: theme.accent }}>{msg.title}</div>
          <div className="ac-win-sub">{msg.subtitle}</div>
        </div>
      </div>
    );
  }
  if (msg.kind === "nudge_card") {
    return (
      <div className="ac-nudge-card">
        <div className="ac-nudge-dot" />
        <div>
          <div className="ac-nudge-title">drift detected</div>
          <div className="ac-nudge-sub">{msg.reason}</div>
        </div>
        <div className="ac-nudge-actions">
          <button className="ac-chip">back to work</button>
          <button className="ac-chip ac-chip-ghost">it's research</button>
        </div>
      </div>
    );
  }
  if (msg.kind === "context_card") {
    return (
      <div className="ac-ctx-card">
        <span className="ac-ctx-icon">⏚</span>
        <div className="ac-ctx-text">{msg.text}</div>
        <span className="ac-ctx-until">{msg.until}</span>
      </div>
    );
  }

  const isYou = msg.kind === "you";
  return (
    <div className={`ac-msg ${isYou ? "ac-msg-you" : "ac-msg-cat"}`}>
      {!isYou && (
        <div className="ac-msg-avatar">
          <CatSkin skin={skin} persona={persona} expression="neutral" scale={1.5} />
        </div>
      )}
      <div className="ac-msg-stack">
        <div className="ac-msg-bubble" style={isYou ? { background: theme.accent + "22", borderColor: theme.accent + "44" } : {}}>
          {msg.text}
        </div>
        <div className="ac-msg-time">{msg.t}</div>
      </div>
    </div>
  );
}

function MainPanel({
  persona, skin, scenario, onClose, onPersonaChange, onSkinChange, view, onViewChange,
  activeProfile, onProfileExtend, onProfileEnd, pickerOpen, onPickerToggle,
  paused, onTogglePause,
}) {
  const theme = PERSONA_THEME[persona];
  const messages = SAMPLE_CHAT[scenario] || SAMPLE_CHAT.monitoring;
  const scrollRef = React.useRef(null);
  const [voiceMode, setVoiceMode] = React.useState(false);

  React.useEffect(() => {
    if (scrollRef.current) scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
  }, [scenario, view]);

  // Expression from scenario
  const catExpr = scenario === "celebrating" ? "happy" : scenario === "drift" ? "drift" : scenario === "sleeping" ? "sleep" : "neutral";

  return (
    <div className="ac-panel">

      {/* PROFILE BAR */}
      <ProfileBar
        activeProfile={activeProfile}
        persona={persona}
        onPick={onPickerToggle}
        onExtend={onProfileExtend}
        onEnd={onProfileEnd}
      />

      {/* Compact header */}
      <div className="ac-panel-hd ac-panel-hd-compact">
        <div className="ac-panel-hd-l">
          <div className="ac-mini-cat">
            <CatSkin skin={skin} persona={persona} expression={catExpr} scale={1.6} />
          </div>
          <div className="ac-mini-cat-meta">
            <div className="ac-mini-cat-name">{theme.voice.toLowerCase()}</div>
            <div className="ac-mini-cat-status">
              <span className="ac-pulse" style={{ background: paused ? "#aaa" : theme.accent }} />
              {paused ? "paused" : scenario === "celebrating" ? "celebrating" : scenario === "drift" ? "watching" : scenario === "sleeping" ? "sleeping" : "with you"}
            </div>
          </div>
        </div>
        <div className="ac-panel-hd-r">
          {view === "settings" ? (
            <button className="ac-icon-btn ac-icon-btn-back" onClick={() => onViewChange("chat")} title="Back to chat">
              ← back
            </button>
          ) : (
            <button className="ac-icon-btn" title="Settings" onClick={() => onViewChange("settings")}>
              <svg width="14" height="14" viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.6">
                <circle cx="10" cy="10" r="3" />
                <path d="M10 1v2M10 17v2M1 10h2M17 10h2M3.5 3.5l1.4 1.4M15.1 15.1l1.4 1.4M15.1 4.9l-1.4 1.4M4.9 15.1l-1.4 1.4" strokeLinecap="round" />
              </svg>
            </button>
          )}
          <button className="ac-icon-btn" onClick={onClose} title="Close">×</button>
        </div>
      </div>

      {view === "settings" ? (
        <SettingsView persona={persona} onPersonaChange={onPersonaChange} activeProfile={activeProfile} skin={skin} onSkinChange={onSkinChange} />
      ) : (
        <>
          <StatStrip persona={persona} scenario={scenario} />

          <div className="ac-chat" ref={scrollRef}>
            {messages.map((m, i) => (
              <ChatBubble key={i} msg={m} persona={persona} skin={skin} />
            ))}
          </div>

          {/* Composer with mic + send */}
          <div className="ac-composer">
            <button className="ac-composer-mic" title="Voice input">
              <svg width="13" height="13" viewBox="0 0 20 20" fill="currentColor">
                <rect x="7" y="1" width="6" height="11" rx="3" />
                <path d="M3 9a7 7 0 0014 0" stroke="currentColor" strokeWidth="1.6" fill="none" strokeLinecap="round" />
                <path d="M10 16v3" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
              </svg>
            </button>
            <input
              className="ac-composer-input"
              placeholder={`tell ${theme.voice.toLowerCase()} what you're working on…`}
            />
            <button className="ac-composer-send" style={{ background: theme.accent }} title="Send">↑</button>
          </div>

          {/* Footer — pause accessible here */}
          <div className="ac-panel-foot">
            <span className="ac-foot-dot" style={{ background: paused ? "#aaa" : "#34c759" }} />
            {paused ? "paused" : "watching"} · gemma 4b · 38s ago
            <button className="ac-foot-pause" onClick={onTogglePause} title={paused ? "Resume" : "Pause watching"}>
              {paused ? "▶ resume" : "⏸ pause"}
            </button>
          </div>
        </>
      )}
    </div>
  );
}

Object.assign(window, { MainPanel, StatStrip, ChatBubble });
