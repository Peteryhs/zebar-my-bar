/*
 * Weather, fetched here rather than through zebar's `weather` provider.
 *
 * The provider geolocates by calling ipinfo.io from the Rust side, and when that
 * request fails ("error sending request for URL ipinfo.io/json") the provider
 * output goes null, the bar tile disappears and the error is all you get. There
 * is no way to ask it to try again, and no way to tell it where you are.
 *
 * So: resolve the coordinates once, remember them, and never depend on that
 * lookup again. Everything below fails quietly. A caller that gets null shows
 * nothing at all, which is the point: a missing tile is better than an error
 * where a temperature should be.
 */

/*
 * Set this to pin the location by hand and skip every lookup below. Coordinates
 * to four decimal places is about ten metres, which is far finer than a forecast
 * grid; two is plenty.
 *
 *   const LOCATION = { latitude: 51.5072, longitude: -0.1276, place: 'London' };
 */
const LOCATION = null;

const COORDS_KEY = 'zebar-bar.coords';

/*
 * How the coordinates were found, worst to best. A better source replaces a
 * cached worse one: an IP lookup can be a different city, and the temperature it
 * returns is then someone else's.
 */
const SOURCE_RANK = { ip: 1, device: 2, manual: 3 };

/*
 * Five attempts, with the gap growing between them. Roughly four minutes of
 * trying in total, which covers a laptop waking up before the network is back
 * without hammering anything.
 */
const RETRY_DELAYS = [2000, 6000, 15000, 45000, 120000];

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function readCache() {
  try {
    const raw = localStorage.getItem(COORDS_KEY);
    if (!raw) return null;

    const parsed = JSON.parse(raw);

    return Number.isFinite(parsed.latitude) &&
      Number.isFinite(parsed.longitude)
      ? parsed
      : null;
  } catch {
    return null;
  }
}

function writeCache(coords) {
  try {
    localStorage.setItem(COORDS_KEY, JSON.stringify(coords));
  } catch {
    // Private mode or a storage error: we just look them up again next time.
  }
}

/*
 * Runs `attempt` until it returns something, waiting a little longer each time.
 * Returns null once the attempts are used up. Never throws, never reports.
 */
async function withRetry(attempt, label) {
  for (let index = 0; index <= RETRY_DELAYS.length; index++) {
    try {
      const result = await attempt();
      if (result) return result;
    } catch (err) {
      // Console only. Nothing about this reaches the bar.
      console.warn(`${label} attempt ${index + 1} failed:`, err);
    }

    if (index < RETRY_DELAYS.length) await sleep(RETRY_DELAYS[index]);
  }

  console.warn(`${label}: giving up for now`);
  return null;
}

async function fetchJson(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error('HTTP ' + response.status);
  return response.json();
}

/*
 * The device's own position, through Windows location services. This is the
 * accurate one: an IP lookup returns wherever the address is registered, which
 * for a phone hotspot, a VPN or a corporate network can be a different city and
 * a materially different temperature.
 *
 * Resolves to null on anything at all: no permission, no location service, no
 * fix. It is an upgrade over the IP guess, never a requirement.
 */
function deviceCoords() {
  if (!navigator.geolocation) return Promise.resolve(null);

  return new Promise(resolve => {
    let settled = false;

    const finish = value => {
      if (settled) return;
      settled = true;
      resolve(value);
    };

    navigator.geolocation.getCurrentPosition(
      position =>
        finish({
          latitude: position.coords.latitude,
          longitude: position.coords.longitude,
          place: '',
          source: 'device',
        }),
      error => {
        console.warn('device location unavailable:', error.message);
        finish(null);
      },
      { enableHighAccuracy: true, timeout: 8000, maximumAge: 600000 },
    );

    // Some webview builds neither resolve nor reject when the permission has
    // never been answered.
    setTimeout(() => finish(null), 9000);
  });
}

async function ipCoords() {
  return withRetry(async () => {
    const info = await fetchJson('https://ipinfo.io/json');
    const [latitude, longitude] = String(info.loc || '')
      .split(',')
      .map(Number);

    if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) return null;

    return {
      latitude,
      longitude,
      place: info.city || info.region || info.country || '',
      source: 'ip',
    };
  }, 'ip geolocation');
}

/*
 * Where we are, best source available, remembered in localStorage. The device
 * position is tried on every start because it is cheap when it works and it
 * upgrades a cached IP guess; the IP lookup only runs when there is nothing
 * better and nothing cached, which is what stops it being a single point of
 * failure for the whole tile.
 */
/*
 * Whatever we can answer with without touching the network, so the first reading
 * is not held up behind a location fix.
 */
export function knownCoords() {
  if (LOCATION) return { ...LOCATION, source: 'manual' };

  return readCache();
}

// The device is asked once per session. A refused permission or a machine with
// no location service would otherwise cost the timeout on every refresh.
let devicePromise = null;

export async function resolveCoords() {
  if (LOCATION) return { ...LOCATION, source: 'manual' };

  const cached = readCache();
  const cachedRank = cached ? SOURCE_RANK[cached.source] || 0 : 0;

  const device = await (devicePromise ??= deviceCoords());

  if (device && SOURCE_RANK.device >= cachedRank) {
    // Keep a place name we already know: the device gives coordinates only, and
    // a blank label reads worse than the city we had.
    if (!device.place && cached && cached.place) device.place = cached.place;

    writeCache(device);
    return device;
  }

  if (cached) return cached;

  const fromIp = await ipCoords();

  if (fromIp) writeCache(fromIp);

  return fromIp;
}

export async function fetchWeather(coords) {
  const url =
    'https://api.open-meteo.com/v1/forecast' +
    '?latitude=' +
    coords.latitude +
    '&longitude=' +
    coords.longitude +
    '&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,is_day,weather_code' +
    '&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max' +
    '&timezone=auto&forecast_days=7';

  return withRetry(() => fetchJson(url), 'forecast');
}

/*
 * Keeps `onUpdate` fed. Called with a reading when there is one, and with null
 * when there is not, so the caller can hide whatever it was showing. Returns a
 * stop function.
 */
export function startWeather({ onUpdate, refreshMs = 900000 }) {
  let stopped = false;
  let timer = null;
  let everShown = false;

  const keyOf = coords => coords.latitude + ',' + coords.longitude;

  // Returns the key it drew, or null if there was nothing to draw.
  async function show(coords) {
    const data = await fetchWeather(coords);

    if (stopped || !data) return null;

    everShown = true;

    onUpdate({
      place: coords.place || '',
      current: data.current || null,
      daily: data.daily || null,
    });

    return keyOf(coords);
  }

  async function tick() {
    if (stopped) return;

    // Draw from what we already know first. Asking Windows for a position can
    // take seconds the first time, and there is no reason for the tile to be
    // empty while that happens.
    const known = knownCoords();
    const drawn = known ? await show(known) : null;

    if (stopped) return;

    const best = await resolveCoords();

    if (stopped) return;

    // Only fetched twice in a round when the better position turns out to be
    // somewhere else, which is once, on the first start after a move.
    if (!best) {
      // A failed refresh leaves the last good reading on screen rather than
      // blanking the tile: the previous value is still roughly true.
      if (!everShown) onUpdate(null);
    } else if (keyOf(best) !== drawn) {
      await show(best);
    }

    // Whether or not this round worked, come back at the normal interval. A
    // machine that was offline for an hour recovers on its own.
    timer = setTimeout(tick, refreshMs);
  }

  tick();

  return () => {
    stopped = true;
    if (timer) clearTimeout(timer);
  };
}

/*
 * WMO weather code to a Nerdfont glyph. Monochrome only, so the icons take the
 * colour of the text around them.
 */
export function weatherIcon(code, isDay) {
  if (code === 0) {
    return isDay ? 'nf-weather-day_sunny' : 'nf-weather-night_clear';
  }
  if (code === 1) {
    return isDay ? 'nf-weather-day_cloudy' : 'nf-weather-night_alt_cloudy';
  }
  if (code === 2) {
    return isDay
      ? 'nf-weather-day_cloudy_high'
      : 'nf-weather-night_alt_cloudy_high';
  }
  if (code === 3) return 'nf-weather-cloudy';
  if (code === 45 || code === 48) return 'nf-weather-fog';
  if (code >= 51 && code <= 57) return 'nf-weather-sprinkle';
  if (code >= 61 && code <= 65) return 'nf-weather-rain';
  if (code === 66 || code === 67) return 'nf-weather-sleet';
  if (code >= 71 && code <= 77) return 'nf-weather-snow';
  if (code >= 80 && code <= 82) return 'nf-weather-showers';
  if (code === 85 || code === 86) return 'nf-weather-snow';
  if (code >= 95) return 'nf-weather-thunderstorm';
  return 'nf-weather-cloudy';
}
