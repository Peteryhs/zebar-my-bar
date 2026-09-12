/*
 * Just enough iCalendar to fill a month view and an agenda.
 *
 * Deliberately not a full RFC 5545 implementation. It handles what a personal
 * calendar is made of: timed and all-day events, and the common repeats. What it
 * does not do is listed at the bottom, so the gaps are known rather than
 * discovered.
 */

// Unfolds the line continuations the format uses: a line beginning with a space or
// tab belongs to the line before it.
function unfold(text) {
  return text.replace(/\r\n[ \t]/g, '').replace(/\n[ \t]/g, '');
}

function unescapeText(value) {
  return value
    .replace(/\\n/gi, ' ')
    .replace(/\\,/g, ',')
    .replace(/\\;/g, ';')
    .replace(/\\\\/g, '\\');
}

/*
 * A property line is NAME;PARAM=VALUE:value. Times come in three shapes:
 * 20260912 (a date, so all day), 20260912T130000Z (UTC) and 20260912T130000
 * (whatever the TZID says, treated as local).
 */
function parseWhen(value, params) {
  const isDate = /^\d{8}$/.test(value) || params.VALUE === 'DATE';

  if (isDate) {
    const year = Number(value.slice(0, 4));
    const month = Number(value.slice(4, 6)) - 1;
    const day = Number(value.slice(6, 8));

    return { at: new Date(year, month, day), allDay: true };
  }

  const match = value.match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)$/);

  if (!match) return null;

  const [, y, mo, d, h, mi, s, zulu] = match;

  /*
   * A TZID other than this machine's is read as local time. Getting it right means
   * carrying a timezone database, and the case that matters — your own calendar on
   * your own laptop — is already local. An event created in another timezone will
   * show at the wrong hour.
   */
  const at = zulu
    ? new Date(Date.UTC(+y, +mo - 1, +d, +h, +mi, +s))
    : new Date(+y, +mo - 1, +d, +h, +mi, +s);

  return { at, allDay: false };
}

function parseLine(line) {
  const colon = line.indexOf(':');

  if (colon < 0) return null;

  const left = line.slice(0, colon);
  const value = line.slice(colon + 1);
  const bits = left.split(';');
  const params = {};

  for (const bit of bits.slice(1)) {
    const equals = bit.indexOf('=');
    if (equals > 0) params[bit.slice(0, equals).toUpperCase()] = bit.slice(equals + 1);
  }

  return { name: bits[0].toUpperCase(), params, value };
}

const DAY_MS = 24 * 60 * 60 * 1000;
const BY_DAY = { SU: 0, MO: 1, TU: 2, WE: 3, TH: 4, FR: 5, SA: 6 };

function parseRule(value) {
  const rule = {};

  for (const part of value.split(';')) {
    const equals = part.indexOf('=');
    if (equals > 0) rule[part.slice(0, equals).toUpperCase()] = part.slice(equals + 1);
  }

  return rule;
}

/*
 * Expands one event into the occurrences that fall inside [from, to].
 *
 * Only the repeats a person actually creates: every day, every N weeks on given
 * weekdays, monthly on the same date, yearly on the same date. COUNT, UNTIL,
 * INTERVAL and EXDATE are respected.
 */
function expand(event, from, to) {
  const out = [];
  const lengthMs = event.end ? event.end - event.start : (event.allDay ? DAY_MS : 0);

  const add = start => {
    if (start > to) return false;

    const end = new Date(start.getTime() + lengthMs);

    if (end >= from) {
      const key = start.toISOString();

      if (!event.excluded.has(key.slice(0, 10)) && !event.excluded.has(key)) {
        out.push({
          summary: event.summary,
          location: event.location,
          allDay: event.allDay,
          start,
          end,
        });
      }
    }

    return true;
  };

  if (!event.rule) {
    add(event.start);
    return out;
  }

  const rule = event.rule;
  const interval = Math.max(1, Number(rule.INTERVAL || 1));
  const until = rule.UNTIL ? parseWhen(rule.UNTIL, {})?.at : null;
  const count = rule.COUNT ? Number(rule.COUNT) : null;

  let made = 0;
  let cursor = new Date(event.start);
  // A repeat that started years ago should not be walked from the beginning.
  let guard = 0;

  const weekdays = rule.BYDAY
    ? rule.BYDAY.split(',')
        .map(day => BY_DAY[day.slice(-2)])
        .filter(day => day !== undefined)
    : null;

  while (guard++ < 2000) {
    if (until && cursor > until) break;
    if (count !== null && made >= count) break;
    if (cursor > to) break;

    if (rule.FREQ === 'WEEKLY' && weekdays && weekdays.length) {
      // Every named weekday of this week, then jump INTERVAL weeks.
      const sunday = new Date(cursor);
      sunday.setDate(sunday.getDate() - sunday.getDay());

      for (const day of weekdays) {
        const at = new Date(sunday);
        at.setDate(at.getDate() + day);
        at.setHours(
          event.start.getHours(),
          event.start.getMinutes(),
          event.start.getSeconds(),
          0,
        );

        if (at < event.start) continue;
        if (until && at > until) continue;
        if (count !== null && made >= count) break;

        add(at);
        made++;
      }

      cursor.setDate(cursor.getDate() + 7 * interval);
      continue;
    }

    add(cursor);
    made++;

    const next = new Date(cursor);

    switch (rule.FREQ) {
      case 'DAILY':
        next.setDate(next.getDate() + interval);
        break;
      case 'WEEKLY':
        next.setDate(next.getDate() + 7 * interval);
        break;
      case 'MONTHLY':
        next.setMonth(next.getMonth() + interval);
        break;
      case 'YEARLY':
        next.setFullYear(next.getFullYear() + interval);
        break;
      default:
        return out; // A repeat we do not understand becomes a single event.
    }

    cursor = next;
  }

  return out;
}

/*
 * Returns the occurrences between `from` and `to`, sorted.
 *
 * Not handled, on purpose: floating timezones other than this machine's, BYSETPOS
 * and BYMONTHDAY rules ("last Friday of the month"), and RECURRENCE-ID overrides,
 * where a single occurrence of a repeat was moved — those are skipped, so the
 * series shows at its original time.
 */
export function parseIcs(text, from, to) {
  if (!text || !text.trim()) return [];

  const lines = unfold(text).split(/\r?\n/);
  const events = [];

  let current = null;

  for (const line of lines) {
    if (line === 'BEGIN:VEVENT') {
      current = { excluded: new Set() };
      continue;
    }

    if (line === 'END:VEVENT') {
      if (current && current.start && !current.overridesOne) {
        events.push(current);
      }

      current = null;
      continue;
    }

    if (!current) continue;

    const parsed = parseLine(line);

    if (!parsed) continue;

    switch (parsed.name) {
      case 'SUMMARY':
        current.summary = unescapeText(parsed.value);
        break;
      case 'LOCATION':
        current.location = unescapeText(parsed.value);
        break;
      case 'DTSTART': {
        const when = parseWhen(parsed.value, parsed.params);
        if (when) {
          current.start = when.at;
          current.allDay = when.allDay;
        }
        break;
      }
      case 'DTEND': {
        const when = parseWhen(parsed.value, parsed.params);
        if (when) current.end = when.at;
        break;
      }
      case 'RRULE':
        current.rule = parseRule(parsed.value);
        break;
      case 'EXDATE':
        for (const one of parsed.value.split(',')) {
          const when = parseWhen(one, parsed.params);
          if (when) {
            current.excluded.add(when.at.toISOString());
            current.excluded.add(when.at.toISOString().slice(0, 10));
          }
        }
        break;
      case 'RECURRENCE-ID':
        current.overridesOne = true;
        break;
      case 'STATUS':
        if (parsed.value === 'CANCELLED') current.overridesOne = true;
        break;
    }
  }

  const occurrences = [];

  for (const event of events) {
    if (!event.summary) event.summary = '(no title)';

    for (const one of expand(event, from, to)) occurrences.push(one);
  }

  occurrences.sort((a, b) => a.start - b.start);

  return occurrences;
}
