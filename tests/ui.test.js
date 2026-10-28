/* End-to-end tests: the real Index.html in an iframe, wired to the real Code.gs through a google.script.run stand-in. */
(function () {
  'use strict';
  var C = MOCK.call;
  var ADMIN = 'owner@test.local', STAFF = 'staff@test.local', S1 = 'student1@test.local';

  // ---------- harness ----------
  var frame = null;
  window.makeGoogle = function (win, params) {
    function runner(ok, fail) {
      return new Proxy({}, { get: function (_, prop) {
        if (prop === 'withSuccessHandler') return function (h) { return runner(h, fail); };
        if (prop === 'withFailureHandler') return function (h) { return runner(ok, h); };
        return function () {
          var args = Array.prototype.slice.call(arguments);
          setTimeout(function () {
            var res;
            try { res = C.apply(null, [prop].concat(args)); } catch (e) { if (fail) fail(new win.Error(e.message)); return; }
            if (ok) ok(res);
          }, 5);
        };
      } });
    }
    return { script: { url: { getLocation: function (cb) { setTimeout(function () { cb({ parameter: params || {} }); }, 0); } }, run: runner(null, null) } };
  };

  function openApp(params, keepSession) {
    if (!keepSession) { try { localStorage.clear(); } catch (e) {} }
    if (frame) frame.remove();
    frame = document.createElement('iframe');
    frame.style.width = '420px'; frame.style.height = '800px';
    window.__params = params || {};
    window.__downloads = [];
    window.__opened = []; // windows the page opened (the personal sender page)
    var boot = '<script>window.google = parent.makeGoogle(window, parent.__params);' +
      'window.open = function () { var w = { location: { href: "" }, closed: false, close: function () { w.closed = true; } }; parent.__opened.push(w); return w; };' +
      'URL.createObjectURL = function (b) { parent.__downloads.push(b); return "blob:test"; };' +
      'HTMLAnchorElement.prototype.click = function () { parent.__downloads.push({ name: this.download }); };</script>';
    frame.srcdoc = window.INDEX_HTML.replace('<body>', '<body>' + boot);
    document.body.appendChild(frame);
    return waitFor(function () { return frame.contentDocument && frame.contentDocument.getElementById('app'); }, 'app to load');
  }
  function d() { return frame.contentDocument; }
  function w() { return frame.contentWindow; }
  function $(id) { return d().getElementById(id); }
  // Visible content only: body.textContent would also include the page's own <script> source.
  function text() { return ['header', '#tabsWrap', 'main'].map(function (s) { var n = d().querySelector(s); return n ? n.textContent : ''; }).join(' '); }
  function byText(label, tag) {
    var all = d().querySelectorAll(tag || 'button');
    for (var i = 0; i < all.length; i++) if (all[i].textContent.trim().indexOf(label) === 0 && !all[i].disabled) return all[i];
    return null;
  }
  function setVal(el, v) { el.value = v; el.dispatchEvent(new (w().Event)('input', { bubbles: true })); }
  async function click(label, tag) { var b = await waitFor(function () { return byText(label, tag); }, 'button "' + label + '"'); b.click(); return b; }
  async function waitText(t, what) { return waitFor(function () { return text().indexOf(t) >= 0; }, what || '"' + t + '"'); }

  /** Signs in through the UI. First-time users are asked for a name; answer with `name` (default: the part before @). */
  async function login(email, name) {
    var input = await waitFor(function () { return $('loginEmail'); }, 'login form');
    setVal(input, email);
    input.form.requestSubmit();
    var code = await waitFor(function () { return $('loginCode'); }, 'code form');
    setVal(code, MOCK.lastCode(email));
    code.form.requestSubmit();
    var landed = await waitFor(function () { return $('nameInput') || $('connectGate') || (!$('loginCode') && !$('loginEmail') && $('welcome') && 'page'); }, 'login to finish');
    if (landed !== 'page' && $('nameInput')) {
      setVal($('nameInput'), name || email.split('@')[0]);
      $('nameInput').form.requestSubmit();
      await waitFor(function () { return !$('nameInput') && ($('welcome') || $('connectGate')); }, 'name to be saved');
    }
    // staff are asked to connect their email as part of signing in; tests that do not need it skip it
    if ($('connectGate') && !login.keepGate) { await click('אחר כך'); await waitFor(function () { return !$('connectGate') && $('welcome'); }, 'past the email step'); }
  }
  function welcomeText() { var w = $('welcome'); return w ? w.textContent : ''; }
  async function sendChat(msg) {
    var input = await waitFor(function () { return $('input'); }, 'chat input');
    setVal(input, msg);
    var n = d().querySelectorAll('.msg').length;
    $('composer').requestSubmit();
    await waitFor(function () { return d().querySelectorAll('.msg.bot').length && !d().querySelector('.msg .spinner') && d().querySelectorAll('.msg').length >= n + 2; }, 'bot reply');
    await waitFor(function () { return $('send') && !$('send').dataset.busy; }, 'send button to free up');
  }
  function cards() { return d().querySelectorAll('#mineList .item'); }

  function setupWorld() {
    MOCK.reset(); C('setup'); MOCK.props.ANTHROPIC_API_KEY = 'sk-ant-test';
    C('requestCode', ADMIN, null);
    var admin = C('verifyCode', ADMIN, MOCK.lastCode(ADMIN)).token;
    var course = C('createCourse', admin, { name: 'מפתחי AI', org: 'האוניברסיטה העברית', start: '2026-09-03' });
    C('addStaff', admin, course.id, STAFF, false);
    return course;
  }
  function chatAI(o) { MOCK.claude = function () { return MOCK.claudeText(JSON.stringify(Object.assign({ reply: 'תודה, ספרו עוד', sameClaim: true, summary: 'סיכום הפנייה', category: 'tools' }, o))); }; }

  // =====================================================================
  test('E2E', 'מנהל: כניסה, יצירת קורס, שיתוף והוספת איש הנהלה', async function () {
    MOCK.reset(); C('setup');
    await openApp({});
    await login(ADMIN);
    await waitText('כל הקורסים');
    setVal($('nName'), 'קורס בדיקה'); setVal($('nOrg'), 'מוסד'); $('nStart').value = '2026-09-03';
    await click('יצירת קורס');
    await waitText('שיתוף עם סטודנטים');
    var links = Array.prototype.map.call(d().querySelectorAll('.linkbox input'), function (i) { return i.value; });
    assert.ok(/\?view=student$/.test(links[0]), 'permanent student link first: ' + links[0]);
    assert.ok(links.some(function (l) { return /\?view=staff$/.test(l); }), 'permanent staff link');
    assert.ok(links.some(function (l) { return l.indexOf('?course=') >= 0; }), 'direct course link still offered');
    setVal($('addStaff'), 'manager@test.local');
    await click('הוספה');
    await waitText('manager@test.local');
    assert.equal(MOCK.outbox[MOCK.outbox.length - 1].to, 'manager@test.local', 'invitation sent');
  });

  test('E2E', 'מנהל: מחיקת קורס מהממשק דורשת הקלדת השם', async function () {
    var course = setupWorld();
    await openApp({}); await login(ADMIN);
    await waitText('כל הקורסים');
    await click('מחיקת הקורס');
    var inp = await waitFor(function () { return $('del_' + course.id); }, 'confirm input');
    var go = byText('מחיקה לצמיתות') || d().querySelector('.btn.danger.solid');
    assert.ok(go.disabled, 'delete is disabled until the name is typed');
    setVal(inp, 'שם שגוי'); assert.ok(go.disabled);
    setVal(inp, 'מפתחי AI'); assert.ok(!go.disabled, 'enabled after typing the exact name');
    go.click();
    await waitText('נמחק. הגיבוי נשמר ב-Drive');
    assert.includes(text(), 'עוד אין קורסים');
  });

  test('E2E', 'סטודנט: שליחה, הבהרה באותה פנייה, נושא חדש, קובץ, עריכה ומחיקה', async function () {
    var course = setupWorld();
    chatAI({ summary: 'סלאק איטי' });
    await openApp({ course: course.id });
    await login(S1);
    await waitText('הפניות שלי');
    await sendChat('המענה בסלאק איטי');
    assert.includes(text(), 'תודה, ספרו עוד', 'Claude reply shown in chat');
    await waitFor(function () { return cards().length === 1; }, 'one request');
    assert.includes(cards()[0].textContent, 'סלאק איטי');
    await sendChat('בעיקר בערב');
    await sleep(100);
    assert.equal(cards().length, 1, 'clarification joins the same request');
    assert.includes(text(), 'ממשיכים את הפנייה');
    await click('פנייה חדשה בנושא אחר');
    var dt = new (w().DataTransfer)(); dt.items.add(new (w().File)(['PNG'], 'shot.png', { type: 'image/png' }));
    var fi = d().querySelector('input[type=file]'); fi.files = dt.files; fi.dispatchEvent(new (w().Event)('change'));
    await waitFor(function () { return d().querySelector('#pending .fchip'); }, 'attachment chip');
    chatAI({ summary: 'המזכירות לא עונה', category: 'admin' });
    await sendChat('המזכירות לא עונה');
    await waitFor(function () { return cards().length === 2; }, 'second request');
    assert.includes(d().getElementById('mineList').textContent, 'shot.png');
    // edit
    await click('עריכה');
    var ed = await waitFor(function () { return d().querySelector('#mineList .editor textarea'); }, 'editor');
    setVal(ed, 'טקסט מתוקן');
    await click('שמירה');
    await waitText('טקסט מתוקן'); await waitText('נערך');
    // delete (needs two clicks)
    await click('מחיקת הפנייה');
    await click('ללחוץ שוב כדי למחוק');
    await waitFor(function () { return cards().length === 1; }, 'request deleted');
  });

  test('E2E', 'איש הנהלה עונה, הסטודנט רואה סטטוס ומענה', async function () {
    var course = setupWorld();
    chatAI({ summary: 'אין הקלטות לשיעורים' });
    await openApp({ course: course.id }); await login(S1); await sendChat('אין הקלטות');
    await openApp({ course: course.id, view: 'staff' }); await login(STAFF);
    await waitText('לוח הנהלת הקורס');
    await click('פניות', 'button');
    await waitText('אין הקלטות לשיעורים');
    var ta = d().querySelector('.item .editor textarea');
    setVal(ta, 'ההקלטות יעלו עד יום חמישי');
    d().querySelector('.item .editor select').value = 'done';
    await click('עדכון הסטודנט');
    await waitText('הסטודנט יראה את העדכון');
    await openApp({ course: course.id }); await login(S1);
    await waitFor(function () { return cards().length === 1 && cards()[0].textContent.indexOf('ההקלטות יעלו') >= 0; }, 'reply on the student card');
    assert.includes(cards()[0].textContent, 'טופל');
  });

  test('E2E', 'ניתוח, מענה לנושא, עדכון לכל הסטודנטים והורדה לאקסל', async function () {
    var course = setupWorld();
    chatAI({});
    await openApp({ course: course.id }); await login(S1); await sendChat('=HYPERLINK("http://evil")');
    MOCK.claude = function () { return MOCK.claudeText(JSON.stringify({ summary: 'תמונה כללית', themes: [{ title: 'נושא בדיקה', category: 'tools', owner: 'tech', students: 1, items: [1], severity: 'high', quotes: ['ציטוט'], recommendation: 'המלצה' }], quickWins: ['צעד'], strengths: ['חוזקה'] })); };
    await openApp({ course: course.id, view: 'staff' }); await login(STAFF);
    await click('נתח והפק המלצות');
    await waitText('תמונה כללית'); await waitText('נושא בדיקה');
    await click('מענה לנושא');
    var ta = await waitFor(function () { return d().querySelector('.theme .editor textarea'); }, 'theme form');
    setVal(ta, 'פתחנו ערוץ תמיכה');
    await click('שמירה');
    await waitText('המענה נשמר ונשלח ל-1 פניות');
    await click('הורדה לאקסל');
    var blob = window.__downloads.filter(function (x) { return x && typeof x.text === 'function'; })[0];
    assert.ok(blob, 'a file was offered for download');
    var head = new Uint8Array(await blob.arrayBuffer()).slice(0, 3);
    assert.equal(Array.from(head).join(','), '239,187,191', 'UTF-8 BOM so Excel reads Hebrew');
    var csv = await blob.text();
    assert.includes(csv, 'תאריך'); assert.includes(csv, '"\'=HYPERLINK', 'formula neutralised in CSV');
    await openApp({ course: course.id }); await login(S1);
    await waitText('בעקבות המשוב שלכם'); await waitText('פתחנו ערוץ תמיכה');
  });

  test('E2E', 'איפוס הלוח מהממשק', async function () {
    var course = setupWorld();
    await openApp({ course: course.id }); await login(S1); await sendChat('משהו');
    await openApp({ course: course.id, view: 'staff' }); await login(STAFF);
    await click('עותקים והגדרות');
    await click('איפוס הלוח');
    await click('ללחוץ שוב');
    await waitText('ניתוח וסטטיסטיקה מאז האיפוס');
    await click('עותקים והגדרות');
    await waitText('לפני איפוס');
  });

  test('E2E', 'הכוונה לפני כניסה: כל קישור מסביר לאיזה אזור נכנסים ומציג את שם הקורס', async function () {
    var course = setupWorld();
    await openApp({ course: course.id });
    await waitFor(function () { return welcomeText().indexOf('מפתחי AI') >= 0; }, 'course name on the sign-in screen');
    assert.includes(welcomeText(), 'אזור הסטודנטים'); assert.includes(welcomeText(), 'ברוכים הבאים');
    await openApp({ course: course.id, view: 'staff' });
    await waitFor(function () { return welcomeText().indexOf('מפתחי AI') >= 0; });
    assert.includes(welcomeText(), 'אזור הנהלת הקורס'); assert.includes(welcomeText(), 'מיועד לאנשי ההנהלה');
    await openApp({});
    await waitFor(function () { return welcomeText(); });
    assert.includes(welcomeText(), 'אזור המנהל');
    await openApp({ course: 'nosuchcourse' });
    await waitFor(function () { return welcomeText().indexOf('תגיעו לקורס שלכם') >= 0; }, 'deleted-course link continues normally');
    assert.notIncludes(welcomeText(), 'כבר לא קיים', 'no warning about the old link');
    assert.ok($('loginEmail'), 'and sign-in still offered');
    await openApp({ view: 'student' });
    await waitFor(function () { return welcomeText().indexOf('תגיעו לקורס שלכם') >= 0; }, 'permanent student link');
    assert.includes(welcomeText(), 'אזור הסטודנטים');
    await openApp({ view: 'staff' });
    await waitFor(function () { return welcomeText().indexOf('ללוח של הקורס שלכם') >= 0; }, 'permanent staff link');
    assert.includes(welcomeText(), 'אזור הנהלת הקורס');
  });

  test('E2E', 'כניסה ראשונה שואלת שם, ברכה אישית, והשם נשמר לכניסה הבאה גם ממכשיר אחר', async function () {
    var course = setupWorld();
    await openApp({ course: course.id });
    await login(S1, 'נועה');
    assert.includes(welcomeText(), 'נועה!'); assert.includes(welcomeText(), 'אזור הסטודנטים');
    assert.includes(welcomeText(), 'סטודנט/ית בקורס מפתחי AI');
    assert.includes($('whoami').textContent, 'נועה'); assert.includes($('whoami').textContent, 'סטודנט/ית');
    await sendChat('פנייה ראשונה');
    // "another device": nothing in local storage, sign in again with the same email
    await openApp({ course: course.id });
    await login(S1);
    assert.equal($('nameInput'), null, 'no name question the second time');
    assert.includes(welcomeText(), 'נועה!');
    await waitFor(function () { return cards().length === 1; }, 'earlier request still there');
    // change the name from "my profile" in the header
    $('nameBtn').click();
    setVal(await waitFor(function () { return $('profName'); }, 'profile name field'), 'נועה כהן');
    $('profName').form.requestSubmit();
    await waitText('השם נשמר');
    assert.includes($('whoami').textContent, 'נועה כהן');
    await click('← חזרה');
    await waitFor(function () { return welcomeText().indexOf('נועה כהן!') >= 0; }, 'new name in the greeting');
  });

  test('E2E', 'כל תפקיד מקבל ברכה ושיוך: הנהלת קורס, מנהל, וסטודנט שנכנס מהכתובת הראשית', async function () {
    var course = setupWorld();
    await openApp({ course: course.id, view: 'staff' }); await login(STAFF, 'יוסי');
    await waitFor(function () { return welcomeText().indexOf('יוסי!') >= 0; });
    assert.includes(welcomeText(), 'אזור הנהלת הקורס'); assert.includes(welcomeText(), 'הנהלת הקורס מפתחי AI');
    assert.includes($('whoami').textContent, 'הנהלת הקורס');
    await openApp({}); await login(ADMIN, 'שחר');
    await waitFor(function () { return welcomeText().indexOf('שחר!') >= 0; });
    assert.includes(welcomeText(), 'אזור המנהל'); assert.includes($('whoami').textContent, 'מנהל/ת מערכת');
    await openApp({ course: course.id }); await login(S1, 'דנה'); await sendChat('שלום');
    await openApp({}, true); // the main address with one course: straight into it
    await waitFor(function () { return welcomeText().indexOf('דנה!') >= 0 && welcomeText().indexOf('אזור הסטודנטים') >= 0; }, 'student lands in their course');
    assert.includes($('whoami').textContent, 'סטודנט/ית');
  });

  test('E2E', 'בקשת הרשאה להנהלה: מי שלא אושר מבקש, המנהל מאשר, ורק אז הלוח נפתח', async function () {
    var course = setupWorld();
    var NEW = 'coordinator@test.local';
    await openApp({ course: course.id, view: 'staff' }); await login(NEW, 'מיכל');
    await waitFor(function () { return welcomeText().indexOf('רק למי שמנהל המערכת אישר') >= 0; }, 'approval gate');
    assert.equal(byText('נתח והפק המלצות'), null, 'no board before approval');
    setVal($('reqNote'), 'אני רכזת הקורס');
    await click('בקשת הרשאה להנהלת הקורס');
    await waitFor(function () { return $('reqState') && $('reqState').textContent === 'ממתין לאישור המנהל'; }, 'pending state');
    assert.ok(MOCK.outbox.some(function (m) { return m.to === ADMIN && m.subject.indexOf('בקשת הרשאה') === 0; }), 'admin notified by email');
    assert.ok(MOCK.outbox.some(function (m) { return m.to === NEW && m.htmlBody.indexOf('ממתינה לאישור') >= 0; }), 'requester gets a confirmation email');
    await openApp({ course: course.id, view: 'staff' }, true);
    await waitFor(function () { return $('reqState') && $('reqState').textContent === 'ממתין לאישור המנהל'; }, 'still pending after reload');
    await openApp({}); await login(ADMIN);
    await waitText('בקשות הרשאה'); await waitText('אני רכזת הקורס');
    await click('אישור');
    await waitText('אושר/ה כהנהלת הקורס');
    assert.equal(MOCK.outbox[MOCK.outbox.length - 1].to, NEW, 'requester notified');
    await openApp({ course: course.id, view: 'staff' }); await login(NEW);
    await waitFor(function () { return welcomeText().indexOf('הגעת ללוח הנהלת הקורס') >= 0; }, 'board after approval');
  });

  test('E2E', 'מנהל: לשונית "משתמשים והרשאות" בלוח הקורס – אישור, הסרת גישה, סטודנטים והיסטוריה', async function () {
    var course = setupWorld();
    var NEW = 'coordinator@test.local';
    await openApp({ course: course.id }); await login(S1, 'נועה');          // a student enters
    await openApp({ course: course.id, view: 'staff' }); await login(NEW, 'מיכל');
    await click('בקשת הרשאה להנהלת הקורס');
    await waitFor(function () { return $('reqState') && $('reqState').textContent === 'ממתין לאישור המנהל'; });
    await openApp({}); await login(ADMIN, 'שחר');
    await waitText('בקשות הרשאה ממתינות לאישור');
    await click('משתמשים והרשאות');
    await waitText('בקשות שממתינות לאישור (1)');
    assert.includes(text(), 'נועה'); assert.includes(text(), S1);           // students list
    await click('אישור');
    await waitText('אושר/ה. נשלחה הודעה');
    await waitText('אושר/ה מבקשה');
    assert.includes(text(), 'בקשות שממתינות לאישור (0)');
    var rowOf = function (email) { return Array.prototype.filter.call(d().querySelectorAll('.item'), function (r) { return r.textContent.indexOf(email) >= 0 && r.querySelector('button'); })[0]; };
    var rv = await waitFor(function () { var r = rowOf(NEW); return r && r.querySelector('button'); }, 'revoke button of the approved person');
    rv.click(); rv.click(); // two clicks: arm, then confirm
    await waitText('הוסרה. נשלחה הודעה');
    assert.ok(rowOf(STAFF), 'the other staff member is untouched');
    assert.includes(text(), 'הגישה הוסרה', 'history shows the revoked status');
    await openApp({ course: course.id, view: 'staff' }); await login(NEW);
    await waitFor(function () { return $('reqState') && $('reqState').textContent === 'הגישה הוסרה'; }, 'revoked shown to the person');
  });

  test('E2E', 'בלי וואטסאפ: מסך הכניסה רק במייל, והפרופיל מציג שם בלבד ונפתח בלי לחכות לשרת', async function () {
    var course = setupWorld();
    await openApp({ course: course.id });
    await waitFor(function () { return $('loginEmail'); }, 'login form');
    assert.equal($('waLoginBtn'), null, 'no WhatsApp sign-in button');
    assert.notIncludes(text(), 'וואטסאפ');
    await login(S1, 'נועה');
    $('nameBtn').click();
    await waitFor(function () { return $('profName'); }, 'profile opens at once');
    assert.equal($('profPhone'), null); assert.equal($('prefWa'), null);
    assert.notIncludes(text(), 'וואטסאפ'); assert.includes(text(), 'נשלחים למייל');
    setVal($('profName'), 'א'); $('profName').form.requestSubmit();
    await waitText('שתי אותיות לפחות', 'too-short name rejected');
    assert.includes($('whoami').textContent, 'נועה', 'name unchanged after a rejected save');
  });

  test('אבטחה', 'מי שפותח את קישור ההנהלה בלי אישור לא נכנס ללוח וגם לא מועבר אוטומטית', async function () {
    var course = setupWorld();
    await openApp({ course: course.id, view: 'staff' }); await login(S1);
    await waitFor(function () { return welcomeText().indexOf('עוד לא אושר') >= 0; });
    assert.includes(welcomeText(), 'ללא הרשאת הנהלה');
    assert.equal(byText('נתח והפק המלצות'), null); assert.equal($('input'), null, 'not dropped into the student chat either');
    await click('לאזור הסטודנטים של הקורס');
    await waitFor(function () { return welcomeText().indexOf('אזור הסטודנטים') >= 0 && $('input'); }, 'student area on request');
  });

  // =====================================================================
  test('מקרי קצה', 'Index.html שנפתח ישירות מהתיקייה (בלי Google) מציג הסבר ולא נתקע', async function () {
    if (frame) frame.remove();
    frame = document.createElement('iframe');
    frame.srcdoc = window.INDEX_HTML; // no google.script stand-in
    document.body.appendChild(frame);
    await waitFor(function () { return frame.contentDocument && frame.contentDocument.getElementById('app'); }, 'page');
    await waitText('זה קובץ המקור');
    assert.includes(text(), 'קישורים.html');
    assert.notIncludes(text(), 'טוען', 'no endless spinner');
  });

  test('מקרי קצה', 'מסך כניסה: מייל לא תקין וקוד שגוי מציגים שגיאה', async function () {
    MOCK.reset(); C('setup');
    await openApp({});
    setVal(await waitFor(function () { return $('loginEmail'); }), 'not-an-email@x');
    $('loginEmail').form.requestSubmit();
    await waitText('כתובת המייל לא תקינה');
    setVal($('loginEmail'), S1); $('loginEmail').form.requestSubmit();
    setVal(await waitFor(function () { return $('loginCode'); }), '000000' === MOCK.lastCode(S1) ? '111111' : '000000');
    $('loginCode').form.requestSubmit();
    await waitText('הקוד שגוי');
  });

  test('מקרי קצה', 'בלי מפתח Claude הצ\'אט עונה בתשובה קבועה', async function () {
    var course = setupWorld(); delete MOCK.props.ANTHROPIC_API_KEY;
    await openApp({ course: course.id }); await login(S1);
    await sendChat('שלום');
    assert.includes(text(), 'הפנייה נשמרה');
  });

  test('מקרי קצה', 'סטודנט מחוץ לרשימת המשתתפים רואה הודעה ולא צ\'אט', async function () {
    var course = setupWorld();
    await openApp({ course: course.id }); await login(S1);
    await waitText('הפניות שלי');
    var admin = C('verifyCode', ADMIN, (C('requestCode', ADMIN, null), MOCK.lastCode(ADMIN))).token;
    C('setRoster', admin, course.id, 'someone@test.local', true);
    await openApp({ course: course.id }, true);
    await waitText('לא ברשימת המשתתפים');
    assert.equal($('input'), null, 'no chat input');
  });

  test('מקרי קצה', 'שליחת הודעה ריקה לא אפשרית', async function () {
    var course = setupWorld();
    await openApp({ course: course.id }); await login(S1);
    var input = await waitFor(function () { return $('input'); });
    setVal(input, '   ');
    assert.equal($('send').disabled, true);
  });

  test('רגרסיה', 'כניסה נשמרת במכשיר, ויציאה מחזירה למסך הכניסה', async function () {
    var course = setupWorld();
    await openApp({ course: course.id }); await login(S1);
    await waitText('הפניות שלי');
    await openApp({ course: course.id }, true);
    await waitText('הפניות שלי', 'still signed in after reload');
    $('logoutBtn').click();
    await waitFor(function () { return $('loginEmail'); }, 'login form after logout');
  });

  // =====================================================================
  test('אבטחה', 'XSS: HTML בהודעה מוצג כטקסט אצל הסטודנט ואצל ההנהלה', async function () {
    var course = setupWorld();
    var attack = '<img src=x onerror="parent.__xss=1"><script>parent.__xss=2</script>';
    chatAI({ summary: '<b onmouseover="parent.__xss=3">סיכום</b>', reply: '<img src=y onerror="parent.__xss=4">' });
    await openApp({ course: course.id }); await login(S1); await sendChat(attack);
    await waitFor(function () { return cards().length === 1; });
    await sleep(100);
    assert.equal(d().querySelectorAll('img').length, 0, 'no img element created in student view');
    assert.includes(text(), '<img src=x', 'shown literally');
    await openApp({ course: course.id, view: 'staff' }); await login(STAFF);
    await click('פניות', 'button');
    await waitText('<b onmouseover');
    await sleep(100);
    assert.equal(d().querySelectorAll('img, b[onmouseover], script[src]').length, 0, 'no injected elements in staff view');
    assert.equal(window.__xss, undefined, 'no injected script ran');
  });

  function adminToken() { return C('verifyCode', ADMIN, (C('requestCode', ADMIN, null), MOCK.lastCode(ADMIN))).token; }
  function rowWith(name) { return Array.prototype.filter.call(d().querySelectorAll('.card.spread'), function (c) { return c.textContent.indexOf(name) >= 0; })[0]; }

  test('E2E', 'קישור הנהלה קבוע: קורס אחד נפתח ישר, כמה קורסים מוצגים לבחירה, ואפשר להחליף קורס', async function () {
    setupWorld();
    await openApp({ view: 'staff' }); await login(STAFF, 'יוסי');
    await waitFor(function () { return text().indexOf('לוח וניתוח') >= 0; }, 'one course: straight to its board');
    assert.ok(byText('הקורסים שלי'), '"my courses" is there even with one course');
    var admin = adminToken();
    var second = C('createCourse', admin, { name: 'קורס שני' });
    C('addStaff', admin, second.id, STAFF, false);
    await openApp({ view: 'staff' }, true);
    await waitText('יש לך גישה ללוח ההנהלה', 'picker lists the courses');
    assert.includes(text(), 'מפתחי AI'); assert.includes(text(), 'קורס שני');
    (await waitFor(function () { return rowWith('קורס שני'); }, 'second course row')).querySelector('button').click();
    await waitFor(function () { return $('titleCourse').textContent.indexOf('קורס שני') >= 0 && text().indexOf('לוח וניתוח') >= 0; }, 'entered the chosen course');
    await click('הקורסים שלי');
    await waitText('יש לך גישה ללוח ההנהלה', 'back to the picker');
  });

  test('E2E', 'איש הנהלה פותח קורס חדש בעצמו, עובר בין הקורסים, ולכל קורס הלשוניות שלו', async function () {
    setupWorld();
    await openApp({ view: 'staff' }); await login(STAFF, 'יוסי');
    await waitFor(function () { return text().indexOf('לוח וניתוח') >= 0; }, 'board');
    await click('הקורסים שלי');
    await waitText('פתיחת קורס חדש');
    setVal($('nName'), 'קורס מפתחי AI מספר 15'); setVal($('nOrg'), 'האוניברסיטה העברית');
    await click('יצירת קורס');
    await waitFor(function () { return $('titleCourse').textContent.indexOf('קורס מפתחי AI מספר 15') >= 0; }, 'inside the new course');
    ['פניות', 'מיילים לסטודנטים', 'הערות, זום והקלטות', 'לוח זמנים וסילבוס', 'שיתוף'].forEach(function (t) { assert.ok(byText(t), 'tab ' + t); });
    assert.equal(byText('כל הקורסים'), null, 'no admin tabs for staff');
    await click('הקורסים שלי');
    await waitText('יש לך גישה ללוח ההנהלה');
    assert.includes(text(), 'מפתחי AI'); assert.includes(text(), 'קורס מפתחי AI מספר 15');
    (await waitFor(function () { return rowWith('מפתחי AI') && rowWith('מספר 15') && Array.prototype.filter.call(d().querySelectorAll('.card.spread'), function (c) { return c.textContent.indexOf('מפתחי AI') >= 0 && c.textContent.indexOf('מספר 15') < 0; })[0]; }, 'first course row')).querySelector('button').click();
    await waitFor(function () { return $('titleCourse').textContent.indexOf('מפתחי AI') >= 0 && $('titleCourse').textContent.indexOf('15') < 0; }, 'back in the first course');
  });

  test('E2E', 'חתימה, שליחת קישורי הזום ושליחת הקלטה במייל מתוך הלשוניות', async function () {
    var course = setupWorld();
    C('boot', C('verifyCode', S1, (C('requestCode', S1, course.id), MOCK.lastCode(S1))).token, course.id); // one student in the course
    await openApp({ course: course.id, view: 'staff' }); await login(ADMIN, 'שחר');
    await waitFor(function () { return text().indexOf('לוח וניתוח') >= 0; }, 'board');
    // signature
    await click('מיילים לסטודנטים');
    setVal(await waitFor(function () { return $('signature'); }, 'signature box'), 'בברכה,\nשחר, מנהל התוכנית');
    await click('שמירת החתימה');
    await waitText('החתימה נשמרה');
    // Zoom: save, then send to all the students
    await click('הערות, זום והקלטות');
    setVal(await waitFor(function () { return d().querySelector('input[aria-label="קישור לזום השיעורים"]'); }), 'https://zoom.us/j/555');
    setVal(d().querySelector('input[aria-label="סיסמה לזום השיעורים"]'), 'pw');
    await click('שמירת קישורי הזום');
    await waitText('קישורי הזום נשמרו');
    var panel = await waitFor(function () { return Array.prototype.filter.call(d().querySelectorAll('.send-panel'), function (x) { return x.textContent.indexOf('שליחת קישורי הזום במייל') >= 0; })[0]; }, 'zoom send panel');
    var openBtn = panel.querySelector('.send-open');
    assert.includes(openBtn.className, 'btn', 'a clear (blue) button, not a small link');
    assert.ok(panel.querySelector('.stack').hidden, 'the options open on click');
    openBtn.click();
    assert.ok(!panel.querySelector('.stack').hidden);
    var before = MOCK.outbox.length;
    panel.querySelector('.send-go').click();
    assert.includes(panel.querySelector('.send-go').textContent, 'ללחוץ שוב כדי לשלוח לכל הסטודנטים');
    panel.querySelector('.send-go').click();
    await waitFor(function () { return panel.textContent.indexOf('נשלחו 1 מיילים') >= 0; }, 'zoom sent');
    var z = MOCK.outbox[before];
    assert.equal(z.to, S1); assert.includes(z.htmlBody, 'https://zoom.us/j/555'); assert.includes(z.htmlBody, 'שחר, מנהל התוכנית');
    assert.equal(z.name, 'קול הסטודנטים - מפתחי AI');
    // a recording, to one chosen address
    var urls = d().querySelectorAll('input[type=url]'); setVal(urls[urls.length - 1], 'https://drive.google.com/rec2');
    var nums = d().querySelectorAll('input[type=number]'); setVal(nums[nums.length - 1], '2');
    await click('הוספה');
    await waitText('ההקלטה נשמרה');
    var rp = await waitFor(function () { return Array.prototype.filter.call(d().querySelectorAll('.send-panel'), function (x) { return x.textContent.indexOf('שליחת שיעור 2 במייל') >= 0; })[0]; }, 'recording send button');
    rp.querySelector('.send-open').click();
    rp.querySelectorAll('input[type=radio]')[1].click();
    setVal(rp.querySelector('textarea'), 'chosen@x.com');
    before = MOCK.outbox.length;
    rp.querySelector('.send-go').click(); rp.querySelector('.send-go').click();
    await waitFor(function () { return rp.textContent.indexOf('נשלחו 1 מיילים') >= 0; }, 'recording sent');
    assert.equal(MOCK.outbox[before].to, 'chosen@x.com'); assert.includes(MOCK.outbox[before].subject, 'הקלטת שיעור 2');
    assert.includes(MOCK.outbox[before].htmlBody, 'https://drive.google.com/rec2');
  });

  test('E2E', 'סטודנט רואה בלשוניות את ההודעות, הזום, ההקלטות, המועדים והסילבוס שההנהלה שיתפה', async function () {
    var course = setupWorld();
    var admin = adminToken();
    C('saveZoom', admin, course.id, { lessonUrl: 'https://zoom.us/j/77', lessonPass: 'sod' });
    C('saveRecording', admin, course.id, { kind: 'lesson', number: 4, topic: 'פונקציות', url: 'https://x.com/rec4' });
    C('saveMeeting', admin, course.id, { kind: 'practice', number: 2, date: '2026-11-03', start: '10:00', end: '11:30' });
    C('uploadDeskFile', admin, course.id, 'syllabus', { name: 'syllabus.pdf', type: 'application/pdf', data: btoa('%PDF-1.4') });
    C('sendCourseMail', admin, course.id, { to: 'list', emails: S1, subject: 'לא אמור להופיע', body: 'x' });
    await openApp({ course: course.id }); await login(S1, 'נועה');
    await waitFor(function () { return $('input'); }, 'chat');
    assert.ok(document.body.className.indexOf('area-student') >= 0 || frame.contentDocument.body.className.indexOf('area-student') >= 0, 'student colours');
    C('sendCourseMail', admin, course.id, { to: 'students', subject: 'ברוכים הבאים לקורס', body: 'השיעור הראשון ביום ראשון' });
    await click('הודעות');
    await waitText('ברוכים הבאים לקורס');
    assert.includes(text(), 'השיעור הראשון ביום ראשון'); assert.notIncludes(text(), 'לא אמור להופיע');
    await click('זום והקלטות');
    await waitText('חדרי הזום של הקורס');
    var z = Array.prototype.filter.call(d().querySelectorAll('a'), function (a) { return a.getAttribute('href') === 'https://zoom.us/j/77'; })[0];
    assert.ok(z, 'zoom link'); assert.equal(z.target, '_blank'); assert.includes(text(), 'סיסמה: sod');
    assert.includes(text(), 'שיעור 4 · פונקציות');
    await click('לוח זמנים וסילבוס');
    await waitText('מועדי השיעורים והתרגולים');
    assert.includes(text(), 'תרגול 2'); assert.includes(text(), '10:00–11:30');
    await click('הורדה');
    await waitFor(function () { return window.__downloads.some(function (x) { return x.name === 'syllabus.pdf'; }); }, 'syllabus downloaded');
    await click('צ\'אט משוב');
    await waitFor(function () { return $('input'); }, 'back to the chat');
  });

  test('E2E', 'מסכי כניסה שונים לכל אזור, עם הסבר בולט על חשבון Google', async function () {
    setupWorld();
    var area = function () { return frame.contentDocument.body.className; };
    await openApp({ view: 'staff' });
    await waitFor(function () { return $('googleNote'); }, 'staff note');
    assert.includes(area(), 'area-staff'); assert.includes($('googleNote').textContent, 'היכנסו עם חשבון Google');
    assert.includes($('googleNote').textContent, 'השימוש מוגבל'); assert.includes(text(), 'אזור הנהלת הקורס');
    await openApp({ view: 'student' });
    await waitFor(function () { return $('googleNote'); }, 'student note');
    assert.includes(area(), 'area-student'); assert.includes($('googleNote').textContent, 'כל כתובת מייל');
    await openApp({});
    await waitFor(function () { return $('googleNote'); }, 'admin note');
    assert.includes(area(), 'area-admin'); assert.includes(text(), 'אזור המנהל');
  });

  test('E2E', 'איש הנהלה מתבקש לחבר את המייל כבר בכניסה, ומשם נכנס ללוח', async function () {
    setupWorld();
    await openApp({ view: 'staff' });
    login.keepGate = true;
    try { await login(STAFF, 'יוסי'); } finally { login.keepGate = false; }
    await waitFor(function () { return $('connectGate'); }, 'email step right after sign-in');
    assert.includes(text(), 'חיבור המייל שלך');
    await click('חיבור המייל שלי');
    var url = await waitFor(function () { return window.__opened[0] && window.__opened[0].location.href; }, 'sender window');
    assert.includes(MOCK.makeSender(STAFF).open(url), '✓ מחובר');
    await click('אישרתי, להמשיך');
    await waitFor(function () { return text().indexOf('לוח וניתוח') >= 0; }, 'on to the board');
    assert.notIncludes($('bandText').textContent, 'עוד לא מחובר');
    // someone else skips: asked again only tomorrow, and the board says the email is not connected
    var admin = adminToken(); C('addStaff', admin, C('boot', admin, null).staffCourses[0].id, 'later@test.local', false);
    await openApp({ view: 'staff' }); await login('later@test.local', 'דנה');
    await waitFor(function () { return text().indexOf('לוח וניתוח') >= 0; }, 'skipped to the board');
    assert.includes($('bandText').textContent, 'המייל שלך עוד לא מחובר');
    await openApp({ view: 'staff' }, true);
    await waitFor(function () { return text().indexOf('לוח וניתוח') >= 0; }, 'not asked again today');
    assert.equal($('connectGate'), null);
  });

  test('E2E', 'בלי שום קורס במערכת: איש הנהלה מבקש הרשאה לפתוח קורסים, המנהל מאשר, והוא פותח קורס', async function () {
    MOCK.reset(); C('setup');
    var admin = adminToken();
    await openApp({ view: 'staff' }); await login('founder@test.local', 'רוני');
    await waitFor(function () { return $('creatorCard'); }, 'creator request card');
    assert.includes(text(), 'בקשת הרשאה לפתוח קורסים');
    setVal($('creatorCard').querySelector('textarea'), 'רכזת תוכנית הדאטה');
    await click('בקשת הרשאה לפתוח קורסים');
    await waitText('ממתינה לאישור מנהל המערכת');
    assert.ok(MOCK.outbox.some(function (m) { return m.to === ADMIN && m.subject === 'בקשת הרשאה לפתוח קורסים'; }), 'admin told');
    // the admin approves on the admin page
    await openApp({}); await login(ADMIN, 'שחר');
    await waitText('פתיחת קורסים חדשים');
    assert.includes(text(), 'רכזת תוכנית הדאטה');
    await click('אישור');
    await waitText('קיבל/ה הרשאה לפתוח קורסים');
    // back as the requester: the new course form, and the course opens with all its tabs
    await openApp({ view: 'staff' }); await login('founder@test.local', 'רוני');
    await waitText('אפשר לפתוח כאן את הקורס הראשון שלך');
    setVal($('nName'), 'קורס דאטה מספר 1');
    await click('יצירת קורס');
    // now on the staff of a course: asked to connect their email, as every staff member
    await waitFor(function () { return $('connectGate'); }, 'email step');
    await click('אחר כך');
    await waitFor(function () { return $('titleCourse').textContent.indexOf('קורס דאטה מספר 1') >= 0 && byText('מיילים לסטודנטים'); }, 'inside the new course');
    assert.ok(byText('הקורסים שלי'));
  });

  test('E2E', 'כניסה עם חדשות: סטודנט רואה באנר בולט, מספרים על הלשוניות ובכותרת, והם נעלמים אחרי צפייה', async function () {
    var course = setupWorld();
    var admin = adminToken();
    var s1 = C('verifyCode', S1, (C('requestCode', S1, course.id), MOCK.lastCode(S1))).token;
    C('setMyName', s1, 'נועה'); C('boot', s1, course.id);
    var a = C('sendMessage', s1, course.id, { itemId: null, text: 'בעיה', anonymous: false });
    C('reply', admin, a.itemId, 'תוקן', 'done', false);
    C('sendCourseMail', admin, course.id, { to: 'students', subject: 'מחר אין שיעור', body: 'נדחה' });
    C('saveZoom', admin, course.id, { lessonUrl: 'https://zoom.us/j/9' });
    await openApp({ course: course.id }); await login(S1, 'נועה');
    var banner = await waitFor(function () { return $('newsBanner'); }, 'what is new banner');
    assert.includes(banner.textContent, 'מענה חדש מהנהלת הקורס'); assert.includes(banner.textContent, 'הודעה חדשה'); assert.includes(banner.textContent, 'קישורי הזום');
    var tab = function (label) { return Array.prototype.filter.call(d().querySelectorAll('#tabs button'), function (b) { return b.textContent.indexOf(label) === 0; })[0]; };
    assert.ok(tab('הודעות').querySelector('.badge'), 'badge on messages'); assert.ok(tab('זום והקלטות').querySelector('.badge'));
    assert.ok(/^\(\d+\)/.test(frame.contentDocument.title), 'count in the window title');
    await click('להודעות');
    await waitText('מחר אין שיעור');
    assert.includes(text(), '● חדש');
    await waitFor(function () { return !tab('הודעות').querySelector('.badge'); }, 'badge cleared after looking');
    await click('זום והקלטות');
    await waitText('חדרי הזום של הקורס');
    await waitFor(function () { return !tab('זום והקלטות').querySelector('.badge'); }, 'zoom badge cleared');
    // the next visit: nothing new, no banner
    await openApp({ course: course.id }, true);
    await waitFor(function () { return $('input'); }, 'chat');
    await sleep(100);
    assert.equal($('newsBanner'), null);
    assert.equal(tab('הודעות').querySelector('.badge'), null);
  });

  test('E2E', 'פניות אצל ההנהלה: באנר על פניות חדשות, קיבוץ לפי סטודנט, ריכוז לטיפול, הערה פנימית וסימון למעקב', async function () {
    var course = setupWorld();
    var s1 = C('verifyCode', S1, (C('requestCode', S1, course.id), MOCK.lastCode(S1))).token;
    C('setMyName', s1, 'נועה');
    C('sendMessage', s1, course.id, { itemId: null, text: 'המצגות לא עולות', anonymous: false });
    C('sendMessage', s1, course.id, { itemId: null, text: 'נושא חדש לגמרי', anonymous: false });
    var s2 = C('verifyCode', 'anon@test.local', (C('requestCode', 'anon@test.local', course.id), MOCK.lastCode('anon@test.local'))).token;
    C('sendMessage', s2, course.id, { itemId: null, text: 'בעיה אנונימית', anonymous: true });
    await openApp({ course: course.id, view: 'staff' }); await login(STAFF, 'יוסי');
    var banner = await waitFor(function () { return $('newsBanner'); }, 'staff banner');
    assert.includes(banner.textContent, 'פניות חדשות מסטודנטים');
    assert.ok(Array.prototype.some.call(d().querySelectorAll('#tabs .badge'), function (x) { return x.textContent === '3'; }), 'badge 3 on requests');
    await click('לפניות החדשות');
    await waitText('ריכוז לטיפול');
    assert.includes(text(), 'מחכות למענה');
    await click('הכל');
    var groups = await waitFor(function () { var g = d().querySelectorAll('.student-group'); return g.length === 2 && g; }, 'two student groups');
    assert.includes(text(), 'סטודנט/ית בעילום שם #');
    var noa = Array.prototype.filter.call(groups, function (g) { return g.textContent.indexOf(S1) >= 0; })[0];
    assert.equal(noa.querySelectorAll('.item').length, 2, 'both requests of the same student together');
    assert.includes(noa.textContent, '2 מחכות למענה');
    // follow-up mark and internal note
    noa.querySelector('.item button.link').click(); // ☆ סימון למעקב
    await waitText('★ במעקב');
    var card = d().querySelector('.item.flagged');
    card.querySelector('details').open = true;
    setVal(card.querySelector('textarea[aria-label="הערה פנימית"]'), 'לבדוק עם המרצה');
    Array.prototype.filter.call(card.querySelectorAll('button'), function (b) { return b.textContent === 'שמירת ההערה'; })[0].click();
    await waitText('ההערה נשמרה');
    assert.equal(C('board', adminToken(), course.id).items.filter(function (i) { return i.staffNote === 'לבדוק עם המרצה'; }).length, 1);
    await click('למעקב');
    await waitFor(function () { return d().querySelectorAll('.item').length === 1; }, 'only the flagged one');
    await click('רשימה לפי זמן');
    await click('הכל');
    await waitFor(function () { return !d().querySelector('.student-group') && d().querySelectorAll('.item').length === 3; }, 'plain list');
  });

  test('מקרי קצה', 'מסך הקוד מציג בבירור לאיזו כתובת נשלח הקוד, ו"תיקון כתובת המייל" מחזיר עם הכתובת לתיקון', async function () {
    setupWorld();
    await openApp({ view: 'staff' });
    setVal(await waitFor(function () { return $('loginEmail'); }), 'arcoblenochic@gmail.com');
    $('loginEmail').form.requestSubmit();
    await waitFor(function () { return $('sentTo'); }, 'code screen');
    assert.equal($('sentTo').textContent, 'arcoblenochic@gmail.com');
    assert.includes(text(), 'אות אחת חסרה מספיקה');
    await click('תיקון כתובת המייל');
    var i = await waitFor(function () { return $('loginEmail'); }, 'back to the email form');
    assert.equal(i.value, 'arcoblenochic@gmail.com', 'the address is there to fix');
  });

  test('E2E', 'קישור הנהלה קבוע בלי הרשאה: בוחרים קורס, שולחים בקשה, והמנהל רואה אותה', async function () {
    var course = setupWorld();
    await openApp({ view: 'staff' }); await login('newbie@test.local', 'רונית');
    await waitText('עוד אין גישה', 'explains there is no access yet');
    await click('לבקשת הרשאה');
    await click('בקשת הרשאה להנהלת הקורס');
    await waitFor(function () { return $('reqState') && $('reqState').textContent === 'ממתין לאישור המנהל'; }, 'pending');
    var reqs = C('listStaffRequests', adminToken());
    assert.equal(reqs[0].email, 'newbie@test.local'); assert.equal(reqs[0].courseId, course.id);
  });

  test('E2E', 'קישור סטודנטים קבוע: קורס אחד נפתח ישר, כמה קורסים לבחירה, וקורס סגור לא מוצג למי שלא ברשימה', async function () {
    setupWorld();
    await openApp({ view: 'student' }); await login(S1, 'נועה');
    await waitFor(function () { return $('input'); }, 'one open course: straight to the chat');
    var admin = adminToken();
    C('createCourse', admin, { name: 'קורס שני' });
    var closed = C('createCourse', admin, { name: 'קורס סגור' });
    C('setRoster', admin, closed.id, 'someone@test.local', true);
    await openApp({ view: 'student' }, true);
    await waitText('בחרו את הקורס', 'picker');
    assert.includes(text(), 'קורס שני'); assert.notIncludes(text(), 'קורס סגור');
    (await waitFor(function () { return rowWith('קורס שני'); }, 'row')).querySelector('button').click();
    await waitFor(function () { return $('input') && $('titleCourse').textContent.indexOf('קורס שני') >= 0; }, 'chat of the chosen course');
    assert.ok(byText('החלפת קורס'), 'switch course offered');
  });

  test('E2E', 'מחיקת קורס ויצירת חדש: קישור ישן לקורס שנמחק מוביל לקורס החדש ולא לשגיאה', async function () {
    var course = setupWorld();
    var admin = adminToken();
    C('deleteCourse', admin, course.id, 'מפתחי AI');
    var fresh2 = C('createCourse', admin, { name: 'קורס חדש' });
    C('addStaff', admin, fresh2.id, STAFF, false);
    await openApp({ course: course.id, view: 'staff' });
    await waitFor(function () { return welcomeText().indexOf('ללוח של הקורס שלכם') >= 0; }, 'old link: the normal staff sign-in');
    await login(STAFF, 'יוסי');
    // their only course opens by itself, with no warning about the old link
    await waitFor(function () { return $('titleCourse').textContent.indexOf('קורס חדש') >= 0 && text().indexOf('לוח וניתוח') >= 0; }, 'staff board of the new course');
    assert.notIncludes(text(), 'כבר לא קיים');
    // the same for a student holding an old link
    await openApp({ course: course.id }); await login(S1, 'נועה');
    await waitFor(function () { return $('input') && $('titleCourse').textContent.indexOf('קורס חדש') >= 0; }, 'student chat of the new course');
    assert.notIncludes(text(), 'כבר לא קיים');
  });

  test('E2E', 'מענה לפנייה: ברירת המחדל "טופל", הסטטוס מתעדכן אצל המנהל, ובמסננים אין מספרים', async function () {
    var course = setupWorld();
    var s1 = C('verifyCode', S1, (C('requestCode', S1, course.id), MOCK.lastCode(S1))).token;
    C('setMyName', s1, 'נועה');
    C('sendMessage', s1, course.id, { itemId: null, text: 'המצגות לא עולות', anonymous: true });
    await openApp({ course: course.id, view: 'staff' }); await login(STAFF, 'יוסי');
    await click('פניות');
    var filters = await waitFor(function () { return d().querySelector('.filters'); }, 'status filters');
    var labels = Array.prototype.map.call(filters.querySelectorAll('button'), function (b) { return b.textContent; });
    assert.equal(labels.join('|'), 'מחכות למענה|חדשות|למעקב|ממתין לטיפול|בטיפול|טופל|הכל', 'filter labels without counts');
    var sel = d().querySelector('.item .editor select');
    assert.equal(sel.value, 'done', 'answering defaults to "done"');
    setVal(d().querySelector('.item .editor textarea'), 'העלינו את המצגות');
    await click('עדכון הסטודנט');
    await waitText('הסטודנט יראה את העדכון');
    // the system admin sees the same status
    await openApp({ course: course.id, view: 'staff' }); await login(ADMIN);
    await click('פניות');
    await click('טופל');
    await waitFor(function () { return d().querySelector('.item .st.done'); }, 'request shown as done to the admin');
  });

  test('E2E', 'שולחן הקורס בממשק: הערות, זום, הקלטה עם קישור לחיץ, סדרת מועדים ומייל לסטודנטים', async function () {
    var course = setupWorld();
    var s1 = C('verifyCode', S1, (C('requestCode', S1, course.id), MOCK.lastCode(S1))).token;
    C('boot', s1, course.id);
    await openApp({ course: course.id, view: 'staff' }); await login(STAFF, 'יוסי');
    await click('הערות, זום והקלטות');
    setVal(await waitFor(function () { return $('deskNotes'); }, 'notes box'), 'לזכור לבדוק את מטלה 2');
    await click('שמירת ההערות');
    await waitText('ההערות נשמרו');
    assert.equal($('deskNotes').value, 'לזכור לבדוק את מטלה 2', 'notes still shown after saving');
    setVal(d().querySelector('input[aria-label="קישור לזום השיעורים"]'), 'https://zoom.us/j/123');
    setVal(d().querySelector('input[aria-label="סיסמה לזום השיעורים"]'), 'pass1');
    await click('שמירת קישורי הזום');
    await waitText('סיסמה: pass1');
    var zl = Array.prototype.filter.call(d().querySelectorAll('a'), function (a) { return a.textContent === 'כניסה לזום'; })[0];
    assert.equal(zl.getAttribute('href'), 'https://zoom.us/j/123'); assert.equal(zl.target, '_blank');
    var urls = d().querySelectorAll('input[type=url]'); setVal(urls[urls.length - 1], 'https://drive.google.com/rec1');
    var nums = d().querySelectorAll('input[type=number]'); setVal(nums[nums.length - 1], '1');
    await click('הוספה');
    await waitText('ההקלטה נשמרה');
    var rec = Array.prototype.filter.call(d().querySelectorAll('a'), function (a) { return a.textContent === 'צפייה בהקלטה'; })[0];
    assert.equal(rec.getAttribute('href'), 'https://drive.google.com/rec1');
    assert.includes(text(), 'שיעור 1');
    // schedule: a weekly series of 36 lessons
    await click('לוח זמנים וסילבוס');
    await waitText('מועדי השיעורים והתרגולים');
    d().querySelector('details').open = true;
    var ed = d().querySelectorAll('details .editor input');
    setVal(ed[1], '36'); ed[2].value = '2026-11-01';
    await click('יצירת הסדרה');
    try { await waitText('הסדרה נוספה', 'series created'); } catch (e) { throw new Error('DEBUG status=' + $('boardStatus').textContent + ' inputs=' + Array.prototype.map.call(ed, function (i) { return i.value; }).join('|')); }
    assert.includes(text(), '36 שיעורים · 0 תרגולים');
    assert.includes(text(), 'שיעור 36');
    // email to the students
    // email to the students: first connect the staff member's own Gmail, then send
    await click('מיילים לסטודנטים');
    await waitText('כל הסטודנטים בקורס (1)');
    assert.includes(text(), 'חברו פעם אחת את המייל שלכם');
    var sendBtn = Array.prototype.filter.call(d().querySelectorAll('button'), function (b) { return b.textContent === 'שליחה'; })[0];
    assert.equal(sendBtn.disabled, true, 'sending waits for the connection');
    await click('חיבור המייל שלי');
    await waitText('בחלון שנפתח');
    var url = await waitFor(function () { return window.__opened[0] && window.__opened[0].location.href; }, 'sender window');
    assert.includes(url, '?ticket=');
    var mine = MOCK.makeSender(STAFF);
    assert.includes(mine.open(url), '✓ מחובר');
    await click('בדיקת מצב');
    await waitText('✓ מחובר. מיילים שתשלחו מכאן יוצאים מהמייל שלך (' + STAFF + ')');
    setVal($('mailSubject'), 'ברוכים הבאים'); setVal($('mailBody'), 'שלום לכולם');
    var before = MOCK.outbox.length;
    await click('שליחה');
    await click('ללחוץ שוב כדי לשלוח ל-1 סטודנטים');
    await waitText('נכנס לתור, ויוצא מהמייל שלך');
    assert.includes(text(), '1 ממתינים');
    mine.app.tick();
    assert.equal(MOCK.outbox.length, before, 'not from the system account');
    assert.equal(mine.sent[0].to, S1); assert.equal(mine.sent[0].subject, 'ברוכים הבאים');
    await click('בדיקת מצב');
    await waitText('ברוכים הבאים · 1 נמענים · ' + STAFF + ' (מהמייל האישי)');
    await click('ניתוק'); await click('ללחוץ שוב כדי לנתק');
    await waitText('נותק.');
    await waitText('חיבור המייל שלי');
  });

  test('מקרי קצה', 'טיוטת הערות או מייל של קורס אחד לא עוברת לקורס אחר', async function () {
    var course = setupWorld();
    var admin = adminToken();
    var second = C('createCourse', admin, { name: 'קורס שני' });
    C('addStaff', admin, second.id, STAFF, false);
    await openApp({ course: course.id, view: 'staff' }); await login(STAFF, 'יוסי');
    await click('הערות, זום והקלטות');
    setVal(await waitFor(function () { return $('deskNotes'); }, 'notes box'), 'טיוטה של קורס ראשון');
    await click('הקורסים שלי');
    (await waitFor(function () { return rowWith('קורס שני'); }, 'second course')).querySelector('button').click();
    await waitFor(function () { return $('titleCourse').textContent.indexOf('קורס שני') >= 0 && text().indexOf('לוח וניתוח') >= 0; }, 'second board');
    await click('הערות, זום והקלטות');
    assert.equal((await waitFor(function () { return $('deskNotes'); }, 'notes box')).value, '', 'no draft from the other course');
  });

  test('אבטחה', 'סטודנט שמנסה לפתוח את לוח ההנהלה לא רואה שום חלק מהלוח', async function () {
    var course = setupWorld();
    await openApp({ course: course.id, view: 'staff' }); await login(S1);
    await waitFor(function () { return welcomeText().indexOf('עוד לא אושר') >= 0; });
    assert.notIncludes(text(), 'נתח והפק המלצות');
    assert.equal(byText('לוח הנהלת הקורס'), null, 'no staff tab for a student');
    assert.equal(byText('פניות'), null, 'no requests tab');
  });
})();
