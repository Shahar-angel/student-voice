/**
 * קול הסטודנטים: שולח המיילים האישי.
 * פרויקט Apps Script נפרד מהאפליקציה הראשית, שרץ בשם מי שפותח אותו ("Execute as: User accessing the web app").
 * כך מייל שאיש הנהלת קורס שולח דרך המערכת יוצא מה-Gmail שלו ונספר במכסה היומית שלו, ולא במכסה של מנהל המערכת.
 *
 * הוא לא מחזיק נתונים ולא מחליט למי לשלוח. הוא מבקש מהאפליקציה הראשית (MAIN_URL) את המיילים
 * שממתינים לבעל החשבון, שולח אותם ומדווח מה נשלח. אחרי חיבור חד-פעמי הוא בודק כל EVERY_MINUTES דקות,
 * גם כשהדפדפן סגור. אין כאן מפתחות ואין שירות חיצוני: רק שני פרויקטים של Google שמדברים ביניהם.
 */

const MAIN_URL = 'https://script.google.com/macros/s/AKfycbwNMlLD7f-VUwJ7ZcpXeCd6kjFZYGZUcAl59g17II3ANrEixq7mhImXVDpPDSBoSTHZnQ/exec';
const EVERY_MINUTES = 10; // each run takes ~10s; a consumer Google account gets 90 min/day of timer runtime
const USER = PropertiesService.getUserProperties(); // per person: the connection of one user is invisible to every other user

function norm_(e) { return String(e || '').trim().toLowerCase(); }
function isEmail_(e) { return /^[^\s@,;]+@[^\s@,;]+\.[^\s@,;]+$/.test(e); }
function esc_(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (ch) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[ch]; }); }
function me_() { return norm_(Session.getEffectiveUser().getEmail()); }

// =====================================================================
// The page: opened from the mail tab of the main app ("חיבור המייל שלי")
// =====================================================================

function doGet(e) {
  const me = norm_(Session.getActiveUser().getEmail());
  const ticket = String((e && e.parameter && e.parameter.ticket) || '').slice(0, 200);
  let state;
  try {
    if (!me || me !== me_()) throw new Error('לא הצלחנו לזהות את חשבון Google שלך. התחברו לחשבון Google ונסו שוב.');
    if (ticket) connect_(ticket);
    state = flush_();
  } catch (err) { state = { error: String(err && err.message || err) }; }
  return HtmlService.createHtmlOutput(page_(me, state))
    .setTitle('שליחה מהמייל שלי · קול הסטודנטים')
    .addMetaTag('viewport', 'width=device-width, initial-scale=1');
}

/** The ticket comes from the main app for the person signed in there; the main app checks it belongs to this Google account. */
function connect_(ticket) {
  const res = call_('connect', { ticket: ticket, email: me_() });
  if (!res.token) throw new Error('החיבור נכשל. חזרו למערכת ונסו שוב.');
  USER.setProperty('TOKEN', res.token);
  if (!ScriptApp.getProjectTriggers().some(function (t) { return t.getHandlerFunction() === 'tick'; })) {
    ScriptApp.newTrigger('tick').timeBased().everyMinutes(EVERY_MINUTES).create();
  }
}

/** Runs by itself every few minutes, as the person who connected. Never throws, so Google sends no failure emails. */
function tick() {
  try { flush_(); } catch (err) { console.error(err); }
}

/** Disconnect button on the page: stops sending from this account. */
function disconnect() {
  const token = USER.getProperty('TOKEN');
  if (token) { try { call_('disconnect', { token: token }); } catch (err) { console.error(err); } }
  forget_();
  return { ok: true };
}

/**
 * Check from the editor, also when this browser cannot open web apps (several Google accounts signed in).
 * Run testPersonalSender in the app's editor, put the ticket it logs in this project's Script properties
 * as TEST_TICKET, then run this. It connects the editor's account and sends whatever waits for it.
 */
function connectFromEditor() {
  const props = PropertiesService.getScriptProperties();
  const ticket = props.getProperty('TEST_TICKET');
  props.deleteProperty('TEST_TICKET'); // one use, like every ticket
  if (ticket) connect_(ticket);
  const state = flush_();
  console.log(JSON.stringify(state));
  return state;
}

function forget_() {
  USER.deleteProperty('TOKEN');
  ScriptApp.getProjectTriggers().forEach(function (t) { if (t.getHandlerFunction() === 'tick') ScriptApp.deleteTrigger(t); });
}

// =====================================================================
// Sending
// =====================================================================

/** Takes the emails waiting for this account, sends them from it, and reports back. */
function flush_() {
  const token = USER.getProperty('TOKEN');
  if (!token) return { connected: false };
  const lock = LockService.getUserLock(); // the page and the timer must not send the same batch twice
  if (!lock.tryLock(1000)) return { connected: true, busy: true, quota: MailApp.getRemainingDailyQuota() };
  try {
    const res = call_('pull', { token: token, quota: MailApp.getRemainingDailyQuota() });
    if (res.error === 'UNKNOWN') { forget_(); return { connected: false, revoked: true }; } // disconnected in the main app, or the system was reset
    if (res.error) throw new Error(res.error);
    if (norm_(res.email) !== me_()) { forget_(); throw new Error('החיבור שייך לחשבון אחר. חברו מחדש מהמערכת.'); }
    const results = [];
    let sent = 0, stopped = false;
    (res.messages || []).forEach(function (m) {
      if (stopped) return; // out of quota: the rest stay in the queue for tomorrow
      try {
        if (!isEmail_(m.to) || !m.subject || !m.html) throw new Error('bad message');
        MailApp.sendEmail({ to: m.to, subject: String(m.subject).slice(0, 250), htmlBody: String(m.html).slice(0, 60000), name: String(m.name || 'קול הסטודנטים').slice(0, 80) });
        results.push({ id: m.id, ok: true }); sent++;
      } catch (err) {
        if (/quota|limit|too many|מכסה/i.test(String(err && err.message))) { stopped = true; return; }
        results.push({ id: m.id, ok: false, error: String(err && err.message || err).slice(0, 200) });
      }
    });
    const quota = MailApp.getRemainingDailyQuota();
    if (results.length || res.messages && res.messages.length) call_('done', { token: token, results: results, quota: quota });
    return { connected: true, email: res.email, sent: sent, failed: results.length - sent, waiting: Number(res.waiting) || 0, quota: quota };
  } finally { lock.releaseLock(); }
}

function call_(op, data) {
  const r = UrlFetchApp.fetch(MAIN_URL, {
    method: 'post', contentType: 'application/json', muteHttpExceptions: true, followRedirects: true,
    payload: JSON.stringify(Object.assign({ op: op }, data)),
  });
  let out = null;
  try { out = JSON.parse(r.getContentText()); } catch (e) { out = null; }
  if (r.getResponseCode() !== 200 || !out) throw new Error('לא הצלחנו להגיע למערכת קול הסטודנטים. ננסה שוב בעוד כמה דקות.');
  if (op === 'connect' && out.error) throw new Error(out.error);
  return out;
}

// =====================================================================
// Page markup (all text escaped)
// =====================================================================

function page_(me, s) {
  let body;
  if (s.error) {
    body = '<p class="warn">' + esc_(s.error) + '</p><p>אפשר לסגור את החלון ולנסות שוב מלשונית "מיילים לסטודנטים" במערכת.</p>';
  } else if (!s.connected) {
    body = (s.revoked ? '<p class="warn">החיבור בוטל במערכת.</p>' : '<p>החשבון הזה לא מחובר לשליחה.</p>') +
      '<p>כדי לחבר, היכנסו למערכת קול הסטודנטים, ובלשונית "מיילים לסטודנטים" לחצו "חיבור המייל שלי".</p>';
  } else {
    body = '<p class="ok">✓ מחובר. מיילים שתשלחו דרך קול הסטודנטים יוצאים מהמייל <b dir="ltr">' + esc_(me) + '</b>, ונספרים במכסה היומית שלכם ב-Google.</p>' +
      (s.sent || s.failed ? '<p>נשלחו עכשיו ' + Number(s.sent) + ' מיילים' + (s.failed ? ', ' + Number(s.failed) + ' לא נשלחו' : '') + '.</p>' : '') +
      (s.waiting ? '<p>עוד ' + Number(s.waiting) + ' מיילים ממתינים, וייצאו בדקות הקרובות.</p>' : '') +
      '<p class="muted">נשארו לכם היום ' + Number(s.quota) + ' מיילים לשליחה. מיילים חדשים יוצאים אוטומטית תוך ' + EVERY_MINUTES + ' דקות, גם כשהחלון סגור.</p>' +
      '<p>אפשר לסגור את החלון.</p>' +
      '<p><button id="off" onclick="off()">ניתוק</button> <span id="st" class="muted"></span></p>';
  }
  return '<!doctype html><html dir="rtl" lang="he"><head><meta charset="utf-8"><style>' +
    'body{font-family:Arial,sans-serif;max-width:560px;margin:32px auto;padding:0 16px;line-height:1.6;color:#1d1d1f;background:#fff}' +
    'h1{font-size:20px}.ok{color:#11733b}.warn{color:#b3261e}.muted{color:#666;font-size:14px}' +
    'button{font:inherit;padding:6px 14px;border:1px solid #b3261e;color:#b3261e;background:#fff;border-radius:8px;cursor:pointer}' +
    '</style></head><body><h1>שליחה מהמייל שלי · קול הסטודנטים</h1>' + body +
    '<script>function off(){var b=document.getElementById("off");b.disabled=true;document.getElementById("st").textContent="מנתק…";' +
    'google.script.run.withSuccessHandler(function(){document.body.innerHTML="<h1>שליחה מהמייל שלי</h1><p>נותק. מיילים מהמערכת לא ייצאו יותר מהחשבון הזה.</p>";})' +
    '.withFailureHandler(function(){b.disabled=false;document.getElementById("st").textContent="הניתוק נכשל. נסו שוב.";}).disconnect();}</script>' +
    '</body></html>';
}
