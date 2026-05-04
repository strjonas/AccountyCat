// Faux macOS Tahoe desktop — gradient wallpaper, menu bar, dock, fake windows
// behind the AC surfaces. Sets the stage so AC's ambient widget feels real.

// PERSONA_THEME now defined in cats.jsx (single source of truth).

const WALLPAPERS = {
  warm: {
    bg: "radial-gradient(120% 100% at 80% 10%, #F2D8B8 0%, #E8B898 40%, #C68A6E 100%)",
    label: "Tahoe Dawn",
  },
  cool: {
    bg: "radial-gradient(120% 100% at 20% 0%, #6B8FB5 0%, #3F5F88 50%, #1F2A45 100%)",
    label: "Tahoe Tide",
  },
  forest: {
    bg: "radial-gradient(120% 100% at 50% 0%, #8FA582 0%, #5A6E55 60%, #2E3A30 100%)",
    label: "Tahoe Grove",
  },
};

function MenuBar({ activeApp, persona, time, activeProfile, onTogglePanel }) {
  const theme = PERSONA_THEME[persona];
  const prof = activeProfile ? getProfile(activeProfile.id) : null;
  return (
    <div className="ac-menubar">
      <div className="ac-menubar-left">
        <span className="ac-apple"></span>
        <span className="ac-app-name">{activeApp}</span>
        <span className="ac-mb-item">File</span>
        <span className="ac-mb-item">Edit</span>
        <span className="ac-mb-item">View</span>
        <span className="ac-mb-item">Window</span>
        <span className="ac-mb-item">Help</span>
      </div>
      <div className="ac-menubar-right">
        {/* Active profile chip — visible at the menu-bar level so user sees state without opening AC */}
        {prof && (
          <button className="ac-mb-profile" onClick={onTogglePanel} title={`focus: ${prof.name} · ${activeProfile.remainingMin}m left`}>
            <span className="ac-mb-profile-emoji" style={{ color: prof.color }}>{prof.emoji}</span>
            <span className="ac-mb-profile-name">{prof.name}</span>
            <span className="ac-mb-profile-time">{activeProfile.remainingMin}m</span>
          </button>
        )}
        <span className="ac-mb-icon">􀋊</span>
        <span className="ac-mb-icon">􀙇</span>
        <span className="ac-mb-icon">􀊨</span>
        <span className="ac-mb-icon">􀛨</span>
        {/* AC menu bar icon */}
        <button className="ac-mb-cat" onClick={onTogglePanel} title={`AccountyCat — ${theme.voice}`}>
          <span style={{ color: theme.accent, fontSize: 11, fontWeight: 700, letterSpacing: "0.04em" }}>
            ぅ
          </span>
        </button>
        <span className="ac-mb-time">{time}</span>
      </div>
    </div>
  );
}

function FakeAppWindow({ kind, focused, top, left, width, height, z }) {
  // Light blurred placeholder windows so the desktop has depth
  const content = {
    code: {
      title: "AC.swift — AccountyCat",
      body: (
        <div className="ac-fake-code">
          <div className="ac-fake-code-line"><span className="ac-c-kw">import</span> <span className="ac-c-id">SwiftUI</span></div>
          <div className="ac-fake-code-line"><span className="ac-c-kw">import</span> <span className="ac-c-id">AppKit</span></div>
          <div className="ac-fake-code-line"></div>
          <div className="ac-fake-code-line"><span className="ac-c-kw">@MainActor</span></div>
          <div className="ac-fake-code-line"><span className="ac-c-kw">final class</span> <span className="ac-c-type">CatWidget</span>: <span className="ac-c-type">NSWindow</span> {"{"}</div>
          <div className="ac-fake-code-line">  <span className="ac-c-kw">override</span> <span className="ac-c-kw">var</span> canBecomeKey: <span className="ac-c-type">Bool</span> {"{"} <span className="ac-c-kw">false</span> {"}"}</div>
          <div className="ac-fake-code-line">  <span className="ac-c-comment">// Always above other windows, never steals focus</span></div>
          <div className="ac-fake-code-line">  <span className="ac-c-kw">override</span> <span className="ac-c-kw">var</span> level: NSWindow.Level {"{"} .floating {"}"}</div>
          <div className="ac-fake-code-line">{"}"}</div>
          <div className="ac-fake-code-line"></div>
          <div className="ac-fake-code-line"><span className="ac-c-kw">struct</span> <span className="ac-c-type">VisionTask</span> {"{"}</div>
          <div className="ac-fake-code-line">  <span className="ac-c-kw">let</span> interval: <span className="ac-c-type">Duration</span> = .seconds(45)</div>
          <div className="ac-fake-code-line">  <span className="ac-c-kw">let</span> model: <span className="ac-c-type">Model</span> = .gemma4_4b_local</div>
          <div className="ac-fake-code-line">{"}"}</div>
        </div>
      ),
    },
    browser: {
      title: "reddit.com — r/programming",
      body: (
        <div className="ac-fake-browser">
          <div className="ac-fake-tab">r/programming</div>
          <div className="ac-fake-post">
            <div className="ac-fake-post-meta">u/halo_dev · 4h</div>
            <div className="ac-fake-post-title">Why I migrated from Electron to native Swift…</div>
            <div className="ac-fake-post-body">
              <div className="ac-line w90"></div>
              <div className="ac-line w70"></div>
              <div className="ac-line w85"></div>
              <div className="ac-line w50"></div>
            </div>
          </div>
          <div className="ac-fake-post">
            <div className="ac-fake-post-meta">u/quietfox · 2h</div>
            <div className="ac-fake-post-title">Show HN: A focus app that doesn't block</div>
          </div>
        </div>
      ),
    },
    notes: {
      title: "Roadmap.md",
      body: (
        <div className="ac-fake-notes">
          <div className="ac-fake-h1">Q2 — Focus & Polish</div>
          <div className="ac-line w80"></div>
          <div className="ac-line w60"></div>
          <div className="ac-fake-h2">Cat Widget</div>
          <div className="ac-line w90"></div>
          <div className="ac-line w70"></div>
          <div className="ac-line w85"></div>
          <div className="ac-fake-h2">Vision pipeline</div>
          <div className="ac-line w75"></div>
          <div className="ac-line w55"></div>
        </div>
      ),
    },
  }[kind];

  return (
    <div
      className={`ac-fake-window ${focused ? "ac-focused" : ""}`}
      style={{ top, left, width, height, zIndex: z }}
    >
      <div className="ac-fake-tb">
        <div className="ac-tl-dots">
          <span className="ac-tl ac-tl-r" />
          <span className="ac-tl ac-tl-y" />
          <span className="ac-tl ac-tl-g" />
        </div>
        <div className="ac-fake-title">{content.title}</div>
        <div style={{ width: 52 }} />
      </div>
      <div className="ac-fake-body">{content.body}</div>
    </div>
  );
}

function Dock() {
  // Simple dock — colored chips standing in for app icons
  const apps = [
    { c: "#3F8EFC", l: "F" },
    { c: "#FF6B6B", l: "S" },
    { c: "#FFB347", l: "X" },
    { c: "#7DD3FC", l: "M" },
    { c: "#A78BFA", l: "C" },
    { c: "#34D399", l: "T" },
    { c: "#F472B6", l: "N" },
  ];
  return (
    <div className="ac-dock">
      {apps.map((a, i) => (
        <div key={i} className="ac-dock-icon" style={{ background: a.c }}>
          <span>{a.l}</span>
        </div>
      ))}
    </div>
  );
}

Object.assign(window, { MenuBar, FakeAppWindow, Dock, WALLPAPERS });
