/*
 * In-memory stand-ins for the Google Apps Script services Code.gs uses.
 * They let the real server code run in a browser for tests, with no Google account.
 * Everything a test may want to inspect or control lives on window.MOCK.
 */
(function () {
  'use strict';

  // ---------- synchronous SHA-256 (Utilities.computeDigest is synchronous) ----------
  var K = [0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2];
  function sha256(bytes) {
    var H = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    var l = bytes.length, withPad = ((l + 9 + 63) >> 6) << 6, m = new Uint8Array(withPad);
    m.set(bytes); m[l] = 0x80;
    var bits = l * 8; for (var i = 0; i < 8; i++) m[withPad - 1 - i] = (bits / Math.pow(2, 8 * i)) & 0xff;
    var w = new Array(64);
    for (var o = 0; o < withPad; o += 64) {
      for (var t = 0; t < 16; t++) w[t] = (m[o + 4 * t] << 24) | (m[o + 4 * t + 1] << 16) | (m[o + 4 * t + 2] << 8) | m[o + 4 * t + 3];
      for (t = 16; t < 64; t++) {
        var a0 = w[t - 15], a1 = w[t - 2];
        var s0 = ((a0 >>> 7) | (a0 << 25)) ^ ((a0 >>> 18) | (a0 << 14)) ^ (a0 >>> 3);
        var s1 = ((a1 >>> 17) | (a1 << 15)) ^ ((a1 >>> 19) | (a1 << 13)) ^ (a1 >>> 10);
        w[t] = (w[t - 16] + s0 + w[t - 7] + s1) | 0;
      }
      var a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
      for (t = 0; t < 64; t++) {
        var S1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7));
        var ch = (e & f) ^ (~e & g);
        var t1 = (h + S1 + ch + K[t] + w[t]) | 0;
        var S0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10));
        var mj = (a & b) ^ (a & c) ^ (b & c);
        var t2 = (S0 + mj) | 0;
        h = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
      }
      H[0] = (H[0] + a) | 0; H[1] = (H[1] + b) | 0; H[2] = (H[2] + c) | 0; H[3] = (H[3] + d) | 0;
      H[4] = (H[4] + e) | 0; H[5] = (H[5] + f) | 0; H[6] = (H[6] + g) | 0; H[7] = (H[7] + h) | 0;
    }
    var out = []; H.forEach(function (x) { out.push((x >>> 24) & 255, (x >>> 16) & 255, (x >>> 8) & 255, x & 255); });
    return out;
  }
  var te = new TextEncoder(), td = new TextDecoder();
  function toB64(bytes) { var s = ''; for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i] & 255); return btoa(s); }
  function fromB64(str) { var bin = atob(str); var out = new Array(bin.length); for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i); return out; }

  var MOCK = window.MOCK = {
    props: {}, cache: {}, outbox: [], files: {}, folders: {}, spreadsheets: {},
    fetches: [], mailQuota: 100, owner: 'owner@test.local', url: 'https://script.test/exec',
    activeUser: 'owner@test.local', // who runs the function: the owner in the editor, '' for a web visitor
    claude: null, // function(requestBody) -> response JSON; null = respond with a fixed chat answer
    propReads: 0, // how many times the code went to the Properties service (each is a slow call in Google)
    reset: function () {
      MOCK.props = {}; MOCK.cache = {}; MOCK.outbox = []; MOCK.files = {}; MOCK.folders = {}; MOCK.spreadsheets = {};
      MOCK.fetches = []; MOCK.mailQuota = 100; MOCK.claude = null; MOCK.propReads = 0; MOCK.activeUser = MOCK.owner;
    },
    lastCode: function (email) {
      for (var i = MOCK.outbox.length - 1; i >= 0; i--) {
        var m = MOCK.outbox[i]; if (m.to === email) { var hit = /(\d{6})/.exec(m.subject); if (hit) return hit[1]; }
      }
      return null;
    },
  };
  var seq = 0;
  function nid(prefix) { seq++; return prefix + seq + Math.random().toString(36).slice(2, 8); }

  // ---------- Properties / Cache / Lock / Session / Logger ----------
  window.PropertiesService = { getScriptProperties: function () {
    return {
      getProperty: function (k) { MOCK.propReads++; return Object.prototype.hasOwnProperty.call(MOCK.props, k) ? MOCK.props[k] : null; },
      getProperties: function () { MOCK.propReads++; return Object.assign({}, MOCK.props); },
      setProperty: function (k, v) { MOCK.props[k] = String(v); return this; },
      deleteProperty: function (k) { delete MOCK.props[k]; return this; },
    };
  } };
  window.CacheService = { getScriptCache: function () {
    return {
      get: function (k) { var e = MOCK.cache[k]; if (!e) return null; if (e.until < Date.now()) { delete MOCK.cache[k]; return null; } return e.v; },
      put: function (k, v, ttl) { MOCK.cache[k] = { v: String(v), until: Date.now() + (ttl || 600) * 1000 }; },
      remove: function (k) { delete MOCK.cache[k]; },
    };
  } };
  window.LockService = { getScriptLock: function () { return { waitLock: function () {}, releaseLock: function () {} }; } };
  window.Session = {
    getEffectiveUser: function () { return { getEmail: function () { return MOCK.owner; } }; },
    getActiveUser: function () { return { getEmail: function () { return MOCK.activeUser; } }; },
  };
  window.Logger = { log: function (m) { (MOCK.logs = MOCK.logs || []).push(String(m)); } };
  window.ScriptApp = { getService: function () { return { getUrl: function () { return MOCK.url; } }; } };
  window.HtmlService = { createHtmlOutputFromFile: function () { var o = { setTitle: function () { return o; }, addMetaTag: function () { return o; } }; return o; } };

  // ---------- Utilities ----------
  window.Utilities = {
    DigestAlgorithm: { SHA_256: 'SHA_256' }, Charset: { UTF_8: 'UTF_8' },
    getUuid: function () { return crypto.randomUUID(); },
    computeDigest: function (alg, value) { return sha256(typeof value === 'string' ? te.encode(value) : value); },
    base64EncodeWebSafe: function (bytes) { return toB64(bytes).replace(/\+/g, '-').replace(/\//g, '_'); },
    base64Encode: function (bytes) { return toB64(bytes); },
    base64Decode: function (s) { return fromB64(s); },
    newBlob: function (bytes, type, name) { return makeBlob(bytes, type, name); },
  };
  function makeBlob(bytes, type, name) {
    var data = typeof bytes === 'string' ? Array.from(te.encode(bytes)) : Array.from(bytes);
    return { getBytes: function () { return data.slice(); }, getDataAsString: function () { return td.decode(new Uint8Array(data)); }, getContentType: function () { return type; }, getName: function () { return name; } };
  }

  // ---------- Drive ----------
  function makeFolder(id, name) {
    var f = {
      id: id, name: name, trashed: false,
      getId: function () { return id; },
      setTrashed: function (t) { f.trashed = t; return f; },
      createFolder: function (n) { var cid = nid('fld'); MOCK.folders[cid] = makeFolder(cid, n); return MOCK.folders[cid]; },
      createFile: function (blobOrName, content, mime) {
        var blob = typeof blobOrName === 'string' ? makeBlob(content, mime, blobOrName) : blobOrName;
        var fid = nid('file');
        MOCK.files[fid] = { id: fid, folder: id, blob: blob, trashed: false };
        return { getId: function () { return fid; } };
      },
    };
    return f;
  }
  window.DriveApp = {
    createFolder: function (n) { var id = nid('fld'); MOCK.folders[id] = makeFolder(id, n); return MOCK.folders[id]; },
    getFolderById: function (id) { if (!MOCK.folders[id]) throw new Error('No folder ' + id); return MOCK.folders[id]; },
    getFileById: function (id) {
      var f = MOCK.files[id]; if (!f) throw new Error('No file ' + id);
      return { getBlob: function () { return f.blob; }, setTrashed: function (t) { f.trashed = t; } };
    },
  };

  // ---------- Sheets ----------
  function makeSheet(name) {
    var rows = [];
    var sh = {
      rows: rows,
      getName: function () { return name; },
      getDataRange: function () { return { getValues: function () { return rows.map(function (r) { return r.slice(); }); } }; },
      appendRow: function (arr) { rows.push(arr.map(store)); },
      deleteRow: function (n) { rows.splice(n - 1, 1); },
      setFrozenRows: function () {},
      getRange: function (r, c, nr, nc) {
        var range = {
          setNumberFormat: function () { return range; },
          clearContent: function () { rows.splice(r - 1, nr); return range; }, // rows left empty at the end are not data, as in Sheets
          setFontWeight: function () { return range; },
          setValues: function (vals) {
            for (var i = 0; i < vals.length; i++) {
              while (rows.length < r + i) rows.push([]);
              for (var j = 0; j < vals[i].length; j++) rows[r - 1 + i][c - 1 + j] = store(vals[i][j]);
            }
            return range;
          },
        };
        return range;
      },
    };
    return sh;
  }
  // Sheets treats a leading apostrophe as "store as text" and does not keep it.
  function store(v) { var s = v == null ? '' : String(v); return s.charAt(0) === "'" ? s.slice(1) : s; }
  function makeSpreadsheet(name) {
    var id = nid('ss'), sheets = [makeSheet('Sheet1')];
    var ss = {
      sheets: sheets,
      getId: function () { return id; }, getUrl: function () { return 'https://sheets.test/' + id; },
      getSheetByName: function (n) { return sheets.filter(function (s) { return s.getName() === n; })[0] || null; },
      insertSheet: function (n) { var s = makeSheet(n); sheets.push(s); return s; },
      getSheets: function () { return sheets.slice(); },
      deleteSheet: function (s) { var i = sheets.indexOf(s); if (i >= 0) sheets.splice(i, 1); },
    };
    MOCK.spreadsheets[id] = ss;
    return ss;
  }
  window.SpreadsheetApp = {
    create: function (n) { return makeSpreadsheet(n); },
    openById: function (id) { if (!MOCK.spreadsheets[id]) throw new Error('No spreadsheet ' + id); return MOCK.spreadsheets[id]; },
  };

  // ---------- Mail ----------
  window.MailApp = {
    sendEmail: function (o) { if (MOCK.mailQuota < 1) throw new Error('quota'); MOCK.mailQuota--; MOCK.outbox.push(o); },
    getRemainingDailyQuota: function () { return MOCK.mailQuota; },
  };

  // ---------- UrlFetch (Claude) ----------
  window.UrlFetchApp = { fetch: function (url, opts) {
    var body = JSON.parse(opts.payload);
    MOCK.fetches.push({ url: url, headers: opts.headers, body: body });
    var res = MOCK.claude ? MOCK.claude(body) : { status: 200, json: { stop_reason: 'end_turn', content: [{ type: 'text', text: '{"reply":"תודה!","sameClaim":true,"summary":"סיכום","category":"general"}' }] } };
    return { getResponseCode: function () { return res.status; }, getContentText: function () { return JSON.stringify(res.json); } };
  } };

  window.ContentService = { MimeType: { JSON: 'json' }, createTextOutput: function (s) {
    var o = { content: s, setMimeType: function () { return o; }, getContent: function () { return s; } }; return o;
  } };

  /**
   * The personal sender (apps-script-sender/Code.gs, loaded by run-tests.ps1 as window.SENDER_SOURCE) running as `email`,
   * with its own Gmail quota, sent mail, user properties and triggers. Its calls to the app go straight to the real doPost.
   */
  MOCK.makeSender = function (email) {
    var env = { email: email, props: {}, triggers: [], sent: [], quota: 100, down: false, calls: [] };
    var svc = {
      MailApp: {
        sendEmail: function (o) { if (env.quota < 1) throw new Error('Service invoked too many times for one day: email.'); env.quota--; env.sent.push(o); },
        getRemainingDailyQuota: function () { return env.quota; },
      },
      UrlFetchApp: { fetch: function (url, opts) {
        var req = JSON.parse(opts.payload); env.calls.push({ url: url, op: req.op });
        if (env.down) return { getResponseCode: function () { return 500; }, getContentText: function () { return 'error'; } };
        var out = MOCK.call('doPost', { postData: { contents: opts.payload } });
        return { getResponseCode: function () { return 200; }, getContentText: function () { return out.content; } };
      } },
      Session: {
        getActiveUser: function () { return { getEmail: function () { return env.email; } }; },
        getEffectiveUser: function () { return { getEmail: function () { return env.email; } }; },
      },
      PropertiesService: (function () {
        function store(o) {
          return {
            getProperty: function (k) { return Object.prototype.hasOwnProperty.call(o, k) ? o[k] : null; },
            setProperty: function (k, v) { o[k] = String(v); }, deleteProperty: function (k) { delete o[k]; },
          };
        }
        env.scriptProps = {}; // the sender project's Script properties (shared by every user of the sender)
        return { getUserProperties: function () { return store(env.props); }, getScriptProperties: function () { return store(env.scriptProps); } };
      })(),
      ScriptApp: {
        getProjectTriggers: function () { return env.triggers.slice(); },
        newTrigger: function (fn) { return { timeBased: function () { return { everyMinutes: function (n) { return { create: function () {
          var t = { fn: fn, every: n, getHandlerFunction: function () { return fn; } }; env.triggers.push(t); return t;
        } }; } }; } }; },
        deleteTrigger: function (t) { env.triggers.splice(env.triggers.indexOf(t), 1); },
      },
      HtmlService: { createHtmlOutput: function (html) { var o = { html: html, setTitle: function () { return o; }, addMetaTag: function () { return o; } }; return o; } },
      LockService: { getUserLock: function () { return { tryLock: function () { return true; }, releaseLock: function () {} }; } },
    };
    var names = Object.keys(svc);
    var make = new Function(names.join(','), window.SENDER_SOURCE + '\nreturn { doGet: doGet, tick: tick, disconnect: disconnect, connectFromEditor: connectFromEditor, MAIN_URL: MAIN_URL, EVERY_MINUTES: EVERY_MINUTES };');
    env.app = make.apply(null, names.map(function (k) { return svc[k]; }));
    /** Opens the sender page, as the browser would (optionally with the ticket from the app). Returns the page HTML. */
    env.open = function (url) {
      var m = /[?&]ticket=([^&]+)/.exec(url || '');
      return env.app.doGet({ parameter: m ? { ticket: m[1] } : {} }).html;
    };
    return env;
  };

  /** Fresh "execution": Apps Script resets globals between calls, so clear Code.gs's per-run caches. */
  MOCK.newExecution = function () {
    try { _ss = null; } catch (e) {}
    try { _props = null; _url = null; } catch (e) {}
    try { Object.keys(_tables).forEach(function (k) { delete _tables[k]; }); } catch (e) {}
  };
  /** Calls a server function the way google.script.run would: JSON in, JSON out, errors as messages. */
  MOCK.call = function (fn) {
    var args = JSON.parse(JSON.stringify(Array.prototype.slice.call(arguments, 1)));
    MOCK.newExecution();
    var out = window[fn].apply(null, args);
    return out === undefined ? undefined : JSON.parse(JSON.stringify(out));
  };
  /** Claude reply helper for tests. */
  MOCK.claudeText = function (text) { return { status: 200, json: { stop_reason: 'end_turn', content: [{ type: 'thinking', thinking: '' }, { type: 'text', text: text }] } }; };
})();
