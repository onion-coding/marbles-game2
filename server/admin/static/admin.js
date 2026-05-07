// admin.js — vanilla JS admin panel
// Fetches JSON from /admin/* endpoints and renders into the 4-tab UI.
// No build step, no framework, no dependencies.

(function () {
  'use strict';

  // ── Tab switching ────────────────────────────────────────────────────────

  function initTabs() {
    document.querySelectorAll('.tab-btn').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var target = btn.dataset.tab;
        document.querySelectorAll('.tab-btn').forEach(function (b) { b.classList.remove('active'); });
        document.querySelectorAll('.pane').forEach(function (p) { p.classList.remove('active'); });
        btn.classList.add('active');
        var pane = document.getElementById('pane-' + target);
        if (pane) pane.classList.add('active');
        if (target === 'rounds')  loadRounds();
        if (target === 'wallets') loadWallets();
        if (target === 'config')  loadConfig();
        if (target === 'audit')   loadAudit(0);
      });
    });
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  function apiJSON(method, path, body) {
    var opts = { method: method, headers: { 'Content-Type': 'application/json' } };
    if (body !== undefined) opts.body = JSON.stringify(body);
    return fetch(path, opts).then(function (r) {
      return r.json().then(function (data) {
        if (!r.ok) throw new Error(data.error || r.statusText);
        return data;
      });
    });
  }

  function flash(el, msg, ok) {
    el.innerHTML = '<div class="flash ' + (ok ? 'flash-ok' : 'flash-err') + '">' + esc(msg) + '</div>';
    setTimeout(function () { el.innerHTML = ''; }, 4000);
  }

  function esc(s) {
    return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  function fmtTime(iso) {
    if (!iso) return '-';
    var d = new Date(iso);
    return d.toISOString().replace('T', ' ').replace(/\.\d+Z$/, ' UTC');
  }

  // ── Rounds tab ───────────────────────────────────────────────────────────

  function loadRounds() {
    apiJSON('GET', '/admin/rounds').then(function (d) {
      document.getElementById('rounds-pending').textContent = d.pending_round_count;
      var statusEl = document.getElementById('rounds-status');
      statusEl.innerHTML = d.paused
        ? '<span class="badge badge-paused">Paused</span>'
        : '<span class="badge badge-ok">Running</span>';
      document.getElementById('btn-pause').disabled  = d.paused;
      document.getElementById('btn-resume').disabled = !d.paused;
    }).catch(function (e) {
      document.getElementById('rounds-flash').innerHTML =
        '<div class="flash flash-err">' + esc(e.message) + '</div>';
    });
  }

  function initRounds() {
    document.getElementById('btn-pause').addEventListener('click', function () {
      apiJSON('POST', '/admin/rounds/pause').then(function () {
        flash(document.getElementById('rounds-flash'), 'Game paused. New rounds will return 503.', true);
        loadRounds();
      }).catch(function (e) { flash(document.getElementById('rounds-flash'), e.message, false); });
    });

    document.getElementById('btn-resume').addEventListener('click', function () {
      apiJSON('POST', '/admin/rounds/resume').then(function () {
        flash(document.getElementById('rounds-flash'), 'Game resumed.', true);
        loadRounds();
      }).catch(function (e) { flash(document.getElementById('rounds-flash'), e.message, false); });
    });
  }

  // ── Wallets tab ──────────────────────────────────────────────────────────

  function loadWallets() {
    apiJSON('GET', '/admin/wallets').then(function (list) {
      var tbody = document.getElementById('wallets-tbody');
      if (!list || list.length === 0) {
        tbody.innerHTML = '<tr><td colspan="3" style="color:var(--muted)">No players found</td></tr>';
        return;
      }
      tbody.innerHTML = list.map(function (p) {
        return '<tr>' +
          '<td class="mono">' + esc(p.player_id) + '</td>' +
          '<td>' + p.balance.toFixed(2) + '</td>' +
          '<td>' +
            '<button class="btn btn-success" style="margin-right:4px" ' +
              'onclick="adminCreditDebit(\'' + esc(p.player_id) + '\',\'credit\')">Credit</button>' +
            '<button class="btn btn-danger" ' +
              'onclick="adminCreditDebit(\'' + esc(p.player_id) + '\',\'debit\')">Debit</button>' +
          '</td>' +
        '</tr>';
      }).join('');
    }).catch(function (e) {
      document.getElementById('wallets-flash').innerHTML =
        '<div class="flash flash-err">' + esc(e.message) + '</div>';
    });
  }

  // Exposed globally so inline onclick can reach it.
  window.adminCreditDebit = function (playerID, op) {
    var amountStr = prompt('Amount in cents (integer) to ' + op + ' for ' + playerID + ':');
    if (!amountStr) return;
    var amount = parseInt(amountStr, 10);
    if (isNaN(amount) || amount <= 0) { alert('Enter a positive integer.'); return; }
    var reason = prompt('Reason (optional):') || '';
    apiJSON('POST', '/admin/wallets/' + encodeURIComponent(playerID) + '/' + op,
      { amount: amount, reason: reason }
    ).then(function (d) {
      flash(document.getElementById('wallets-flash'),
        op + ' OK — new balance: ' + d.balance.toFixed(2), true);
      loadWallets();
    }).catch(function (e) {
      flash(document.getElementById('wallets-flash'), e.message, false);
    });
  };

  // ── Config tab ───────────────────────────────────────────────────────────

  function loadConfig() {
    apiJSON('GET', '/admin/config').then(function (cfg) {
      document.getElementById('cfg-rtp').textContent     = cfg.rtp_bps;
      document.getElementById('cfg-buyin').textContent   = cfg.buy_in;
      document.getElementById('cfg-marbles').textContent = cfg.max_marbles;
      document.getElementById('cfg-tracks').textContent  = (cfg.track_pool || []).join(', ');
      document.getElementById('cfg-paused').innerHTML    = cfg.paused
        ? '<span class="badge badge-paused">Paused</span>'
        : '<span class="badge badge-ok">Running</span>';
      document.getElementById('rtp-input').value = cfg.rtp_bps;
    }).catch(function (e) {
      flash(document.getElementById('config-flash'), e.message, false);
    });
  }

  function initConfig() {
    document.getElementById('btn-set-rtp').addEventListener('click', function () {
      var val = parseInt(document.getElementById('rtp-input').value, 10);
      if (isNaN(val) || val < 1 || val > 10000) {
        flash(document.getElementById('config-flash'), 'rtp_bps must be 1–10000', false);
        return;
      }
      apiJSON('POST', '/admin/config/rtp-bps', { rtp_bps: val }).then(function (cfg) {
        flash(document.getElementById('config-flash'),
          'RTP updated to ' + cfg.rtp_bps + ' bps (' + (cfg.rtp_bps / 100).toFixed(2) + '%)', true);
        loadConfig();
      }).catch(function (e) { flash(document.getElementById('config-flash'), e.message, false); });
    });
  }

  // ── Audit tab ────────────────────────────────────────────────────────────

  var auditOffset = 0;
  var auditLimit  = 50;

  function loadAudit(offset) {
    auditOffset = offset;
    apiJSON('GET', '/admin/audit?offset=' + offset + '&limit=' + auditLimit).then(function (data) {
      var container = document.getElementById('audit-list');
      if (!data.events || data.events.length === 0) {
        container.innerHTML = '<p style="color:var(--muted)">No audit events yet.</p>';
      } else {
        container.innerHTML = data.events.map(function (ev) {
          return '<div class="audit-entry">' +
            '<span class="ts">'     + esc(fmtTime(ev.timestamp)) + '</span>' +
            '<span class="actor">'  + esc(ev.actor || '-') + '</span>' +
            '<span class="action">' + esc(ev.action || '-') + '</span>' +
            '<span class="details">' + esc((ev.target ? ev.target + ' — ' : '') + (ev.details || '')) + '</span>' +
          '</div>';
        }).join('');
      }
      // Pagination controls.
      var pgEl = document.getElementById('audit-pagination');
      var total = data.total || 0;
      var hasPrev = offset > 0;
      var hasNext = offset + auditLimit < total;
      pgEl.innerHTML =
        '<button class="btn btn-muted" ' + (hasPrev ? '' : 'disabled') + ' id="audit-prev">Prev</button>' +
        '<span>' + (offset + 1) + '–' + Math.min(offset + auditLimit, total) + ' of ' + total + '</span>' +
        '<button class="btn btn-muted" ' + (hasNext ? '' : 'disabled') + ' id="audit-next">Next</button>';
      if (hasPrev) document.getElementById('audit-prev').onclick = function () { loadAudit(offset - auditLimit); };
      if (hasNext) document.getElementById('audit-next').onclick = function () { loadAudit(offset + auditLimit); };
    }).catch(function (e) {
      document.getElementById('audit-list').innerHTML =
        '<div class="flash flash-err">' + esc(e.message) + '</div>';
    });
  }

  // ── Boot ─────────────────────────────────────────────────────────────────

  document.addEventListener('DOMContentLoaded', function () {
    initTabs();
    initRounds();
    initConfig();
    // Activate the first tab (Rounds) by default.
    var first = document.querySelector('.tab-btn[data-tab="rounds"]');
    if (first) first.click();
    // Auto-refresh rounds status every 10 s.
    setInterval(function () {
      var active = document.querySelector('.tab-btn.active');
      if (active && active.dataset.tab === 'rounds') loadRounds();
    }, 10000);
  });

}());
