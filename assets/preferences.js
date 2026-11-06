const KEY = 'my-bar.preferences.v1';
const defaults = {
  visualizer: false, compact: false, dinosaur: false,
  showAppName: true, showSystem: true, showStorage: true, showWeather: true,
};
const listeners = new Set();

function read() {
  try {
    const stored = JSON.parse(localStorage.getItem(KEY) || '{}');
    return Object.fromEntries(Object.entries(defaults).map(([key, value]) =>
      [key, typeof stored?.[key] === 'boolean' ? stored[key] : value]));
  } catch { return { ...defaults }; }
}

let preferences = read();
function publish() { listeners.forEach(listener => listener({ ...preferences })); }

export function setPreference(key, value) {
  if (!(key in defaults)) return;
  preferences = { ...read(), [key]: Boolean(value) };
  try { localStorage.setItem(KEY, JSON.stringify(preferences)); }
  catch (error) { console.warn('Could not save bar preferences:', error); }
  publish();
}

export function onPreferences(listener) {
  listeners.add(listener);
  listener({ ...preferences });
  return () => listeners.delete(listener);
}

window.addEventListener('storage', event => {
  if (event.key === KEY || event.key === null) { preferences = read(); publish(); }
});

// Bind real switches in the bar settings panel, without polling.
export function bindPreferenceControls(root = document) {
  const controls = [...root.querySelectorAll('[data-preference]')];
  controls.forEach(control => control.addEventListener('click', () => {
    setPreference(control.dataset.preference, control.getAttribute('aria-checked') !== 'true');
  }));
  return onPreferences(values => controls.forEach(control => {
    control.setAttribute('aria-checked', String(values[control.dataset.preference]));
  }));
}
