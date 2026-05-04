// Profiles — AC's primary purpose. Each profile is a focus mode you start
// ("focus on writing for 1h"). Profiles carry their own safelist (apps/sites
// that AREN'T distractions while this profile is active), tone hints, and
// optional duration. Only ONE profile is active at a time.

const PROFILE_DEFS = [
  {
    id: "writing",
    name: "writing",
    emoji: "✎",
    color: "#7BA3D9",
    description: "long-form prose. drafting AC's launch post or blog drafts. quiet apps, no chat.",
    safelist: [
      { kind: "app", value: "iA Writer",   note: "main writing surface" },
      { kind: "app", value: "Notes",       note: "raw notes" },
      { kind: "app", value: "Safari",      note: "research only", limit: "20m" },
      { kind: "site", value: "thesaurus.com", note: "always fine" },
      { kind: "site", value: "wikipedia.org", note: "research, no rabbit holes" },
    ],
    blocklist: ["slack", "discord", "twitter", "instagram"],
  },
  {
    id: "coding",
    name: "deep coding",
    emoji: "⌘",
    color: "#A88BFF",
    description: "focused engineering on AccountyCat. heads-down, no socials, docs ok.",
    safelist: [
      { kind: "app", value: "Xcode",          note: "primary editor" },
      { kind: "app", value: "Terminal",       note: "always" },
      { kind: "site", value: "developer.apple.com", note: "always" },
      { kind: "site", value: "stackoverflow.com",   note: "always, but flag time-sinks" },
      { kind: "site", value: "github.com",          note: "code only, not feed" },
    ],
    blocklist: ["reddit", "twitter", "instagram", "youtube unless tutorial"],
  },
  {
    id: "social",
    name: "social mgmt",
    emoji: "◐",
    color: "#E89B7A",
    description: "scheduled hour for posting + replies. instagram + linkedin are work here, not distractions.",
    safelist: [
      { kind: "site", value: "instagram.com",  note: "this is the work" },
      { kind: "site", value: "linkedin.com",   note: "this is the work" },
      { kind: "site", value: "tweetdeck.com",  note: "scheduling" },
      { kind: "app",  value: "Notion",         note: "content calendar" },
    ],
    blocklist: ["youtube", "reddit", "tiktok"],
  },
  {
    id: "admin",
    name: "admin & email",
    emoji: "✉",
    color: "#A8B58E",
    description: "inbox zero, invoices, scheduling. fast and small.",
    safelist: [
      { kind: "app",  value: "Mail",      note: "primary" },
      { kind: "app",  value: "Calendar",  note: "primary" },
      { kind: "site", value: "stripe.com",  note: "billing" },
      { kind: "site", value: "linear.app",  note: "ticket sweep" },
    ],
    blocklist: ["reddit", "twitter", "youtube"],
  },
  {
    id: "design",
    name: "design",
    emoji: "◭",
    color: "#D9A8C7",
    description: "figma + dribbble + pinterest are research, not procrastination — for now.",
    safelist: [
      { kind: "app",  value: "Figma",      note: "primary" },
      { kind: "site", value: "dribbble.com",  note: "reference" },
      { kind: "site", value: "pinterest.com", note: "moodboards, time-cap 25m" },
      { kind: "site", value: "fonts.google.com", note: "always" },
    ],
    blocklist: ["reddit", "twitter", "youtube unless tutorial"],
  },
];

// Active profile state used by mockup. id null = no profile active (open mode).
const SAMPLE_ACTIVE_PROFILE = {
  id: "writing",
  startedAt: "10:00",
  durationMin: 60,
  remainingMin: 47,
  // For UI ring
  elapsedFrac: 13 / 60,
};

function getProfile(id) {
  return PROFILE_DEFS.find(p => p.id === id) || PROFILE_DEFS[0];
}

// ─── PROFILE BAR ───────────────────────────────────────────────────────────
// Sits at the very top of the panel (and on the cat widget hover hint).
// Either "no profile" CTA or "active profile + countdown ring + extend/end".

function ProfileBar({ activeProfile, onPick, onExtend, onEnd, persona }) {
  if (!activeProfile) {
    return (
      <div className="ac-profile-bar ac-profile-bar-empty">
        <div className="ac-pb-empty-l">
          <span className="ac-pb-empty-dot" />
          <span className="ac-pb-empty-txt">no focus active · open mode</span>
        </div>
        <button className="ac-pb-pick" onClick={onPick}>
          pick a focus →
        </button>
      </div>
    );
  }

  const prof = getProfile(activeProfile.id);
  const total = activeProfile.durationMin;
  const remaining = activeProfile.remainingMin;
  const elapsed = total - remaining;
  const frac = Math.max(0, Math.min(1, elapsed / total));

  // Ring stroke calculation — circumference 2πr, r=11
  const r = 11;
  const c = 2 * Math.PI * r;
  const dash = c * frac;

  const fmtTime = (m) => {
    const h = Math.floor(m / 60);
    const mm = m % 60;
    return h ? `${h}h ${mm}m` : `${mm}m`;
  };

  return (
    <div className="ac-profile-bar" style={{ background: prof.color + "14", borderBottomColor: prof.color + "33" }}>
      <div className="ac-pb-l" onClick={onPick} role="button">
        {/* Ring + emoji */}
        <div className="ac-pb-ring-wrap">
          <svg className="ac-pb-ring" width="28" height="28" viewBox="0 0 28 28">
            <circle cx="14" cy="14" r={r} fill="none" stroke={prof.color + "33"} strokeWidth="2.5" />
            <circle
              cx="14" cy="14" r={r} fill="none"
              stroke={prof.color} strokeWidth="2.5"
              strokeDasharray={`${dash} ${c}`}
              strokeLinecap="round"
              transform="rotate(-90 14 14)"
            />
          </svg>
          <span className="ac-pb-ring-emoji" style={{ color: prof.color }}>{prof.emoji}</span>
        </div>

        <div className="ac-pb-meta">
          <div className="ac-pb-name">
            <span style={{ color: prof.color }}>focus:</span> {prof.name}
            <span className="ac-pb-caret">▾</span>
          </div>
          <div className="ac-pb-time">
            <span className="ac-pb-time-num">{fmtTime(remaining)}</span>
            <span className="ac-pb-time-sep">·</span>
            <span>started {activeProfile.startedAt}</span>
          </div>
        </div>
      </div>

      <div className="ac-pb-r">
        <button className="ac-pb-action" onClick={onExtend} title="add 15 min">+15m</button>
        <button className="ac-pb-action ac-pb-action-end" onClick={onEnd} title="end profile">end</button>
      </div>
    </div>
  );
}

// ─── PROFILE PICKER POPOVER ────────────────────────────────────────────────
// Shows when ProfileBar's left side is clicked. Lists the user's profiles
// with a duration picker.

function ProfilePicker({ activeId, onStart, onClose, onManage }) {
  const [selected, setSelected] = React.useState(activeId || PROFILE_DEFS[0].id);
  const [duration, setDuration] = React.useState(60);
  const durations = [25, 45, 60, 90, 120];

  const prof = getProfile(selected);

  return (
    <div className="ac-pp">
      <div className="ac-pp-hd">
        <div className="ac-pp-hd-title">start a focus</div>
        <button className="ac-pp-x" onClick={onClose}>×</button>
      </div>

      <div className="ac-pp-list">
        {PROFILE_DEFS.map(p => {
          const on = p.id === selected;
          return (
            <button
              key={p.id}
              className={`ac-pp-row ${on ? "ac-pp-row-on" : ""}`}
              onClick={() => setSelected(p.id)}
              style={on ? { background: p.color + "1a", borderColor: p.color + "55" } : {}}
            >
              <span className="ac-pp-row-emoji" style={{ color: p.color, background: p.color + "22" }}>{p.emoji}</span>
              <span className="ac-pp-row-name">{p.name}</span>
              <span className="ac-pp-row-meta">{p.safelist.length} safelisted</span>
            </button>
          );
        })}
      </div>

      <div className="ac-pp-divider" />

      <div className="ac-pp-section-lbl">how long</div>
      <div className="ac-pp-durations">
        {durations.map(d => (
          <button
            key={d}
            className={`ac-pp-dur ${duration === d ? "ac-pp-dur-on" : ""}`}
            onClick={() => setDuration(d)}
            style={duration === d ? { background: prof.color, color: "white", borderColor: prof.color } : {}}
          >
            {d < 60 ? `${d}m` : d === 60 ? "1h" : `${d/60}h`}
          </button>
        ))}
        <button className="ac-pp-dur ac-pp-dur-custom">custom…</button>
      </div>

      <div className="ac-pp-actions">
        <button className="ac-pp-manage" onClick={onManage}>manage profiles</button>
        <button
          className="ac-pp-start"
          style={{ background: prof.color }}
          onClick={() => onStart(prof.id, duration)}
        >
          start {prof.name} →
        </button>
      </div>
    </div>
  );
}

Object.assign(window, { PROFILE_DEFS, SAMPLE_ACTIVE_PROFILE, getProfile, ProfileBar, ProfilePicker });
