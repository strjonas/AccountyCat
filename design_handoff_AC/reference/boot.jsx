// Top-level App. Wires desktop, widget, panel, profile picker, nudge,
// overlay, settings + Tweaks panel.

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "persona": "mochi",
  "skin": "bubble",
  "scenario": "monitoring",
  "wallpaper": "warm",
  "panelOpen": true,
  "showNudge": false,
  "showOverlay": false,
  "showPicker": false,
  "widgetExpression": "auto",
  "profileActive": true,
  "paused": false
}/*EDITMODE-END*/;

const SCENARIOS = {
  monitoring: {
    label: "writing focus · monitoring",
    expression: "neutral",
    activeApp: "iA Writer",
    focused: "notes",
    badge: false,
    showNudge: false,
    showOverlay: false,
    hint: "with you",
    color: "#34c759",
  },
  drift: {
    label: "drift · safelist breach",
    expression: "drift",
    activeApp: "Safari",
    focused: "browser",
    badge: true,
    showNudge: true,
    showOverlay: false,
    hint: "noticed something",
    color: "#FFB347",
  },
  explaining: {
    label: "explained · trusting you",
    expression: "happy",
    activeApp: "Safari",
    focused: "browser",
    badge: false,
    showNudge: false,
    showOverlay: false,
    hint: "trusting you",
    color: "#34c759",
  },
  celebrating: {
    label: "win · streak milestone",
    expression: "celebrate",
    activeApp: "iA Writer",
    focused: "notes",
    badge: true,
    showNudge: false,
    showOverlay: false,
    hint: "proud of you",
    color: "#FFB347",
  },
  escalation: {
    label: "ignored · overlay",
    expression: "concern",
    activeApp: "Safari",
    focused: "browser",
    badge: true,
    showNudge: false,
    showOverlay: true,
    hint: "we should talk",
    color: "#FF6B6B",
  },
  sleeping: {
    label: "quiet hours · sleeping",
    expression: "sleep",
    activeApp: "Finder",
    focused: null,
    badge: false,
    showNudge: false,
    showOverlay: false,
    hint: "shhh",
    color: "#777",
  },
  noProfile: {
    label: "no profile active · open mode",
    expression: "neutral",
    activeApp: "Finder",
    focused: null,
    badge: false,
    showNudge: false,
    showOverlay: false,
    hint: "pick a focus",
    color: "#9aa1a8",
  },
};

function App() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const sc = SCENARIOS[t.scenario] || SCENARIOS.monitoring;
  const expression = t.widgetExpression === "auto" ? sc.expression : t.widgetExpression;
  const [panelView, setPanelView] = React.useState("chat");

  // Active profile — null when noProfile scenario or profileActive=false.
  const activeProfile = (t.scenario === "noProfile" || !t.profileActive)
    ? null
    : SAMPLE_ACTIVE_PROFILE;

  React.useEffect(() => {
    const fit = () => {
      const el = document.getElementById('ac-desktop');
      if (!el) return;
      const sx = window.innerWidth / 1280;
      const sy = window.innerHeight / 800;
      const s = Math.min(sx, sy, 1);
      const offX = (window.innerWidth  - 1280 * s) / 2;
      const offY = (window.innerHeight - 800  * s) / 2;
      if (s >= 1) {
        el.style.transform = '';
        el.style.left = offX + 'px';
        el.style.top  = offY + 'px';
      } else {
        el.style.left = '0';
        el.style.top  = '0';
        el.style.transform = `translate(${offX}px, ${offY}px) scale(${s})`;
      }
    };
    fit();
    window.addEventListener('resize', fit);
    return () => window.removeEventListener('resize', fit);
  }, []);

  const showNudge = sc.showNudge || t.showNudge;
  const showOverlay = sc.showOverlay || t.showOverlay;
  const skin = t.skin || "bubble";

  const wallpaper = WALLPAPERS[t.wallpaper] || WALLPAPERS.warm;
  const time = "10:42";

  const closeOverlay = () => setTweak({ scenario: "explaining", showOverlay: false });
  const snoozeOverlay = () => setTweak({ scenario: "monitoring", showOverlay: false });

  return (
    <>
      <div className="ac-stage">
        <div className="ac-desktop" id="ac-desktop">
          <div className="ac-wallpaper" style={{ background: wallpaper.bg }} />

          <MenuBar
            activeApp={sc.activeApp}
            persona={t.persona}
            time={time}
            activeProfile={activeProfile}
            onTogglePanel={() => setTweak('panelOpen', !t.panelOpen)}
          />

          <div className="ac-mode-hint">
            <span className="ac-mode-dot" style={{ background: sc.color }} />
            scenario: {sc.label}
          </div>

      <FakeAppWindow kind="code"    focused={sc.focused === "code"}    top={64}  left={36}  width={520} height={360} z={1} />
      <FakeAppWindow kind="notes"   focused={sc.focused === "notes"}   top={120} left={520} width={360} height={310} z={2} />
      <FakeAppWindow kind="browser" focused={sc.focused === "browser"} top={220} left={150} width={480} height={340} z={3} />

          <Dock />

          <CatWidget
            persona={t.persona}
            skin={skin}
            expression={expression}
            badge={sc.badge}
            hint={sc.hint}
            alarmed={t.scenario === "escalation"}
            activeProfile={activeProfile}
            paused={t.paused}
            onClick={() => setTweak('panelOpen', !t.panelOpen)}
          />

          {showNudge && (
            <div className="ac-nudge-anchor">
              <Nudge
                persona={t.persona}
                text={
                  t.persona === "nova"
                    ? "you said writing focus. r/programming for 11 min — outside safelist. course-correct?"
                    : t.persona === "sage"
                      ? "writing focus is on — r/programming isn't on the safelist. notice it. choose."
                      : "hey — r/programming for 11 min. that's not on writing's safelist 🥺"
                }
                onDismiss={() => setTweak('scenario', 'explaining')}
                onAcknowledge={() => setTweak('scenario', 'monitoring')}
              />
            </div>
          )}

          {t.panelOpen && (
            <div className="ac-panel-anchor">
              <MainPanel
                persona={t.persona}
                skin={skin}
                scenario={t.scenario}
                view={panelView}
                onViewChange={setPanelView}
                onClose={() => setTweak('panelOpen', false)}
                onPersonaChange={(p) => setTweak('persona', p)}
                onSkinChange={(s) => setTweak('skin', s)}
                activeProfile={activeProfile}
                onProfileExtend={() => {}}
                onProfileEnd={() => setTweak({ scenario: "noProfile", profileActive: false })}
                onPickerToggle={() => setTweak('showPicker', !t.showPicker)}
                pickerOpen={t.showPicker}
                paused={t.paused}
                onTogglePause={() => setTweak('paused', !t.paused)}
              />
              {t.showPicker && (
                <div className="ac-picker-anchor">
                  <ProfilePicker
                    activeId={activeProfile?.id}
                    onClose={() => setTweak('showPicker', false)}
                    onStart={(id, dur) => {
                      setTweak({ showPicker: false, profileActive: true, scenario: "monitoring" });
                    }}
                    onManage={() => {
                      setPanelView("settings");
                      setTweak('showPicker', false);
                    }}
                  />
                </div>
              )}
            </div>
          )}

          {showOverlay && (
            <Overlay
              persona={t.persona}
              activeProfile={activeProfile}
              onDismiss={closeOverlay}
              onSnooze={snoozeOverlay}
              onExplain={closeOverlay}
            />
          )}
        </div>
      </div>

      <TweaksPanel title="Tweaks">
        <TweakSection label="Persona" />
        <TweakRadio
          label="character"
          value={t.persona}
          options={[
            { value: "mochi", label: "Mochi" },
            { value: "nova",  label: "Nova"  },
            { value: "sage",  label: "Sage"  },
          ]}
          onChange={(v) => setTweak('persona', v)}
        />

        <TweakSection label="Cat skin" />
        <TweakSelect
          label="style"
          value={t.skin}
          options={[
            { value: "pixel",  label: "Pixel — retro 8-bit" },
            { value: "line",   label: "Line — minimal stroke" },
            { value: "liquid", label: "Liquid — glass blob" },
            { value: "bubble", label: "Bubble — soft sticker" },
            { value: "mono",   label: "Mono — flat silhouette" },
          ]}
          onChange={(v) => setTweak('skin', v)}
        />

        <TweakSection label="Scenario" />
        <TweakSelect
          label="state"
          value={t.scenario}
          options={[
            { value: "monitoring",  label: "writing · monitoring" },
            { value: "drift",       label: "safelist drift · nudge" },
            { value: "explaining",  label: "explained · trusting you" },
            { value: "celebrating", label: "streak milestone · celebrate" },
            { value: "escalation",  label: "ignored · overlay" },
            { value: "sleeping",    label: "quiet hours · sleeping" },
            { value: "noProfile",   label: "no profile · open mode" },
          ]}
          onChange={(v) => setTweak('scenario', v)}
        />

        <TweakSection label="Surfaces" />
        <TweakToggle label="main panel"     value={t.panelOpen}     onChange={(v) => setTweak('panelOpen', v)} />
        <TweakToggle label="profile picker" value={t.showPicker}    onChange={(v) => setTweak('showPicker', v)} />
        <TweakToggle label="nudge tooltip"  value={t.showNudge}     onChange={(v) => setTweak('showNudge', v)} />
        <TweakToggle label="overlay"        value={t.showOverlay}   onChange={(v) => setTweak('showOverlay', v)} />

        <TweakSection label="Cat expression (override)" />
        <TweakSelect
          label="expression"
          value={t.widgetExpression}
          options={[
            { value: "auto",      label: "auto (from scenario)" },
            { value: "neutral",   label: "neutral" },
            { value: "happy",     label: "happy" },
            { value: "sleep",     label: "sleeping" },
            { value: "alert",     label: "alert" },
            { value: "drift",     label: "drift" },
            { value: "celebrate", label: "celebrate" },
            { value: "concern",   label: "concerned" },
          ]}
          onChange={(v) => setTweak('widgetExpression', v)}
        />

        <TweakSection label="Extras" />
        <TweakToggle label="paused"        value={t.paused}        onChange={(v) => setTweak('paused', v)} />
        <TweakRadio
          label="theme"
          value={t.wallpaper}
          options={[
            { value: "warm",   label: "Dawn" },
            { value: "cool",   label: "Tide" },
            { value: "forest", label: "Grove" },
          ]}
          onChange={(v) => setTweak('wallpaper', v)}
        />
      </TweaksPanel>
    </>
  );
}

const root = ReactDOM.createRoot(document.getElementById("root"));
root.render(<App />);
