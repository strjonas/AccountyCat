// AC Settings v3
// Tabs: appearance · profiles · ai · notifications · persona · you
// No keys tab (shortcuts listed briefly in notifications). No quiet hours.
// AI: managed (soon) / local / byok-openrouter, econ/balanced/smartest tiers.
// Vision: intensity slider (calm→aggressive), info popover. No frame-interval setting.
// About: learned items with lock + cleanup, add, quit button.

function SettingsView({ persona, onPersonaChange, activeProfile, skin, onSkinChange }) {
  const [tab, setTab] = React.useState("appearance");
  const theme = PERSONA_THEME[persona];

  const tabs = [
    ["appearance", "look"],
    ["profiles",   "profiles"],
    ["ai",         "ai"],
    ["notifs",     "nudges"],
    ["persona",    "persona"],
    ["about",      "you"],
  ];

  return (
    <div className="ac-settings">
      <div className="ac-set-tabs">
        {tabs.map(([id, label]) => (
          <button
            key={id}
            className={`ac-set-tab ${tab === id ? "ac-set-tab-on" : ""}`}
            onClick={() => setTab(id)}
            style={tab === id ? { color: theme.accent, borderColor: theme.accent } : {}}
          >
            {label}
          </button>
        ))}
      </div>

      {tab === "appearance"  && <AppearanceTab skin={skin} onSkinChange={onSkinChange} persona={persona} onPersonaChange={onPersonaChange} />}
      {tab === "profiles"    && <ProfilesTab activeProfileId={activeProfile?.id} accent={theme.accent} />}
      {tab === "ai"          && <AITab accent={theme.accent} />}
      {tab === "notifs"      && <NotifsTab accent={theme.accent} />}
      {tab === "persona"     && <PersonaTab persona={persona} onPersonaChange={onPersonaChange} />}
      {tab === "about"       && <AboutTab persona={persona} accent={theme.accent} />}
    </div>
  );
}

// ─── APPEARANCE ────────────────────────────────────────────────────────────
function AppearanceTab({ skin, onSkinChange, persona, onPersonaChange }) {
  const theme = PERSONA_THEME[persona];
  const expressions = ["neutral", "happy", "celebrate", "concern", "drift", "sleep"];
  const [previewExpr, setPreviewExpr] = React.useState("neutral");

  return (
    <div className="ac-set-body">
      <div className="ac-set-section-lbl">cat style</div>
      <div className="ac-set-hint" style={{ marginTop: -4, marginBottom: 8 }}>
        style is separate from character — mix and match any combo.
      </div>
      <div className="ac-skin-grid">
        {SKIN_DEFS.map(s => {
          const on = s.id === skin;
          return (
            <button
              key={s.id}
              className={`ac-skin-card ${on ? "ac-skin-card-on" : ""}`}
              onClick={() => onSkinChange(s.id)}
              style={on ? { borderColor: theme.accent, background: theme.accent + "12" } : {}}
            >
              <div className="ac-skin-preview">
                <CatSkin skin={s.id} persona={persona} expression={previewExpr} scale={2.5} />
              </div>
              <div className="ac-skin-name" style={on ? { color: theme.accent } : {}}>{s.name}</div>
              <div className="ac-skin-blurb">{s.blurb}</div>
            </button>
          );
        })}
      </div>

      <div className="ac-set-section-lbl" style={{ marginTop: 8 }}>preview expression</div>
      <div className="ac-expr-row">
        {expressions.map(e => (
          <button
            key={e}
            className={`ac-expr-btn ${previewExpr === e ? "ac-expr-btn-on" : ""}`}
            onClick={() => setPreviewExpr(e)}
            style={previewExpr === e ? { borderColor: theme.accent, color: theme.accent } : {}}
          >
            {e}
          </button>
        ))}
      </div>

      <div className="ac-set-divider" />
      <div className="ac-set-section-lbl">accent</div>
      <div className="ac-set-hint" style={{ marginTop: -4 }}>inherited from your character choice below, or override:</div>
      <div className="ac-set-row" style={{ paddingTop: 8 }}>
        <span className="ac-set-label">follow character</span>
        <Pill on>on</Pill>
      </div>
    </div>
  );
}

// ─── PROFILES TAB ──────────────────────────────────────────────────────────
function ProfilesTab({ activeProfileId, accent }) {
  const allProfiles = [
    { id: "default", name: "everyday", emoji: "◎", color: "#9aa1a8",
      description: "AC watches and learns, but won't nudge unless you drift from something you've called out in chat.",
      safelist: [], blocklist: [], isDefault: true },
    ...PROFILE_DEFS,
  ];
  const [editingId, setEditingId] = React.useState(activeProfileId || "default");
  const prof = allProfiles.find(p => p.id === editingId) || allProfiles[0];

  return (
    <div className="ac-set-body">
      <div className="ac-set-section-lbl">your profiles</div>
      <div className="ac-set-hint" style={{ marginTop: -4, marginBottom: 8 }}>
        everyday is the default — no mode required. use named profiles for focused sessions.
      </div>
      <div className="ac-prof-chip-row">
        {allProfiles.map(p => {
          const on = p.id === editingId;
          const active = p.id === activeProfileId;
          return (
            <button
              key={p.id}
              className={`ac-prof-chip ${on ? "ac-prof-chip-on" : ""}`}
              onClick={() => setEditingId(p.id)}
              style={on ? { borderColor: p.color, background: p.color + "1a" } : {}}
            >
              <span className="ac-prof-chip-emoji" style={{ color: p.color }}>{p.emoji}</span>
              <span className="ac-prof-chip-name">{p.name}</span>
              {active && <span className="ac-prof-chip-active" style={{ background: p.color }}>active</span>}
            </button>
          );
        })}
        <button className="ac-prof-chip ac-prof-chip-add">+ new</button>
      </div>

      <div className="ac-set-divider" />

      <div className="ac-prof-editor-hd">
        <span className="ac-prof-editor-emoji" style={{ color: prof.color, background: prof.color + "22" }}>{prof.emoji}</span>
        <input className="ac-prof-name-input" defaultValue={prof.name} readOnly={prof.isDefault} />
        {!prof.isDefault && <button className="ac-prof-delete" title="delete profile">✕</button>}
      </div>

      {prof.isDefault ? (
        <div className="ac-set-hint" style={{ fontStyle: "italic", padding: "6px 0" }}>
          everyday mode — AC watches passively. it will only intervene if you've asked it to help with something specific in chat. no safelist, no timer.
        </div>
      ) : (
        <>
          <textarea className="ac-set-textarea" defaultValue={prof.description} rows="2" />

          <div className="ac-set-section-lbl ac-set-section-lbl-row">
            <span>safelist · ok during "{prof.name}"</span>
            <button className="ac-set-tiny-add" style={{ color: prof.color }}>+ add</button>
          </div>
          <div className="ac-safelist">
            {prof.safelist.map((item, i) => (
              <div key={i} className="ac-safe-row">
                <span className={`ac-safe-kind ac-safe-kind-${item.kind}`}>{item.kind}</span>
                <span className="ac-safe-val">{item.value}</span>
                <span className="ac-safe-note">{item.note}{item.limit ? ` · ${item.limit}` : ""}</span>
                <button className="ac-safe-x">×</button>
              </div>
            ))}
          </div>
          <div className="ac-set-section-lbl">always-distractions</div>
          <div className="ac-blocklist">
            {prof.blocklist.map((b, i) => (
              <span key={i} className="ac-block-tag">{b} <span className="ac-block-x">×</span></span>
            ))}
            <button className="ac-block-add">+ add</button>
          </div>
        </>
      )}
    </div>
  );
}

// ─── AI TAB ────────────────────────────────────────────────────────────────
// Mode: managed(soon) / local / openrouter.
// Tier: economy / balanced / smartest (no model-picker for normal user).
// Advanced mode reveals raw model selector.
function AITab({ accent }) {
  const [mode, setMode] = React.useState("local");
  const [tier, setTier] = React.useState("balanced");
  const [advanced, setAdvanced] = React.useState(false);
  const [showInfo, setShowInfo] = React.useState(false);

  const tiers = [
    { id: "economy",   label: "economy",  sub: "fast, cheap, gets it right 80% of the time" },
    { id: "balanced",  label: "balanced", sub: "recommended · sharp enough, reasonable cost" },
    { id: "smartest",  label: "smartest", sub: "catches edge cases, higher cost + slower" },
  ];

  return (
    <div className="ac-set-body">
      {/* vision section */}
      <div className="ac-set-section-lbl-row">
        <div className="ac-set-section-lbl" style={{ margin: 0 }}>vision</div>
        <button className="ac-info-btn" onClick={() => setShowInfo(!showInfo)} title="What is vision?">ⓘ</button>
      </div>
      {showInfo && (
        <div className="ac-info-box">
          AC takes periodic screenshots and analyzes them to understand what you're doing — without sending anything to the cloud (in local mode). This is how it knows whether you're on a safelisted site or drifting. Screenshots are analyzed and immediately discarded; only the structured result is kept.
        </div>
      )}

      <div className="ac-set-section-lbl">how actively should AC watch</div>
      <div className="ac-intensity-row">
        <span className="ac-intensity-lbl">calm</span>
        <div className="ac-intensity-track">
          <div className="ac-intensity-fill" style={{ width: "50%", background: accent }} />
          <input type="range" className="ac-intensity-slider" min="0" max="100" defaultValue="50" />
        </div>
        <span className="ac-intensity-lbl">sharp</span>
      </div>
      <div className="ac-set-hint">calm = fewer checks, lower cost/compute. sharp = catches drift faster, more prompts.</div>

      <div className="ac-set-divider" />
      <div className="ac-set-section-lbl">how AC thinks</div>
      <div className="ac-ai-mode-pills">
        {[
          { id: "managed",  label: "Managed",     sub: "coming soon", disabled: true },
          { id: "local",    label: "Local",        sub: "private · free" },
          { id: "online",   label: "OpenRouter",   sub: "bring your own key" },
        ].map(m => (
          <button
            key={m.id}
            disabled={m.disabled}
            className={`ac-mode-pill ${mode === m.id ? "ac-mode-pill-on" : ""} ${m.disabled ? "ac-mode-pill-disabled" : ""}`}
            onClick={() => !m.disabled && setMode(m.id)}
            style={mode === m.id ? { borderColor: accent, background: accent + "1a" } : {}}
          >
            <div className="ac-mode-pill-name" style={mode === m.id ? { color: accent } : {}}>{m.label}</div>
            <div className="ac-mode-pill-sub">{m.sub}</div>
          </button>
        ))}
      </div>

      <div className="ac-set-section-lbl" style={{ marginTop: 12 }}>intelligence tier</div>
      <div className="ac-tier-col">
        {tiers.map(t => (
          <button
            key={t.id}
            className={`ac-tier-row ${tier === t.id ? "ac-tier-row-on" : ""}`}
            onClick={() => setTier(t.id)}
            style={tier === t.id ? { borderColor: accent, background: accent + "10" } : {}}
          >
            <div className="ac-tier-radio" style={tier === t.id ? { borderColor: accent } : {}}>
              {tier === t.id && <span style={{ background: accent }} />}
            </div>
            <div>
              <div className="ac-tier-name">{t.label}</div>
              <div className="ac-tier-sub">{t.sub}</div>
            </div>
          </button>
        ))}
      </div>
      <div className="ac-set-hint">AC uses different models for vision vs text — no need to pick them yourself.</div>

      {mode === "online" && (
        <>
          <div className="ac-set-divider" />
          <div className="ac-set-section-lbl">openrouter key</div>
          <div className="ac-set-hint" style={{ marginBottom: 6 }}>
            paste your OpenRouter API key. AC will pick the right models per tier. <a href="#" className="ac-inline-link">→ openrouter.ai</a>
          </div>
          <div className="ac-key-row">
            <span className="ac-key-provider">openrouter</span>
            <span className="ac-key-mask">sk-or-•••••••• 9Xp2</span>
            <span className="ac-key-state ac-key-state-ok">ok</span>
            <button className="ac-key-edit">edit</button>
          </div>
          <div className="ac-spend-row">
            <span className="ac-set-label" style={{ fontSize: 12 }}>today's spend</span>
            <span className="ac-spend-num" style={{ fontSize: 13 }}>$0.031</span>
          </div>
        </>
      )}

      {mode === "local" && (
        <>
          <div className="ac-set-divider" />
          <div className="ac-set-section-lbl">installed models</div>
          <div className="ac-model-row ac-model-row-active">
            <div className="ac-model-icon">◈</div>
            <div className="ac-model-meta">
              <div className="ac-model-name">Gemma 4 · vision <span className="ac-model-tag">active</span></div>
              <div className="ac-model-sub">2.3 GB · 38ms · ~600 MB RAM</div>
            </div>
          </div>
          <div className="ac-model-row">
            <div className="ac-model-icon">◈</div>
            <div className="ac-model-meta">
              <div className="ac-model-name">Moondream 1.8B</div>
              <div className="ac-model-sub">0.9 GB · last used 2w ago</div>
            </div>
            <button className="ac-model-action ac-model-trash">delete</button>
          </div>
          <button className="ac-set-link">browse model library →</button>
        </>
      )}

      <div className="ac-set-divider" />
      <div className="ac-set-row" style={{ paddingBottom: 0 }}>
        <div>
          <div className="ac-set-label">advanced mode</div>
          <div className="ac-set-hint">choose specific models yourself</div>
        </div>
        <Pill on={advanced} onClick={() => setAdvanced(!advanced)}>{advanced ? "on" : "off"}</Pill>
      </div>
      {advanced && (
        <div className="ac-set-hint" style={{ fontStyle: "italic", padding: "6px 10px", background: "rgba(0,0,0,0.03)", borderRadius: 7 }}>
          advanced model selection coming in a future build.
        </div>
      )}
    </div>
  );
}

// ─── NUDGES / NOTIFICATIONS ─────────────────────────────────────────────────
function NotifsTab({ accent }) {
  return (
    <div className="ac-set-body">
      <div className="ac-set-section-lbl">when AC intervenes</div>
      <SetRow label="first nudge" hint="inline chat message + tooltip near cat">
        <Pill on>on</Pill>
      </SetRow>
      <SetRow label="escalation overlay" hint="visual-novel screen if nudge is ignored ~3 min">
        <Pill on>on</Pill>
      </SetRow>
      <SetRow label="auto-quiet on calls" hint="zoom, facetime, meet, teams">
        <Pill on>on</Pill>
      </SetRow>

      <div className="ac-set-divider" />
      <div className="ac-set-section-lbl">sounds</div>
      <SetRow label="nudge chime" hint="gentle once">
        <Pill on>on</Pill>
      </SetRow>
      <SetRow label="celebration" hint="streak milestones, completed profiles">
        <Pill on>on</Pill>
      </SetRow>

      <div className="ac-set-divider" />
      <div className="ac-set-section-lbl">keyboard shortcuts</div>
      <div className="ac-shortcut-row">
        <div><div className="ac-set-label">open / close panel</div></div>
        <div className="ac-shortcut-keys"><kbd className="ac-kbd">⌘</kbd><kbd className="ac-kbd">⌥</kbd><kbd className="ac-kbd">C</kbd></div>
      </div>
      <div className="ac-shortcut-row">
        <div><div className="ac-set-label">toggle vision</div></div>
        <div className="ac-shortcut-keys"><kbd className="ac-kbd">⌘</kbd><kbd className="ac-kbd">⌥</kbd><kbd className="ac-kbd">V</kbd></div>
      </div>
      <div className="ac-shortcut-row">
        <div><div className="ac-set-label">start / switch focus</div></div>
        <div className="ac-shortcut-keys"><kbd className="ac-kbd">⌘</kbd><kbd className="ac-kbd">⌥</kbd><kbd className="ac-kbd">F</kbd></div>
      </div>
      <div className="ac-shortcut-row">
        <div><div className="ac-set-label">extend +15 min</div></div>
        <div className="ac-shortcut-keys"><kbd className="ac-kbd">⌘</kbd><kbd className="ac-kbd">⌥</kbd><kbd className="ac-kbd">↑</kbd></div>
      </div>
      <div className="ac-shortcut-row">
        <div><div className="ac-set-label">pause / resume watching</div></div>
        <div className="ac-shortcut-keys"><kbd className="ac-kbd">⌘</kbd><kbd className="ac-kbd">⌥</kbd><kbd className="ac-kbd">P</kbd></div>
      </div>
      <button className="ac-set-link" style={{ marginTop: 4 }}>customize in shortcuts.app →</button>
    </div>
  );
}

// ─── PERSONA TAB ───────────────────────────────────────────────────────────
function PersonaTab({ persona, onPersonaChange }) {
  const blurbs = {
    mochi: "warm, rooting for you. uses 🥺 occasionally.",
    nova: "sharp co-pilot. concise, no hand-holding.",
    sage: "calm, reflective. mirrors back what you said.",
  };
  return (
    <div className="ac-set-body">
      <div className="ac-set-section-lbl">character (voice & personality)</div>
      <div className="ac-set-hint" style={{ marginTop: -4, marginBottom: 8 }}>
        character is separate from style — change look in the "look" tab.
      </div>
      <div className="ac-persona-grid">
        {["mochi", "nova", "sage"].map(p => {
          const t = PERSONA_THEME[p];
          return (
            <button key={p} className={`ac-persona-card ${p === persona ? "ac-persona-card-on" : ""}`}
              onClick={() => onPersonaChange(p)}
              style={p === persona ? { borderColor: t.accent, background: t.accent + "12" } : {}}>
              <div style={{ display: "flex", justifyContent: "center", marginBottom: 6 }}>
                <CatSkin skin="bubble" persona={p} expression="happy" scale={2.4} />
              </div>
              <div className="ac-persona-card-name" style={p === persona ? { color: t.accent } : {}}>{t.voice}</div>
              <div className="ac-persona-card-blurb">{blurbs[p]}</div>
            </button>
          );
        })}
      </div>
    </div>
  );
}

// ─── ABOUT / YOU ────────────────────────────────────────────────────────────
function AboutTab({ persona, accent }) {
  const theme = PERSONA_THEME[persona];
  const [learned, setLearned] = React.useState([
    { id: 1, text: '"linear is work, not distraction"', locked: true },
    { id: 2, text: '"you ship best mornings 9–11"', locked: false },
    { id: 3, text: '"twitter after lunch = trap"', locked: false },
    { id: 4, text: '"deep work blocks rarely under 45 min"', locked: false },
  ]);
  const removeItem = (id) => setLearned(l => l.filter(x => x.id !== id));
  const toggleLock = (id) => setLearned(l => l.map(x => x.id === id ? { ...x, locked: !x.locked } : x));

  return (
    <div className="ac-set-body">
      <div className="ac-set-section-lbl">your name</div>
      <div className="ac-set-input">alex</div>

      <div className="ac-set-section-lbl ac-set-section-lbl-row" style={{ marginTop: 8 }}>
        <span>what {theme.voice.toLowerCase()} knows about you</span>
        <div style={{ display: "flex", gap: 6 }}>
          <button className="ac-set-tiny-add" style={{ color: accent }}>+ add</button>
          <button className="ac-set-tiny-add" style={{ color: "rgba(29,27,22,0.5)" }}>clean up</button>
        </div>
      </div>
      <div className="ac-set-hint" style={{ marginTop: -6, marginBottom: 6 }}>
        locked items are never auto-removed during cleanup.
      </div>
      {learned.map(item => (
        <div key={item.id} className="ac-learned">
          <span style={{ flex: 1 }}>{item.text}</span>
          <button
            className="ac-learned-lock"
            onClick={() => toggleLock(item.id)}
            title={item.locked ? "unlock" : "lock (keep on cleanup)"}
            style={{ color: item.locked ? accent : "rgba(29,27,22,0.3)" }}
          >
            {item.locked ? "🔒" : "○"}
          </button>
          <button className="ac-learned-x" onClick={() => removeItem(item.id)} disabled={item.locked}>×</button>
        </div>
      ))}

      <div className="ac-set-divider" />
      <div className="ac-set-section-lbl">version</div>
      <div className="ac-set-hint">AccountyCat 1.0 (b14) · macOS 15.4 · vision: on-device</div>
      <button className="ac-set-link">privacy & data →</button>
      <button className="ac-set-link">export everything…</button>
      <button className="ac-set-link" style={{ color: "#cc4444" }}>reset all data…</button>
      <button className="ac-set-link" style={{ color: "rgba(29,27,22,0.6)", marginTop: 4 }}>quit AccountyCat</button>
    </div>
  );
}

function SetRow({ label, hint, children }) {
  return (
    <div className="ac-set-row">
      <div>
        <div className="ac-set-label">{label}</div>
        {hint && <div className="ac-set-hint">{hint}</div>}
      </div>
      <div>{children}</div>
    </div>
  );
}

function Pill({ on, children, onClick }) {
  return (
    <button
      onClick={onClick}
      style={{ appearance: "none", border: "none", background: "transparent", padding: 0, cursor: onClick ? "default" : undefined }}
    >
      <span className={`ac-set-pill ${on ? "ac-set-pill-on" : ""}`}>{children}</span>
    </button>
  );
}

Object.assign(window, { SettingsView });
