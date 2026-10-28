/* Minimal test runner: test(group, name, fn). Results are written into #results as JSON for run-tests.ps1. */
(function () {
  'use strict';
  var tests = [];
  window.test = function (group, name, fn) { tests.push({ group: group, name: name, fn: fn }); };

  function fmt(v) { try { return JSON.stringify(v); } catch (e) { return String(v); } }
  window.assert = {
    ok: function (v, msg) { if (!v) throw new Error(msg || 'expected truthy, got ' + fmt(v)); },
    equal: function (a, b, msg) { if (a !== b) throw new Error((msg ? msg + ': ' : '') + 'expected ' + fmt(b) + ', got ' + fmt(a)); },
    includes: function (hay, needle, msg) { if (String(hay).indexOf(needle) < 0) throw new Error((msg ? msg + ': ' : '') + fmt(needle) + ' not found in ' + fmt(String(hay).slice(0, 300))); },
    notIncludes: function (hay, needle, msg) { if (String(hay).indexOf(needle) >= 0) throw new Error((msg ? msg + ': ' : '') + fmt(needle) + ' should not appear'); },
    throws: function (fn, pattern, msg) {
      try { fn(); } catch (e) { if (pattern && !String(e.message).match(pattern)) throw new Error((msg ? msg + ': ' : '') + 'wrong error: ' + e.message); return e; }
      throw new Error((msg ? msg + ': ' : '') + 'expected an error');
    },
  };
  window.sleep = function (ms) { return new Promise(function (r) { setTimeout(r, ms); }); };
  window.waitFor = function (pred, what, timeout) {
    var start = Date.now(); timeout = timeout || 8000;
    return new Promise(function (resolve, reject) {
      (function poll() {
        var v; try { v = pred(); } catch (e) { v = null; }
        if (v) return resolve(v);
        if (Date.now() - start > timeout) return reject(new Error('timed out waiting for ' + (what || 'condition')));
        setTimeout(poll, 25);
      })();
    });
  };

  window.runAllTests = async function () {
    var results = [];
    for (var i = 0; i < tests.length; i++) {
      var t = tests[i], started = Date.now();
      try { await t.fn(); results.push({ group: t.group, name: t.name, ok: true, ms: Date.now() - started }); }
      catch (e) { results.push({ group: t.group, name: t.name, ok: false, error: String(e && e.message || e), ms: Date.now() - started }); }
    }
    var out = document.getElementById('results');
    out.textContent = JSON.stringify(results);
    out.setAttribute('data-done', '1');
  };
})();
