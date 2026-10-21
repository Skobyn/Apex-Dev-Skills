// Apex Console — single-page admin UI over apex-scope-loop, apex-dispatch and apex-decision-layer.
// Contract: ../docs/api.md. No libraries, no innerHTML with data, no inline handlers (CSP-safe).

const DEMO = new URLSearchParams(location.search).get('demo') === '1';
const NS = 'apex-console.';

// ---------------------------------------------------------------- storage --
const store = {
  get(k, fallback) {
    try { const v = localStorage.getItem(NS + k); return v === null ? fallback : v; } catch { return fallback; }
  },
  set(k, v) {
    try { localStorage.setItem(NS + k, v); } catch { /* storage unavailable: ignore */ }
  },
};

// ------------------------------------------------------------------- DOM --
function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  setAttrs(el, attrs);
  append(el, kids);
  return el;
}
const SVGNS = 'http://www.w3.org/2000/svg';
function s(tag, attrs, ...kids) {
  const el = document.createElementNS(SVGNS, tag);
  setAttrs(el, attrs);
  append(el, kids);
  return el;
}
function setAttrs(el, attrs) {
  if (!attrs) return;
  for (const [k, v] of Object.entries(attrs)) {
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') el.setAttribute('class', Array.isArray(v) ? v.filter(Boolean).join(' ') : v);
    else if (k === 'text') el.textContent = v;
    else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2).toLowerCase(), v);
    else if (k === 'value' && 'value' in el) el.value = v;
    else if (k === 'checked' || k === 'disabled' || k === 'selected' || k === 'open' || k === 'hidden') el[k] = !!v;
    else el.setAttribute(k, v === true ? '' : String(v));
  }
}
function append(el, kids) {
  for (const k of kids.flat(Infinity)) {
    if (k === null || k === undefined || k === false) continue;
    el.append(k instanceof Node ? k : document.createTextNode(String(k)));
  }
}
function clear(el) { while (el.firstChild) el.firstChild.remove(); }
const clone = (o) => JSON.parse(JSON.stringify(o));
let uid = 0;
const nextId = (p = 'id') => `${p}-${++uid}`;

// --------------------------------------------------------------- format --
const nf = (d = 0, min = 0) => new Intl.NumberFormat('en-US', { maximumFractionDigits: d, minimumFractionDigits: min });
function fmtNum(v, d = 1) {
  if (v === null || v === undefined || Number.isNaN(v)) return '—';
  return nf(d).format(v);
}
function fmtCompact(v) {
  if (v === null || v === undefined) return '—';
  const a = Math.abs(v);
  if (a >= 1e6) return nf(a >= 1e7 ? 0 : 1).format(v / 1e6) + 'M';
  if (a >= 1e3) return nf(a >= 1e4 ? 0 : 1).format(v / 1e3) + 'k';
  return nf(a < 10 ? 2 : 1).format(v);
}
function fmtUSD(v, d) {
  if (v === null || v === undefined) return '—';
  const digits = d ?? (Math.abs(v) >= 1000 ? 0 : 2);
  return '$' + nf(digits, digits).format(v);
}
function fmtPct(v, d = 0) {
  if (v === null || v === undefined) return '—';
  const x = v * 100;
  return nf(Math.abs(x) < 10 && x % 1 ? 1 : d).format(x) + '%';
}
function isUSD(unit) { return /^usd$/i.test(unit || ''); }
function fmtUnit(v, unit) {
  if (v === null || v === undefined) return '—';
  const u = (unit || '').toLowerCase();
  if (u === 'ratio') return fmtPct(v);
  if (u === 'hours') return fmtNum(v, v < 10 ? 1 : 0) + ' h';
  if (isUSD(u)) return fmtUSD(v);
  if (u === 'count') return fmtNum(v, 0);
  return fmtNum(v, Math.abs(v) < 10 ? 2 : 1);
}
function unitSuffix(unit) {
  const u = (unit || '').toLowerCase();
  if (u === 'ratio' || u === 'hours' || isUSD(u) || u === 'count' || !u) return '';
  return unit;
}
function fmtTime(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString('en-US', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false });
}
function fmtDay(iso) {
  const d = new Date(iso.length === 10 ? iso + 'T00:00:00Z' : iso);
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' });
}
function rel(iso) {
  if (!iso) return '—';
  const t = new Date(iso).getTime();
  if (Number.isNaN(t)) return iso;
  const sec = Math.round((Date.now() - t) / 1000);
  const abs = Math.abs(sec);
  const fmt = (n, u) => `${n} ${u}${n === 1 ? '' : 's'}`;
  let out;
  if (abs < 45) out = 'just now';
  else if (abs < 3600) out = fmt(Math.round(abs / 60), 'min');
  else if (abs < 86400) out = fmt(Math.round(abs / 3600), 'hour');
  else if (abs < 86400 * 14) out = fmt(Math.round(abs / 86400), 'day');
  else return fmtTime(iso);
  if (out === 'just now') return out;
  return sec >= 0 ? out + ' ago' : 'in ' + out;
}
function timeEl(iso, mode = 'rel') {
  if (!iso) return h('span', { class: 'muted', text: '—' });
  return h('time', { datetime: iso, title: new Date(iso).toUTCString(), text: mode === 'rel' ? rel(iso) : fmtTime(iso) });
}

// -------------------------------------------------------------- toasts --
function toast(msg, { action, error, timeout } = {}) {
  const host = document.getElementById('toasts');
  const t = h('div', { class: ['toast', error && 'err'] }, h('span', { text: msg }));
  let timer;
  const close = () => { clearTimeout(timer); t.remove(); };
  if (action) {
    t.append(h('button', { class: 'btn btn-sm', type: 'button', text: action.label, onclick: async () => { close(); await action.run(); } }));
  }
  t.append(h('button', { class: 'x-btn', type: 'button', 'aria-label': 'Dismiss', text: '×', onclick: close }));
  host.append(t);
  timer = setTimeout(close, timeout ?? (action ? 9000 : 5000));
}
function notifySaved(msg, undoId, after) {
  const text = DEMO ? `Demo mode: not saved. ${msg}` : msg;
  toast(text, undoId ? { action: { label: 'Undo', run: () => undoAudit(undoId, after) } } : {});
}
function toastError(e) {
  const extra = e && e.errors && e.errors.length ? ' ' + e.errors.join(' ') : '';
  toast((e && e.message ? e.message : String(e)) + extra, { error: true, timeout: 8000 });
}

// ----------------------------------------------------------------- API --
let demoData = null;
async function loadDemo() {
  if (!demoData) {
    const r = await fetch('demo.json', { cache: 'no-store' });
    if (!r.ok) throw new Error('Could not load demo.json.');
    demoData = await r.json();
  }
  return demoData;
}
async function handle(r) {
  let body = null;
  try { body = await r.json(); } catch { /* not JSON */ }
  if (!r.ok || (body && body.ok === false)) {
    let msg = body && body.error;
    if (!msg) msg = r.status === 401 || r.status === 403
      ? 'Not signed in. Open the link the console printed when it started (it ends in ?t=…).'
      : `Request failed (HTTP ${r.status}).`;
    const e = new Error(msg);
    e.errors = (body && body.errors) || [];
    e.status = r.status;
    throw e;
  }
  return body;
}
async function apiGet(path) {
  if (DEMO) return demoGet(path);
  const r = await fetch(path, { credentials: 'same-origin', headers: { Accept: 'application/json' }, cache: 'no-store' });
  return handle(r);
}
async function apiPost(path, body) {
  if (DEMO) return demoPost(path, body);
  const r = await fetch(path, {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', 'X-Apex-Console': '1', Accept: 'application/json' },
    body: JSON.stringify(body),
  });
  return handle(r);
}

// --- demo mode: GETs come from demo.json, POSTs are simulated and never saved
async function demoGet(path) {
  const d = await loadDemo();
  const [p, qs] = path.split('?');
  const q = new URLSearchParams(qs || '');
  switch (p) {
    case '/api/state': return clone(d.state);
    case '/api/metrics': {
      const m = clone(d.metrics);
      m.repo = q.get('repo') || 'all';
      m.days = Number(q.get('days') || 28);
      if (m.repo !== 'all' || m.days !== 28) m.notes = [...(m.notes || []), 'Demo data does not change with the repo or window filter.'];
      return m;
    }
    case '/api/progress': return clone(d.progress);
    case '/api/knobs': {
      const k = clone(d.knobs);
      const repo = q.get('repo') || k.repo;
      if (repo !== k.repo) {
        k.repo = repo;
        const pr = d.progress.repos.find((x) => x.id === repo);
        k.active_lock = pr ? clone(pr.lock) : null;
      }
      return k;
    }
    case '/api/keys': return clone(d.keys);
    case '/api/audit': return clone(d.audit);
    default: throw new Error(`Demo mode has no data for ${p}.`);
  }
}
function flatten(obj, prefix = '', out = {}) {
  for (const [k, v] of Object.entries(obj || {})) {
    const key = prefix ? `${prefix}.${k}` : k;
    if (v && typeof v === 'object' && !Array.isArray(v)) flatten(v, key, out);
    else out[key] = v;
  }
  return out;
}
function currentFlat(plugin, knobs) {
  if (plugin === 'scope-loop') return flatten(knobs.scope_loop.effective);
  if (plugin === 'decision') return flatten(knobs.decision.config);
  const providers = {};
  for (const p of knobs.dispatch.providers) {
    providers[p.id] = { enabled: p.enabled, reviewer: p.roles_allowed.includes('reviewer'), min_acceptance: p.min_acceptance };
  }
  return flatten({ providers, escalation: knobs.dispatch.escalation });
}
function localDiff(plugin, patch, knobs) {
  const cur = currentFlat(plugin, knobs);
  const next = flatten(patch);
  const changes = [];
  for (const [k, v] of Object.entries(next)) {
    const from = k in cur ? cur[k] : null;
    if (JSON.stringify(from) !== JSON.stringify(v)) changes.push({ key: k, from, to: v });
  }
  return changes;
}
let demoSeq = 0;
async function demoPost(path, body) {
  const d = await loadDemo();
  const auditId = `a-demo-${String(++demoSeq).padStart(4, '0')}`;
  switch (path) {
    case '/api/knobs/preview':
    case '/api/knobs': {
      const knobs = await demoGet(`/api/knobs?repo=${encodeURIComponent(body.repo)}`);
      const changes = localDiff(body.plugin, body.patch, knobs);
      const warnings = [];
      if (knobs.active_lock) warnings.push(`A task is running (line ${knobs.active_lock.line}, ${knobs.active_lock.stage}); these changes apply from its next check.`);
      if (body.plugin === 'decision' && body.patch.egress === 'hosted') warnings.push('Hosted egress sends task state to a model provider.');
      if (body.plugin === 'scope-loop' && body.patch.tiers && body.patch.tiers.exempt) warnings.push('Exemptions loosen Tier C: matching paths no longer trigger it by path or content.');
      return { ok: true, changes, warnings, audit_id: path === '/api/knobs' ? auditId : null };
    }
    case '/api/tiers/simulate': {
      const tiers = body.patch || {};
      const knobs = await demoGet(`/api/knobs?repo=${encodeURIComponent(body.repo)}`);
      const all = (tiers.exempt || []).find((e) => /^[*/]*$/.test(String(e.glob ?? '').trim()));
      if (all) {
        const e = new Error('The proposal was refused (HTTP 422).');
        e.status = 422;
        e.errors = [`tiers.exempt: "${all.glob}" matches every path, so it would turn off Tier C. Use a narrower glob.`];
        throw e;
      }
      await new Promise((r) => setTimeout(r, 1800));
      const sim = clone(d.tiersim);
      const limit = Math.max(1, Math.min(60, Number(body.limit) || 30));
      sim.repo = body.repo;
      sim.tasks = sim.tasks.sort((a, b) => String(b.completed_at).localeCompare(String(a.completed_at))).slice(0, limit);
      sim.summary = { ...summarizeSim(sim.tasks), note: sim.summary.note };
      sim.changes = localDiff('scope-loop', { tiers }, knobs);
      return sim;
    }
    case '/api/audit/undo': return { ok: true, changes: [], warnings: [], audit_id: auditId };
    case '/api/keys': return { ok: true, audit_id: auditId };
    case '/api/keys/check': {
      const checks = d.keys.keys.map((k) => {
        if (k.set && k.in_console_env) return { name: k.name, status: 'ok', detail: body.probe ? 'Set; probe simulated in demo mode.' : 'Set and visible to this console.' };
        if (k.set) return { name: k.name, status: 'warn', detail: "Set in the keys file but not in this console's environment. Restart the shell or the console." };
        if (k.needed) return { name: k.name, status: 'fail', detail: 'Needed by an enabled provider or backend, and not set.' };
        return { name: k.name, status: 'skipped', detail: 'Not set and not needed.' };
      });
      return { ok: true, checks };
    }
    case '/api/halt': return { ok: true, audit_id: auditId };
    case '/api/targets': return { ok: true };
    case '/api/repos': return clone(d.state);
    default: throw new Error(`Demo mode cannot simulate ${path}.`);
  }
}

function summarizeSim(tasks) {
  const ok = tasks.filter((t) => !t.error);
  const moves = {};
  let looser = 0;
  let stricter = 0;
  for (const t of ok) {
    if (!t.move) continue;
    moves[t.move] = (moves[t.move] || 0) + 1;
    if (TIER_RANK[t.proposed] < TIER_RANK[t.current]) looser++; else stricter++;
  }
  const mix = (k) => Object.fromEntries(['A', 'B', 'C'].map((x) => [x, ok.filter((t) => t[k] === x).length]));
  return {
    replayed: ok.length, errors: tasks.length - ok.length, changed: looser + stricter, looser, stricter,
    moves, mix_current: mix('current'), mix_proposed: mix('proposed'),
  };
}

async function undoAudit(id, after) {
  try {
    const res = await apiPost('/api/audit/undo', { id });
    notifySaved(`Undone ${id}. Logged as ${res.audit_id || 'a new entry'}.`);
    if (after) await after();
    else if (ui.tab === 'audit') renderView();
  } catch (e) { toastError(e); }
}

// ------------------------------------------------------------- dialogs --
const FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';
function openDialog({ title, lede, body, actions = [], drawer = false, onClose, initialFocus }) {
  const titleId = nextId('dlg-title');
  const bodyEl = h('div', { class: 'dlg-body' });
  const footEl = h('div', { class: 'dlg-foot' });
  const dlg = h('dialog', { class: drawer ? 'drawer' : null, 'aria-labelledby': titleId, 'aria-modal': 'true' },
    h('div', { class: 'dlg' },
      h('div', { class: 'dlg-head' },
        h('div', { class: 'stack' }, h('h2', { id: titleId, text: title }), lede ? h('p', { class: 'small', text: lede }) : null),
        h('button', { class: 'x-btn', type: 'button', 'aria-label': 'Close', text: '×', onclick: () => dlg.close() })),
      bodyEl, footEl));
  const api = {
    dlg,
    close: () => dlg.close(),
    setBody(...nodes) { clear(bodyEl); append(bodyEl, nodes); },
    setActions(list) {
      clear(footEl);
      for (const a of list) {
        const b = h('button', {
          type: 'button',
          class: ['btn', a.kind === 'primary' && 'btn-primary', a.kind === 'danger' && 'btn-danger'],
          text: a.label,
          disabled: a.disabled,
        });
        b.addEventListener('click', async () => {
          if (!a.onClick) { dlg.close(); return; }
          const btns = [...footEl.querySelectorAll('button')];
          btns.forEach((x) => { x.disabled = true; });
          try { await a.onClick(api); } finally { btns.forEach((x) => { if (x.isConnected) x.disabled = false; }); }
        });
        if (a.ref) a.ref(b);
        footEl.append(b);
      }
    },
  };
  if (body) api.setBody(body);
  api.setActions(actions);
  const prev = document.activeElement;
  dlg.addEventListener('keydown', (e) => {
    if (e.key !== 'Tab') return;
    const f = [...dlg.querySelectorAll(FOCUSABLE)].filter((x) => x.offsetParent !== null);
    if (!f.length) return;
    const first = f[0];
    const last = f[f.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  });
  dlg.addEventListener('close', () => {
    dlg.remove();
    if (prev && prev.isConnected && prev.focus) prev.focus();
    if (onClose) onClose();
  });
  document.body.append(dlg);
  dlg.showModal();
  const target = initialFocus ? dlg.querySelector(initialFocus) : null;
  (target || dlg.querySelector('.dlg-body ' + FOCUSABLE.split(',')[0]) || dlg.querySelector('.x-btn')).focus();
  return api;
}
function confirmDialog({ title, lede, body, confirmLabel, kind = 'primary' }) {
  return new Promise((resolve) => {
    let done = false;
    openDialog({
      title, lede, body,
      actions: [
        { label: 'Cancel' },
        { label: confirmLabel, kind, onClick: (d) => { done = true; d.close(); } },
      ],
      onClose: () => resolve(done),
    });
  });
}

// ------------------------------------------------------------- widgets --
function seg(options, current, onPick, label) {
  const g = h('div', { class: 'seg', role: 'group', 'aria-label': label });
  for (const o of options) {
    g.append(h('button', {
      type: 'button', text: o.label, 'aria-pressed': String(o.value === current),
      onclick: () => onPick(o.value),
    }));
  }
  return g;
}
function switchEl({ checked, label, disabled, onChange, showText = true }) {
  const input = h('input', { type: 'checkbox', role: 'switch', checked, disabled, 'aria-label': label });
  const txt = h('span', { class: 'switch-text', text: checked ? 'On' : 'Off' });
  input.addEventListener('change', () => { txt.textContent = input.checked ? 'On' : 'Off'; onChange(input.checked); });
  return h('label', { class: 'switch' }, input, h('span', { class: 'track', 'aria-hidden': 'true' }), showText ? txt : null);
}
const STATUS = {
  good: { g: '✓', label: 'On target' },
  watch: { g: '◐', label: 'Watch' },
  off: { g: '✕', label: 'Off target' },
  none: { g: '—', label: 'No target' },
};
function statusEl(kind, label) {
  const st = STATUS[kind] || STATUS.none;
  return h('span', { class: ['status', `st-${kind in STATUS ? kind : 'none'}`] },
    h('span', { class: 'g', 'aria-hidden': 'true', text: st.g }), label || st.label);
}
function okEl(ok, yes, no) {
  return h('span', { class: ['status', ok ? 'st-good' : 'st-off'] }, h('span', { class: 'g', 'aria-hidden': 'true', text: ok ? '✓' : '✕' }), ok ? yes : no);
}
function deltaEl(value, prev, goodWhenUp) {
  if (value === null || value === undefined || prev === null || prev === undefined || prev === 0) {
    return h('span', { class: 'delta flat', text: prev === 0 && value ? 'new' : 'no prior' });
  }
  const pct = (value - prev) / Math.abs(prev);
  if (Math.abs(pct) < 0.005) return h('span', { class: 'delta flat' }, h('span', { 'aria-hidden': 'true', text: '■' }), ' flat');
  const up = pct > 0;
  const good = up === goodWhenUp;
  return h('span', { class: ['delta', good ? 'good' : 'bad'], title: `previous: ${fmtNum(prev, 2)}` },
    h('span', { 'aria-hidden': 'true', text: up ? '▲' : '▼' }),
    `${nf(Math.abs(pct) < 0.1 ? 1 : 0).format(Math.abs(pct) * 100)}%`,
    h('span', { class: 'sr-only', text: ` ${up ? 'up' : 'down'} vs previous window, ${good ? 'better' : 'worse'}` }));
}
function tableWrap(headers, rows, opts = {}) {
  const thead = h('thead', null, h('tr', null, headers.map((c) => h('th', { scope: 'col', class: c.num ? 'num' : null, text: c.label ?? c }))));
  const tbody = h('tbody', null, rows);
  return h('div', { class: ['table-wrap', opts.class], tabindex: opts.focusable ? '0' : null, role: opts.focusable ? 'region' : null, 'aria-label': opts.label },
    h('table', null, opts.caption ? h('caption', { class: 'sr-only', text: opts.caption }) : null, thead, tbody));
}
function td(content, cls) { return h('td', { class: cls }, content); }
function errorCard(e, retry) {
  return h('div', { class: 'card err-card stack' },
    h('h2', { text: 'Could not load this view' }),
    h('p', { text: e.message || String(e) }),
    retry ? h('div', null, h('button', { class: 'btn', type: 'button', text: 'Try again', onclick: retry })) : null);
}
function chipsEditor({ items, label, placeholder, onChange, validate }) {
  const wrap = h('div', { class: 'stack' });
  const list = h('div', { class: 'editable-chips', role: 'list', 'aria-label': label });
  const input = h('input', { type: 'text', placeholder, 'aria-label': `Add to ${label}`, autocomplete: 'off', spellcheck: 'false' });
  const err = h('div', { class: 'field-error', 'aria-live': 'polite' });
  const draw = () => {
    clear(list);
    if (!items.length) list.append(h('span', { class: 'muted small', text: 'None' }));
    items.forEach((it, i) => {
      list.append(h('span', { class: 'chip', role: 'listitem' }, it,
        h('button', { class: 'chip-x', type: 'button', 'aria-label': `Remove ${it}`, text: '×', onclick: () => { items.splice(i, 1); draw(); onChange(); } })));
    });
  };
  const add = () => {
    const v = input.value.trim();
    err.textContent = '';
    if (!v) return;
    if (items.includes(v)) { err.textContent = `${v} is already in the list.`; return; }
    const problem = validate ? validate(v) : null;
    if (problem) { err.textContent = problem; return; }
    items.push(v); input.value = ''; draw(); onChange();
  };
  input.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); add(); } });
  draw();
  wrap.append(list, h('div', { class: 'chip-add' }, input, h('button', { class: 'btn btn-sm', type: 'button', text: 'Add', onclick: add })), err);
  return wrap;
}

// --------------------------------------------------------------- charts --
const CHART_H = 210;
function niceStep(raw) {
  const exp = Math.pow(10, Math.floor(Math.log10(raw)));
  const f = raw / exp;
  return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10) * exp;
}
function yScale(values, fixedMax) {
  if (fixedMax) return { max: fixedMax, ticks: [0, 0.25, 0.5, 0.75, 1].map((t) => t * fixedMax) };
  const max = Math.max(0, ...values.filter((v) => v !== null && v !== undefined));
  if (max <= 0) return { max: 1, ticks: [0, 0.5, 1] };
  const step = niceStep(max / 4);
  const top = Math.ceil(max / step) * step;
  const ticks = [];
  for (let t = 0; t <= top + step / 2; t += step) ticks.push(+t.toFixed(10));
  return { max: top, ticks };
}
function roundTopBar(x, y, w, hgt, r) {
  r = Math.max(0, Math.min(r, w / 2, hgt));
  return `M${x},${y + hgt}V${y + r}Q${x},${y} ${x + r},${y}H${x + w - r}Q${x + w},${y} ${x + w},${y + r}V${y + hgt}Z`;
}
function chartCard({ title, sub, kind, labels, values, fmt, axisFmt, fixedMax, colWide, events }) {
  const tableId = nextId('tbl');
  const box = h('div', { class: 'chart-box' });
  const toggle = h('button', { class: 'btn btn-sm', type: 'button', 'aria-pressed': 'false', 'aria-controls': tableId, text: 'Table' });
  const table = tableWrap(['Week', { label: title, num: true }],
    labels.map((l, i) => h('tr', null, td(`Week of ${fmtDay(l)}`), td(fmt(values[i]), 'num'))),
    { caption: title, class: 'chart-table' });
  table.id = tableId;
  table.hidden = true;
  toggle.addEventListener('click', () => {
    const on = toggle.getAttribute('aria-pressed') !== 'true';
    toggle.setAttribute('aria-pressed', String(on));
    toggle.textContent = on ? 'Chart' : 'Table';
    table.hidden = !on;
    box.hidden = on;
  });
  const card = h('section', { class: ['card', 'chart-card', colWide && 'wide'], 'aria-label': title },
    h('div', { class: 'chart-head' },
      h('div', null, h('h3', { text: title }), sub ? h('p', { class: 'chart-sub', text: sub }) : null),
      toggle),
    box, table);
  const draw = () => {
    if (box.hidden) return;
    const w = box.clientWidth;
    if (!w) return;
    clear(box);
    const present = values.filter((v) => v !== null && v !== undefined);
    if (!present.length) { box.append(h('div', { class: 'chart-empty', text: 'No data in this window.' })); return; }
    (kind === 'line' ? drawLine : drawBars)(box, w, { title, labels, values, fmt, axisFmt: axisFmt || fmt, fixedMax, events: events || [] });
  };
  let raf = 0;
  const ro = new ResizeObserver(() => { cancelAnimationFrame(raf); raf = requestAnimationFrame(draw); });
  ro.observe(box);
  toggle.addEventListener('click', () => requestAnimationFrame(draw));
  return card;
}
function chartFrame(box, w, { title, labels, values, fmt, axisFmt, fixedMax, events }) {
  const m = { l: 48, r: 12, t: 20, b: 28 };
  const iw = Math.max(40, w - m.l - m.r);
  const ih = CHART_H - m.t - m.b;
  const sc = yScale(values, fixedMax);
  const y = (v) => m.t + ih - (v / sc.max) * ih;
  const n = labels.length;
  const band = iw / n;
  const xc = (i) => m.l + band * i + band / 2;
  const last = values.reduce((acc, v, i) => (v !== null && v !== undefined ? i : acc), -1);
  const label = `${title}. ${n} weeks from ${fmtDay(labels[0])} to ${fmtDay(labels[n - 1])}.` +
    (last >= 0 ? ` Latest, week of ${fmtDay(labels[last])}: ${fmt(values[last])}.` : '') + ' Use left and right arrow keys to read each week.';
  const svg = s('svg', { width: w, height: CHART_H, viewBox: `0 0 ${w} ${CHART_H}`, role: 'img', 'aria-label': label, tabindex: '0', focusable: 'true' });
  const grid = s('g', { 'aria-hidden': 'true' });
  for (const t of sc.ticks) {
    grid.append(s('line', { class: 'grid-line', x1: m.l, x2: m.l + iw, y1: Math.round(y(t)) + 0.5, y2: Math.round(y(t)) + 0.5 }));
    grid.append(s('text', { class: 'axis-text', x: m.l - 8, y: y(t) + 4, 'text-anchor': 'end' }, axisFmt(t)));
  }
  const every = band < 46 ? Math.ceil(46 / band) : 1;
  labels.forEach((l, i) => {
    if ((n - 1 - i) % every) return;
    grid.append(s('text', { class: 'axis-text', x: xc(i), y: CHART_H - 8, 'text-anchor': 'middle' }, fmtDay(l)));
  });
  svg.append(grid);
  const tip = h('div', { class: 'chart-tip', hidden: true, 'aria-hidden': 'true' });
  box.append(svg, tip);
  const showTip = (i, px, py, side) => {
    clear(tip);
    tip.append(h('b', { text: fmt(values[i]) }), h('span', { class: 'muted', text: `Week of ${fmtDay(labels[i])}` }));
    tip.hidden = false;
    const tw = tip.offsetWidth;
    const th = tip.offsetHeight;
    if (side) {
      // beside the crosshair so the marker stays visible
      const left = px + 14 + tw <= w ? px + 14 : px - 14 - tw;
      tip.style.left = `${Math.max(0, left)}px`;
      tip.style.top = `${Math.min(Math.max(0, py - th / 2), CHART_H - th)}px`;
      return;
    }
    tip.style.left = `${Math.min(Math.max(0, px - tw / 2), w - tw)}px`;
    tip.style.top = `${Math.max(0, py - th - 10)}px`;
  };
  const evLayer = eventLayer({ events, labels, m, ih, band, w, tip, svg });
  return { svg, m, iw, ih, y, band, xc, n, tip, showTip, sc, evLayer };
}
const WEEK_MS = 7 * 86400000;
function eventLayer({ events, labels, m, ih, band, w, tip, svg }) {
  const g = s('g', { class: 'events' });
  if (!events?.length || !labels.length) return g;
  const t0 = new Date(labels[0] + 'T00:00:00Z').getTime();
  for (const ev of events) {
    const t = new Date(ev.at).getTime();
    const pos = (t - t0) / WEEK_MS; // in bands; each band starts on its week's first day
    if (!Number.isFinite(pos) || pos < 0 || pos > labels.length) continue;
    const x = Math.round(m.l + pos * band) + 0.5;
    const text = `${fmtDay(ev.at)} · ${ev.summary}`;
    const mk = s('g', { class: 'ev', tabindex: '0', role: 'button', 'aria-label': `Settings change, ${text}. Open in Audit.` },
      s('title', null, text),
      s('line', { class: 'ev-line', x1: x, x2: x, y1: m.t - 6, y2: m.t + ih }),
      s('path', { class: 'ev-glyph', d: `M${x},${m.t - 13}l4,4l-4,4l-4,-4z` }),
      s('rect', { x: x - 6, y: m.t - 15, width: 12, height: ih + 15, fill: 'transparent' }));
    const show = () => {
      clear(tip);
      tip.append(h('b', { text: 'Settings change' }), h('span', { text }));
      tip.hidden = false;
      const tw = tip.offsetWidth;
      tip.style.left = `${Math.min(Math.max(0, x - tw / 2), w - tw)}px`;
      tip.style.top = `${Math.max(0, m.t - tip.offsetHeight - 12)}px`;
    };
    const hide = () => { tip.hidden = true; };
    const open = () => { ui.auditFocus = ev.id; go('audit'); };
    mk.addEventListener('pointerenter', show);
    mk.addEventListener('pointerleave', hide);
    mk.addEventListener('focus', show);
    mk.addEventListener('blur', hide);
    mk.addEventListener('click', open);
    mk.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open(); } });
    g.append(mk);
  }
  return g;
}
function attachKeys(svg, n, setIdx) {
  let idx = -1;
  svg.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowRight' || e.key === 'ArrowLeft' || e.key === 'Home' || e.key === 'End') {
      e.preventDefault();
      if (e.key === 'Home') idx = 0;
      else if (e.key === 'End') idx = n - 1;
      else idx = Math.min(n - 1, Math.max(0, (idx < 0 ? n : idx) + (e.key === 'ArrowRight' ? 1 : -1)));
      setIdx(idx);
    } else if (e.key === 'Escape') { idx = -1; setIdx(-1); }
  });
  svg.addEventListener('blur', () => { idx = -1; setIdx(-1); });
}
function drawBars(box, w, opts) {
  const f = chartFrame(box, w, opts);
  const { values } = opts;
  const bw = Math.max(4, Math.min(22, f.band - 2, f.band * 0.42));
  const g = s('g', { class: 'bars' });
  const bars = values.map((v, i) => {
    if (v === null || v === undefined) return null;
    const top = f.y(v);
    const hh = f.m.t + f.ih - top;
    const p = s('path', { class: 'bar mark-s1', d: roundTopBar(f.xc(i) - bw / 2, top, bw, Math.max(hh, v > 0 ? 1 : 0), 4) });
    g.append(p);
    return p;
  });
  const setIdx = (i) => {
    bars.forEach((b, j) => b && b.classList.toggle('on', j === i));
    g.classList.toggle('hovering', i >= 0 && !!bars[i]);
    if (i < 0 || values[i] === null || values[i] === undefined) { f.tip.hidden = true; return; }
    f.showTip(i, f.xc(i), f.y(values[i]));
  };
  const hit = s('g', null);
  values.forEach((v, i) => {
    const r = s('rect', { x: f.m.l + f.band * i, y: f.m.t, width: f.band, height: f.ih, fill: 'transparent' });
    r.addEventListener('pointerenter', () => setIdx(i));
    hit.append(r);
  });
  hit.addEventListener('pointerleave', () => setIdx(-1));
  f.svg.append(g, hit, f.evLayer);
  attachKeys(f.svg, f.n, setIdx);
}
function drawLine(box, w, opts) {
  const f = chartFrame(box, w, opts);
  const { values } = opts;
  let d = '';
  let pen = false;
  values.forEach((v, i) => {
    if (v === null || v === undefined) { pen = false; return; }
    d += `${pen ? 'L' : 'M'}${f.xc(i).toFixed(1)},${f.y(v).toFixed(1)}`;
    pen = true;
  });
  const path = s('path', { class: 'line-s1', d });
  const cross = s('line', { class: 'crosshair', y1: f.m.t, y2: f.m.t + f.ih, visibility: 'hidden' });
  const marker = s('circle', { class: 'marker mark-s1', r: 5, visibility: 'hidden' });
  const setIdx = (i) => {
    if (i < 0 || values[i] === null || values[i] === undefined) {
      cross.setAttribute('visibility', 'hidden'); marker.setAttribute('visibility', 'hidden'); f.tip.hidden = true; return;
    }
    const x = f.xc(i);
    cross.setAttribute('x1', x); cross.setAttribute('x2', x); cross.setAttribute('visibility', 'visible');
    marker.setAttribute('cx', x); marker.setAttribute('cy', f.y(values[i])); marker.setAttribute('visibility', 'visible');
    f.showTip(i, x, f.y(values[i]), true);
  };
  const overlay = s('rect', { x: f.m.l, y: f.m.t, width: f.iw, height: f.ih, fill: 'transparent' });
  overlay.addEventListener('pointermove', (e) => {
    const rect = f.svg.getBoundingClientRect();
    const px = e.clientX - rect.left;
    const i = Math.min(f.n - 1, Math.max(0, Math.floor((px - f.m.l) / f.band)));
    setIdx(i);
  });
  overlay.addEventListener('pointerleave', () => setIdx(-1));
  f.svg.append(cross, path, marker, overlay, f.evLayer);
  attachKeys(f.svg, f.n, setIdx);
}
function tierMixCard(mix) {
  const tiers = ['A', 'B', 'C'];
  const counts = tiers.map((t) => mix?.[t] ?? 0);
  const total = counts.reduce((a, b) => a + b, 0);
  const title = 'Tier mix of completed tasks';
  const tableId = nextId('tbl');
  const box = h('div', { class: 'chart-box mix-box' });
  const table = tableWrap(['Tier', { label: 'Tasks', num: true }, { label: 'Share', num: true }],
    tiers.map((t, i) => h('tr', null, td(`Tier ${t}`), td(String(counts[i]), 'num'), td(total ? fmtPct(counts[i] / total) : '—', 'num'))),
    { caption: title });
  table.id = tableId;
  table.hidden = true;
  const toggle = h('button', { class: 'btn btn-sm', type: 'button', 'aria-pressed': 'false', 'aria-controls': tableId, text: 'Table' });
  toggle.addEventListener('click', () => {
    const on = toggle.getAttribute('aria-pressed') !== 'true';
    toggle.setAttribute('aria-pressed', String(on));
    toggle.textContent = on ? 'Chart' : 'Table';
    table.hidden = !on; box.hidden = on;
  });
  const draw = () => {
    const w = box.clientWidth;
    if (!w || box.hidden) return;
    clear(box);
    if (!total) { box.append(h('div', { class: 'chart-empty', text: 'No completed tasks in this window.' })); return; }
    const H = 26;
    const label = `${title}: ` + tiers.map((t, i) => `Tier ${t} ${counts[i]} (${fmtPct(counts[i] / total)})`).join(', ') + '.';
    const svg = s('svg', { width: w, height: H, viewBox: `0 0 ${w} ${H}`, role: 'img', 'aria-label': label });
    const clipId = nextId('clip');
    svg.append(s('defs', null, s('clipPath', { id: clipId }, s('rect', { x: 0, y: 0, width: w, height: H, rx: 6 }))));
    const g = s('g', { 'clip-path': `url(#${clipId})` });
    const tip = h('div', { class: 'chart-tip', hidden: true, 'aria-hidden': 'true' });
    let x = 0;
    const gap = 2;
    const nonzero = counts.filter((c) => c > 0).length;
    const avail = w - gap * Math.max(0, nonzero - 1);
    tiers.forEach((t, i) => {
      if (!counts[i]) return;
      const sw = (counts[i] / total) * avail;
      const r = s('rect', { class: `bar mark-s${i + 1}`, x, y: 0, width: Math.max(0, sw), height: H });
      const cx = x + sw / 2;
      r.addEventListener('pointerenter', () => {
        clear(tip);
        tip.append(h('b', { text: `Tier ${t}: ${counts[i]} tasks` }), h('span', { class: 'muted', text: `${fmtPct(counts[i] / total)} of ${total}` }));
        tip.hidden = false;
        tip.style.left = `${Math.min(Math.max(0, cx - tip.offsetWidth / 2), w - tip.offsetWidth)}px`;
        tip.style.top = `${-tip.offsetHeight - 8}px`;
      });
      r.addEventListener('pointerleave', () => { tip.hidden = true; });
      g.append(r);
      x += sw + gap;
    });
    svg.append(g);
    box.append(svg, tip,
      h('div', { class: 'mix-labels' }, tiers.map((t, i) => h('span', { class: 'mix-label' },
        h('span', { class: `mix-swatch sw-s${i + 1}`, 'aria-hidden': 'true' }),
        h('b', { text: `Tier ${t}` }), `${counts[i]} · ${fmtPct(counts[i] / total)}`))));
  };
  const ro = new ResizeObserver(() => requestAnimationFrame(draw));
  ro.observe(box);
  toggle.addEventListener('click', () => requestAnimationFrame(draw));
  return h('section', { class: 'card chart-card wide', 'aria-label': title },
    h('div', { class: 'chart-head' },
      h('div', null, h('h3', { text: title }), h('p', { class: 'chart-sub', text: 'A: light review · B: standard review · C: high-risk, full review and human gate' })),
      toggle),
    box, table);
}

// ------------------------------------------------------------- app state --
const TABS = [
  { id: 'overview', label: 'Overview', ico: '◎' },
  { id: 'metrics', label: 'Metrics', ico: '▤' },
  { id: 'progress', label: 'Progress', ico: '▸' },
  { id: 'watched', label: 'Watched', ico: '◔' },
  { id: 'knobs', label: 'Knobs', ico: '⚙' },
  { id: 'keys', label: 'Keys', ico: '⚿' },
  { id: 'audit', label: 'Audit', ico: '☰' },
];
const SCOPES = ['all', 'bugfix', 'poc', 'feature'];
const ui = {
  tab: TABS.some((t) => t.id === store.get('tab')) ? store.get('tab') : 'overview',
  repo: store.get('repo', 'all'),
  days: Number(store.get('days', '28')) || 28,
  knobsRepo: store.get('knobsRepo', null),
  state: null,
  metrics: null,
  metricsKey: null,
  expanded: new Set(),
  scope: SCOPES.includes(store.get('scope')) ? store.get('scope') : 'all',
  progress: null,
  auditFocus: null,
};
let renderToken = 0;
let pollTimer = null;

function repoName(id) {
  if (!id) return 'All repos';
  const r = ui.state?.repos?.find((x) => x.id === id);
  return r ? r.name : id;
}

function renderTabs() {
  const nav = document.getElementById('tabs');
  clear(nav);
  const missing = ui.state?.keys?.missing_needed?.length || 0;
  const halted = (ui.state?.repos || []).filter((r) => r.halted).length;
  for (const t of TABS) {
    const badge = t.id === 'keys' && missing ? `${missing} missing` : t.id === 'progress' && halted ? `${halted} halted` : null;
    nav.append(h('button', {
      class: 'tab', type: 'button', 'aria-current': ui.tab === t.id ? 'page' : null,
      onclick: () => go(t.id),
    }, h('span', { class: 'tab-ico', 'aria-hidden': 'true', text: t.ico }), t.label,
    badge ? h('span', { class: 'tab-badge', text: badge }) : null));
  }
}
function go(tab) {
  if (ui.tab === tab) return;
  ui.tab = tab;
  store.set('tab', tab);
  renderTabs();
  renderView();
  const main = document.getElementById('main');
  main.focus({ preventScroll: true });
  window.scrollTo(0, 0);
}
async function refreshState() {
  ui.state = await apiGet('/api/state');
  renderTabs();
  const meta = document.getElementById('rail-meta');
  meta.textContent = `v${ui.state.version} · ${ui.state.repos.length} repo${ui.state.repos.length === 1 ? '' : 's'} · ${ui.state.config_dir}`;
}

async function renderView() {
  const token = ++renderToken;
  const view = document.getElementById('view');
  stopPolling();
  view.setAttribute('aria-busy', 'true');
  clear(view);
  view.append(h('div', { class: 'loading', text: 'Loading…' }));
  const views = { overview: viewOverview, metrics: viewMetrics, progress: viewProgress, watched: viewWatched, knobs: viewKnobs, keys: viewKeys, audit: viewAudit };
  try {
    const nodes = await views[ui.tab]();
    if (token !== renderToken) return;
    clear(view);
    append(view, [nodes]);
  } catch (e) {
    if (token !== renderToken) return;
    clear(view);
    view.append(errorCard(e, () => renderView()));
  } finally {
    if (token === renderToken) view.setAttribute('aria-busy', 'false');
  }
  if (ui.tab === 'progress' && token === renderToken) startPolling();
}
function pageHead(title, lede, right) {
  return h('div', { class: 'page-head' },
    h('div', null, h('h1', { text: title }), lede ? h('p', { class: 'lede', text: lede }) : null),
    right || null);
}

async function getMetrics(force) {
  const key = `${ui.repo}|${ui.days}`;
  if (!force && ui.metrics && ui.metricsKey === key) return ui.metrics;
  ui.metrics = await apiGet(`/api/metrics?repo=${encodeURIComponent(ui.repo)}&days=${ui.days}`);
  ui.metricsKey = key;
  return ui.metrics;
}
function filterRow(onChange) {
  const repos = ui.state?.repos || [];
  if (ui.repo !== 'all' && !repos.some((r) => r.id === ui.repo)) ui.repo = 'all';
  const sel = h('select', { id: 'f-repo' },
    h('option', { value: 'all', text: 'All repos', selected: ui.repo === 'all' }),
    repos.map((r) => h('option', { value: r.id, text: r.name, selected: ui.repo === r.id })));
  sel.addEventListener('change', () => { ui.repo = sel.value; store.set('repo', ui.repo); onChange(); });
  const win = seg([{ value: 7, label: '7d' }, { value: 28, label: '28d' }, { value: 90, label: '90d' }], ui.days,
    (v) => { ui.days = v; store.set('days', String(v)); onChange(); }, 'Time window');
  return h('div', { class: 'filters' },
    h('div', { class: 'field' }, h('label', { class: 'eyebrow', for: 'f-repo', text: 'Repo' }), sel),
    h('div', { class: 'field' }, h('span', { class: 'eyebrow', text: 'Window' }), win));
}
function windowText(m) {
  if (!m?.window) return '';
  return `${fmtDay(m.window.from)} – ${fmtDay(m.window.to)} · ${repoName(m.repo === 'all' ? null : m.repo)}`;
}

// ------------------------------------------------------------- overview --
const EQ_GROUPS = [
  { id: 'adoption', label: 'Adoption', hint: 'grow' },
  { id: 'overhead', label: 'Agent overhead', hint: 'cut' },
  { id: 'price', label: 'Price', hint: 'route to the cheapest capable model' },
];
function fmtTerm(t) {
  if (t.value === null || t.value === undefined) return '—';
  if (t.id === 'price' || /^usd/i.test(t.unit)) return fmtUSD(t.value);
  if (t.id === 'tokens' || t.value >= 10000) return fmtCompact(t.value);
  return fmtNum(t.value, 2);
}
function eqCard(t) {
  const tipId = nextId('tip');
  const goodUp = t.group === 'adoption';
  return h('div', { class: 'eq-card', tabindex: '0', 'aria-describedby': tipId },
    h('span', { class: 'eq-label', text: t.label }),
    h('span', { class: 'eq-value', text: fmtTerm(t) }),
    h('span', { class: 'eq-unit', text: t.unit }),
    deltaEl(t.value, t.prev, goodUp),
    h('span', { class: 'tip', role: 'tooltip', id: tipId, text: t.formula }));
}
function eqCheck(eq) {
  const terms = eq.terms || [];
  if (!terms.length || terms.some((t) => t.value === null || t.value === undefined)) return 'Some terms have no value yet, so the product is not shown. ';
  const prod = terms.reduce((acc, t) => acc * t.value * (t.factor ?? 1), 1);
  const scaled = terms.filter((t) => (t.factor ?? 1) !== 1).map((t) => t.label.toLowerCase());
  const ok = eq.total_usd !== null && Math.abs(prod - eq.total_usd) <= Math.max(0.01, Math.abs(eq.total_usd) * 0.005);
  return `Check: the six terms multiply to ${fmtUSD(prod)}${scaled.length ? ` (${scaled.join(', ')} counts per million tokens, so it carries a factor of 1/1,000,000)` : ''}${ok ? ', matching total spend. ' : `, but total spend reads ${fmtUSD(eq.total_usd)}. `}`;
}
function equationEl(eq) {
  const strip = h('div', { class: 'equation', role: 'group', 'aria-label': 'Software-factory cost equation' });
  EQ_GROUPS.forEach((g, gi) => {
    const terms = eq.terms.filter((t) => t.group === g.id);
    if (!terms.length) return;
    if (gi > 0) strip.append(h('div', { class: 'eq-op between', 'aria-hidden': 'true', text: '×' }));
    const cards = h('div', { class: 'eq-cards' });
    terms.forEach((t, i) => {
      if (i) cards.append(h('div', { class: 'eq-op', 'aria-hidden': 'true', text: '×' }));
      cards.append(eqCard(t));
    });
    const grp = h('div', { class: 'eq-group' }, h('span', { class: 'eyebrow eq-group-label', text: g.label }), cards);
    grp.style.flexGrow = String(terms.length);
    strip.append(grp);
  });
  strip.append(h('div', { class: 'eq-op between', 'aria-hidden': 'true', text: '=' }));
  const tipId = nextId('tip');
  strip.append(h('div', { class: 'eq-group' }, h('span', { class: 'eyebrow eq-group-label', text: 'Total spend' }),
    h('div', { class: 'eq-cards' },
      h('div', { class: 'eq-card eq-total', tabindex: '0', 'aria-describedby': tipId },
        h('span', { class: 'eq-label', text: 'Spend in window' }),
        h('span', { class: 'eq-value', text: fmtUSD(eq.total_usd) }),
        h('span', { class: 'eq-unit', text: `prev ${fmtUSD(eq.prev_total_usd)}` }),
        deltaEl(eq.total_usd, eq.prev_total_usd, false),
        h('span', { class: 'tip', role: 'tooltip', id: tipId, text: eq.note || 'The six terms multiply to total spend.' })))));
  return strip;
}
async function viewOverview() {
  const m = await getMetrics();
  const out = [];
  out.push(pageHead('Overview', 'How the software factory is running: what it costs, how much it is used, and whether its output holds up.',
    filterRow(() => { ui.metrics = null; renderView(); })));
  const eq = m.equation;
  out.push(h('section', { class: 'card stack', 'aria-labelledby': 'eq-h' },
    h('div', { class: 'section-head' },
      h('div', null, h('h2', { id: 'eq-h', text: 'Cost equation' }),
        h('p', { class: 'small', text: 'Uber’s framing: grow adoption, cut agent overhead, route each request to the cheapest capable model.' })),
      h('span', { class: 'muted small', text: windowText(m) })),
    equationEl(eq),
    h('p', { class: 'eq-note' },
      eqCheck(eq),
      eq.unpriced_runs ? `${eq.unpriced_runs} agent run${eq.unpriced_runs === 1 ? '' : 's'} carried no usage and are not priced. ` : '',
      'Hover or focus a term to see its formula.'),
    m.notes?.length ? h('ul', { class: 'notes' }, m.notes.map((n) => h('li', { text: n }))) : null));

  const groups = [
    { id: 'cost', label: 'Cost' }, { id: 'adoption', label: 'Adoption' }, { id: 'quality', label: 'Quality' },
    { id: 'flow', label: 'Flow' }, { id: 'integrity', label: 'Integrity' },
  ];
  const sc = h('section', { class: 'stack', 'aria-labelledby': 'sc-h' },
    h('div', { class: 'section-head' }, h('h2', { id: 'sc-h', text: 'Scorecard' }),
      h('span', { class: 'muted small', text: 'Click a target to change it. Changes are logged and undoable.' })));
  for (const g of groups) {
    const items = m.scorecard.filter((x) => x.group === g.id);
    if (!items.length) continue;
    sc.append(h('div', { class: 'sc-group' }, h('h3', { class: 'eyebrow', text: g.label }),
      h('div', { class: 'sc-grid' }, items.map(scoreTile))));
  }
  out.push(sc);
  return out;
}
function scoreTile(x) {
  const pct = (x.unit || '').toLowerCase() === 'ratio';
  const suffix = unitSuffix(x.unit);
  const valueEl = h('div', { class: ['tile-value', (x.value === null || x.value === undefined) && 'empty'] },
    x.value === null || x.value === undefined ? 'No data' : fmtUnit(x.value, x.unit),
    suffix && x.value !== null && x.value !== undefined ? h('span', { class: 'eq-unit', text: ` ${suffix}` }) : null);
  const targetSlot = h('div', { class: 'target-slot' });
  const showTarget = () => {
    clear(targetSlot);
    const label = x.target === null || x.target === undefined ? 'Set target' : `Target ${fmtUnit(x.target, x.unit)}`;
    targetSlot.append(h('button', {
      class: 'target-btn', type: 'button', text: label,
      'aria-label': `${label} for ${x.label}. Edit target.`,
      onclick: editTarget,
    }));
  };
  const editTarget = () => {
    clear(targetSlot);
    const inputId = nextId('tgt');
    const input = h('input', {
      id: inputId, type: 'number', step: pct ? '1' : 'any', min: pct ? '0' : null, max: pct ? '100' : null,
      value: x.target === null || x.target === undefined ? '' : String(pct ? +(x.target * 100).toFixed(2) : x.target),
    });
    const save = async (clearIt) => {
      let target = null;
      if (!clearIt) {
        if (input.value.trim() === '') { input.focus(); return; }
        const n = Number(input.value);
        if (!Number.isFinite(n)) { input.focus(); return; }
        target = pct ? n / 100 : n;
      }
      try {
        await apiPost('/api/targets', { id: x.id, target });
        const prev = x.target;
        x.target = target;
        notifySaved(target === null ? `${x.label} target cleared. Logged.` : `${x.label} target set to ${fmtUnit(target, x.unit)}. Logged.`);
        if (!DEMO) { ui.metrics = null; renderView(); return; }
        x.target = DEMO ? prev : target;
        showTarget();
      } catch (e) { toastError(e); }
    };
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { e.preventDefault(); save(false); }
      if (e.key === 'Escape') { e.preventDefault(); showTarget(); targetSlot.querySelector('button')?.focus(); }
    });
    targetSlot.append(h('div', { class: 'target-edit' },
      h('label', { class: 'sr-only', for: inputId, text: `Target for ${x.label}${pct ? ' in percent' : ''}` }),
      input, pct ? h('span', { class: 'muted small', text: '%' }) : null,
      h('button', { class: 'btn btn-sm btn-primary', type: 'button', text: 'Save', onclick: () => save(false) }),
      x.target !== null && x.target !== undefined ? h('button', { class: 'btn btn-sm', type: 'button', text: 'Clear', onclick: () => save(true) }) : null,
      h('button', { class: 'btn-link', type: 'button', text: 'Cancel', onclick: showTarget })));
    input.focus();
  };
  showTarget();
  return h('article', { class: 'card tile', 'aria-label': x.label },
    h('div', { class: 'tile-top' },
      h('span', { class: 'tile-label', text: x.label }),
      h('span', { class: ['chip', x.source === 'uber' && 'chip-accent'], title: x.source === 'uber' ? 'Uber software-factory metric' : 'Factory flow and quality metric', text: x.source === 'uber' ? 'Uber' : 'Factory' })),
    valueEl,
    h('div', { class: 'tile-meta' },
      x.value === null || x.value === undefined ? statusEl('none', 'No data yet') : statusEl(x.status),
      x.value !== null && x.value !== undefined ? deltaEl(x.value, x.prev, x.direction !== 'down') : null),
    h('div', { class: 'tile-foot' },
      targetSlot,
      h('span', { class: 'muted', text: x.n ? `from ${fmtNum(x.n, 0)} ${x.group === 'integrity' || /request|run|1k/.test(x.id) ? 'items' : 'tasks'}` : 'no items yet' })),
    h('details', { class: 'formula' }, h('summary', { text: 'Formula' }),
      h('p', { text: `${x.formula} · ${x.direction === 'down' ? 'lower' : 'higher'} is better` })));
}

// -------------------------------------------------------------- metrics --
async function viewMetrics() {
  const m = await getMetrics();
  const sr = m.series || {};
  const weeks = sr.weeks || [];
  const usd0 = (v) => fmtUSD(v, v >= 100 ? 0 : v % 1 ? 1 : 0);
  const ev = m.events || [];
  const charts = h('div', { class: 'chart-grid' },
    chartCard({ title: 'Agent requests per week', sub: 'Worker, reviewer and adversary runs', kind: 'bar', labels: weeks, events: ev, values: sr.requests || [], fmt: (v) => fmtNum(v, 0), axisFmt: (v) => fmtCompact(v) }),
    chartCard({ title: 'Spend per week', sub: 'USD, priced runs only', kind: 'bar', labels: weeks, events: ev, values: sr.spend || [], fmt: (v) => fmtUSD(v), axisFmt: usd0 }),
    chartCard({ title: 'Cost per 1k requests', sub: 'USD', kind: 'line', labels: weeks, events: ev, values: sr.cost_per_1k_requests || [], fmt: (v) => fmtUSD(v), axisFmt: usd0 }),
    chartCard({ title: 'Cost per task', sub: 'USD per completed task', kind: 'line', labels: weeks, events: ev, values: sr.cost_per_task || [], fmt: (v) => fmtUSD(v), axisFmt: (v) => fmtUSD(v, v % 1 ? 1 : 0) }),
    chartCard({ title: 'Tasks completed per week', kind: 'bar', labels: weeks, events: ev, values: sr.tasks_completed || [], fmt: (v) => fmtNum(v, 0), axisFmt: (v) => fmtNum(v, 1) }),
    chartCard({ title: 'Cache hit rate', sub: 'Share of input tokens read from cache', kind: 'line', labels: weeks, events: ev, values: sr.cache_hit_rate || [], fmt: (v) => fmtPct(v), axisFmt: (v) => fmtPct(v), fixedMax: 1 }),
    chartCard({ title: 'Active repos per week', kind: 'bar', labels: weeks, events: ev, values: sr.active_repos || [], fmt: (v) => fmtNum(v, 0), axisFmt: (v) => fmtNum(v, 1) }),
    tierMixCard(m.tier_mix));
  return [
    pageHead('Metrics', `Weekly series for ${repoName(m.repo === 'all' ? null : m.repo).toLowerCase() === 'all repos' ? 'all repos' : repoName(m.repo)}. Hover a mark, or focus a chart and use the arrow keys.`,
      filterRow(() => { ui.metrics = null; renderView(); })),
    ev.length ? h('div', { class: 'ev-legend' },
      h('span', { class: 'ev-key', 'aria-hidden': 'true' }),
      h('span', null, h('strong', { text: 'Settings change' }), ` · ${ev.length} knob change${ev.length === 1 ? '' : 's'} or stop${ev.length === 1 ? '' : 's'} in these weeks, drawn as dashed lines. Hover or focus one to read it; click to open it in Audit.`)) : null,
    weeks.length ? charts : h('div', { class: 'card empty', text: 'No weekly data yet. Series appear once the ledger has routes.' }),
  ];
}

// ------------------------------------------------------------- progress --
const TASK_STATUS = {
  done: { g: '✓', cls: 'st-good', label: 'Done' },
  active: { g: '●', cls: 'st-watch', label: 'Active' },
  failed: { g: '✕', cls: 'st-off', label: 'Failed' },
  todo: { g: '○', cls: 'st-none', label: 'To do' },
};
function taskStatusEl(st) {
  const t = TASK_STATUS[st] || TASK_STATUS.todo;
  return h('span', { class: ['status', t.cls] }, h('span', { class: 'g', 'aria-hidden': 'true', text: t.g }), t.label);
}
async function viewProgress() {
  const data = await apiGet('/api/progress');
  return progressNodes(data);
}
function rerenderProgress() {
  const view = document.getElementById('view');
  const fkey = document.activeElement?.getAttribute?.('data-fkey');
  clear(view);
  append(view, [progressNodes(ui.progress)]);
  if (fkey) view.querySelector(`[data-fkey="${CSS.escape(fkey)}"]`)?.focus({ preventScroll: true });
}
function scopeFilter() {
  const g = h('div', { class: 'seg', role: 'group', 'aria-label': 'Filter plans by scope' });
  for (const v of SCOPES) {
    g.append(h('button', {
      type: 'button', text: v === 'all' ? 'All scopes' : v, 'aria-pressed': String(ui.scope === v), 'data-fkey': `scope-${v}`,
      onclick: () => { ui.scope = v; store.set('scope', v); rerenderProgress(); },
    }));
  }
  return h('div', { class: 'field scope-filter' }, h('span', { class: 'eyebrow', text: 'Scope' }), g);
}
function scopeBadge(scope) {
  const v = typeof scope === 'string' && scope ? scope : 'n/a';
  return h('span', { class: ['chip', 'scope-badge', `scope-${v}`], 'aria-label': `Scope: ${v}`, title: `Plan scope: ${v}`, text: v });
}
function progressNodes(data) {
  ui.progress = data;
  const out = [pageHead('Progress', 'Read-only view of every plan and task. The console never starts work; it can only stop and resume it.',
    h('span', { class: 'muted small', text: 'Refreshes every 5 s while this tab is visible' })),
  h('div', { class: 'filters' }, scopeFilter())];
  if (!data.repos?.length) out.push(h('div', { class: 'card empty', text: 'No repos registered yet.' }));
  for (const r of data.repos || []) out.push(repoProgress(r));
  return out;
}
function repoProgress(r) {
  const lock = r.lock;
  const head = h('div', { class: 'repo-head' },
    h('div', null,
      h('h2', null, r.name, r.halted ? statusEl('off', 'Halted') : lock ? statusEl('watch', 'Running') : statusEl('none', 'Idle')),
      r.halted && r.halt_reason ? h('p', { class: 'small' }, h('span', { class: 'muted', text: 'Reason: ' }), r.halt_reason) : null,
      lock ? h('div', { class: 'lock-line', 'aria-label': 'Active lock' },
        h('span', null, h('span', { class: 'k', text: 'ACTIVE ' }), h('span', { class: 'v', text: lock.kind })),
        h('span', null, h('span', { class: 'k', text: 'plan ' }), h('code', { text: lock.id })),
        h('span', null, h('span', { class: 'k', text: 'line ' }), h('span', { class: 'v', text: String(lock.line) })),
        h('span', null, h('span', { class: 'k', text: 'stage ' }), h('span', { class: 'v', text: lock.stage })),
        h('span', null, h('span', { class: 'k', text: 'since ' }), timeEl(lock.since))) : h('p', { class: 'small muted', text: 'No task holds the lock.' })),
    r.halted
      ? h('button', { class: 'btn', type: 'button', 'data-fkey': `halt-${r.id}`, text: 'Resume', onclick: () => resumeRepo(r) })
      : h('button', { class: 'btn btn-danger', type: 'button', 'data-fkey': `halt-${r.id}`, text: 'Stop all work', onclick: () => haltRepo(r) }));
  const card = h('section', { class: 'card', 'aria-label': r.name }, head);
  const plans = (r.plans || []).filter((p) => ui.scope === 'all' || p.scope === ui.scope);
  if (!r.plans?.length) card.append(h('p', { class: 'plan empty', text: 'No plans in this repo yet.' }));
  else if (!plans.length) card.append(h('p', { class: 'plan empty', text: `No ${ui.scope} plans in this repo.` }));
  for (const p of plans) card.append(planEl(r, p, lock));
  if (r.adhoc?.length) {
    card.append(h('div', { class: 'plan' }, h('h3', { class: 'eyebrow', text: 'Ad-hoc routes' }),
      tableWrap(['Id', { label: 'Routes', num: true }, { label: 'Cost', num: true }, 'Last activity'],
        r.adhoc.map((a) => h('tr', null, td(h('code', { text: a.id })), td(String(a.routes), 'num'), td(fmtUSD(a.usd), 'num'), td(timeEl(a.last_activity)))),
        { caption: `Ad-hoc routes in ${r.name}`, class: 'task-table' })));
  }
  return card;
}
function planEl(r, p, lock) {
  const key = `${r.id}:${p.hash}`;
  const open = ui.expanded.has(key);
  const pct = p.total ? p.done / p.total : 0;
  const listId = `tasks-${r.id}-${p.hash}`;
  const bar = h('span');
  bar.style.width = `${Math.round(pct * 100)}%`;
  const toggle = h('button', {
    class: 'btn btn-sm expander', type: 'button', 'aria-expanded': String(open), 'aria-controls': listId, 'data-fkey': `exp-${key}`,
    text: open ? `Hide ${p.tasks?.length ?? 0} tasks` : `Show ${p.tasks?.length ?? 0} tasks`,
  });
  const running = lock && lock.id === p.hash ? lock.line : null;
  const tasks = tableWrap(
    [{ label: 'Line', num: true }, 'Task', 'Status', 'Tier', { label: 'Rounds', num: true }, { label: 'Attempts', num: true }, 'Completed', { label: 'Delegated cost', num: true }],
    (p.tasks || []).map((t) => h('tr', null,
      td(String(t.line), 'num'),
      td(h('span', null, t.title, running === t.line ? h('span', { class: 'chip chip-accent', text: 'running' }) : null), 'task-title'),
      td(taskStatusEl(t.status)),
      td(t.tier ? h('span', { class: `tier tier-${t.tier}`, text: t.tier, 'aria-label': `Tier ${t.tier}` }) : '—'),
      td(String(t.rounds ?? '—'), 'num'),
      td(String(t.attempts ?? '—'), 'num'),
      td(t.completed_at ? timeEl(t.completed_at, 'abs') : '—'),
      td(naUSD(t.usd, 'Delegated cost not recorded'), 'num'))),
    { caption: `Tasks in ${p.name}`, class: 'task-table', label: `Tasks in ${p.name}` });
  tasks.id = listId;
  tasks.hidden = !open;
  const costTable = costTableEl(p);
  costTable.hidden = !open;
  toggle.addEventListener('click', () => {
    const now = tasks.hidden;
    tasks.hidden = !now;
    costTable.hidden = !now;
    toggle.setAttribute('aria-expanded', String(now));
    toggle.textContent = `${now ? 'Hide' : 'Show'} ${p.tasks?.length ?? 0} tasks`;
    if (now) ui.expanded.add(key); else ui.expanded.delete(key);
  });
  return h('div', { class: 'plan' },
    h('div', { class: 'plan-top' },
      h('div', null,
        h('div', { class: 'row' }, h('span', { class: 'plan-name', text: p.name }),
          p.enforced ? h('span', { class: 'chip chip-accent', title: 'Dispatch hooks enforce routing for this plan', text: 'enforced' }) : h('span', { class: 'chip', text: 'not enforced' }),
          p.halted ? statusEl('off', 'Halted') : null,
          scopeBadge(p.scope),
          p.landed ? statusEl('good', 'Landed') : null),
        h('div', { class: 'plan-path', text: p.path })),
      h('span', { class: 'muted small' }, 'Last activity ', timeEl(p.last_activity))),
    h('div', { class: 'progress', role: 'progressbar', 'aria-valuemin': '0', 'aria-valuemax': String(p.total), 'aria-valuenow': String(p.done), 'aria-label': `${p.name} progress` }, bar),
    h('div', { class: 'progress-label', text: `${p.done} of ${p.total} tasks done · ${fmtPct(pct)}` }),
    h('div', { class: 'plan-stats' },
      h('span', null, 'Phase ', h('span', { class: 'v', text: p.phase || '—' })),
      h('span', null, 'Cost ', h('span', { class: 'v', text: p.usd === null || p.usd === undefined ? NA : fmtUSD(p.usd) })),
      h('span', null, 'Open findings ', h('span', { class: 'v', text: String(p.open_findings ?? '—') })),
      p.halt_reason ? h('span', null, 'Halt reason ', h('span', { class: 'v', text: p.halt_reason })) : null),
    intentEl(p),
    p.landed ? operatePanel(p) : null,
    toggle, tasks, costTable);
}

// ----------------------------------------------- scope, intent, operate, cost --
// null / missing is `n/a` (or the word `unmeasured`), never 0 and never blank.
const NA = 'n/a';
function naText(v) { return v === null || v === undefined || v === '' ? NA : String(v); }
function naInt(v) { return Number.isInteger(v) ? String(v) : NA; }
function naVal(v) { return typeof v === 'number' && Number.isFinite(v) ? fmtNum(v, Math.abs(v) < 10 && v % 1 ? 2 : 1) : NA; }
function naUSD(v, why) {
  const ok = typeof v === 'number' && Number.isFinite(v);
  return h('span', { class: ok ? null : 'na', title: ok ? null : why, text: ok ? fmtUSD(v) : NA });
}
function intentEl(p) {
  const it = p.intent;
  if (!it) return h('p', { class: 'small muted intent-none', text: 'Intent: n/a (no intent file for this plan).' });
  const rows = [['Problem', it.problem], ['Who', it.who], ['Why now', it.why_now], ['Non-goals', it.non_goals]];
  return h('details', { class: 'intent', 'aria-label': `Intent of ${p.name}` },
    h('summary', null, 'Intent', it.problem ? h('span', { class: 'muted', text: ` — ${String(it.problem).slice(0, 90)}` }) : null),
    h('dl', null, rows.map(([k, v]) => [h('dt', { text: k }), h('dd', { text: naText(v) })])),
    it.file ? h('p', { class: 'plan-path', text: it.file }) : null);
}
function costTableEl(p) {
  const c = p.cost || {};
  const na = typeof c.status === 'string' && c.status !== 'measured' ? c.status : null;
  const orch = (t) => {
    const ok = typeof t.orchestrator_usd === 'number';
    const why = t.orchestrator_na || (typeof t.orchestrator_tokens === 'number' ? `${fmtCompact(t.orchestrator_tokens)} tokens measured, price unknown` : 'Orchestrator cost not available');
    return td(h('span', { class: ok ? null : 'na', title: ok ? `${naInt(t.orchestrator_tokens)} tokens` : why, text: ok ? fmtUSD(t.orchestrator_usd) : NA }), 'num');
  };
  const rows = (p.tasks || []).map((t) => h('tr', null,
    td(h('span', { text: `${t.line}  ${t.title}` }), 'task-title'),
    td(naUSD(t.usd, 'Delegated cost not recorded (background agents record no usage)'), 'num'),
    orch(t),
    td(h('span', { class: 'muted', title: 'Unattributed time is plan-level, see the total row', text: '—' }), 'num')));
  rows.push(h('tr', { class: 'total-row' },
    td(h('strong', { text: 'Plan total' })),
    td(h('span', null, naUSD(c.delegated_usd, na || 'Delegated cost not available'),
      c.delegated_unknown_tasks ? h('span', { class: 'muted small', text: ` (${c.delegated_unknown_tasks} task${c.delegated_unknown_tasks === 1 ? '' : 's'} n/a)` }) : null), 'num'),
    td(naUSD(c.orchestrator_usd, na || 'Orchestrator cost not available'), 'num'),
    td(h('span', { title: typeof c.orchestrator_unattributed_tokens === 'number' ? `${fmtCompact(c.orchestrator_unattributed_tokens)} tokens in no single task's window` : (na || 'Not available') },
      naUSD(c.orchestrator_unattributed_usd, na || 'Unattributed cost not available')), 'num')));
  const t = tableWrap(['Task', { label: 'Delegated', num: true }, { label: 'Orchestrator', num: true }, { label: 'Unattributed', num: true }], rows,
    { caption: `Cost per task in ${p.name}`, class: 'task-table cost-table', label: `Cost per task in ${p.name}`, focusable: true });
  return t;
}
function flagChip(text, why) { return h('span', { class: 'chip flag', title: why, text }); }
function latestCell(c) {
  if (c.unmeasured === true || c.last_status === 'unmeasured' || c.measured === false) {
    return h('span', { class: 'status st-watch', title: c.last_reason || 'This check has not produced a reading' }, 'unmeasured');
  }
  return h('span', { class: ['v', c.last_status === 'breach' ? 'st-off' : null] }, naVal(c.last_value), c.last_status ? h('span', { class: 'muted small', text: ` ${c.last_status}` }) : null);
}
function checksTable(checks, label) {
  if (!checks?.length) return h('p', { class: 'small muted', text: 'No checks declared.' });
  return tableWrap(['Check', 'Metric', { label: 'Threshold', num: true }, 'Severity', { label: 'Latest', num: true }, { label: 'Breaches', num: true }, 'Flags'],
    checks.map((c) => h('tr', null,
      td(h('code', { text: c.id })),
      td(naText(c.metric)),
      td(`${c.op ?? ''} ${naVal(c.threshold)}`.trim(), 'num'),
      td(naText(c.severity)),
      td(latestCell(c), 'num'),
      td(c.unmeasured === true ? 'unmeasured' : naInt(c.breaches), 'num'),
      td(h('span', { class: 'flags' },
        c.unmeasured === true ? flagChip('unmeasured', 'Never produced a reading') : null,
        c.open_at_close === true ? flagChip('open-at-close', 'Was in breach when the window closed') : null,
        c.filed ? flagChip(`filed: ${c.filed}`, 'Where the first breach went') : null)))),
    { caption: label, label, class: 'task-table', focusable: true });
}
function ingestedEl(ing, withLessons) {
  if (!ing) return h('p', { class: 'small muted', text: 'Ingested lessons / backlog: n/a.' });
  const list = (items, kind) => items?.length
    ? h('ul', { class: 'ingested', 'aria-label': `Ingested ${kind}` }, items.map((i) => h('li', null,
      h('code', { text: i.id }), ' ', i.title, i.done === true ? flagChip('done') : null)))
    : h('p', { class: 'small muted', text: `No ${kind} ingested.` });
  const cn = ing.counts || {};
  return h('div', { class: 'ingested-box' },
    withLessons ? [h('h5', { class: 'eyebrow', text: `Lessons (${naInt(cn.lessons)})` }), list(ing.lessons, 'lessons')] : null,
    h('h5', { class: 'eyebrow', text: `Backlog (${naInt(cn.backlog)}, ${naInt(cn.backlog_open)} open)` }), list(ing.backlog, 'backlog items'));
}
function windowEl(w) {
  if (!w) return h('p', { text: 'Watch window: n/a' });
  const lists = (a) => (Array.isArray(a) && a.length ? a.join(', ') : 'none');
  let line;
  if (w.state === 'open') line = `Watch window: day ${naInt(w.day)} of ${naInt(w.days)}`;
  else if (w.state === 'closed') line = `Watch window closed: ${w.outcome || 'ended, not yet closed by a monitor run'}`;
  else if (w.state === 'not-opened') line = 'Watch window: not opened (no deploy recorded)';
  else line = `Watch window: ${naText(w.state)}`;
  const extra = [];
  if (w.state === 'open' || w.state === 'closed') {
    extra.push(h('span', null, 'Measured runs ', h('span', { class: 'v', text: naInt(w.measured_runs) })));
    extra.push(h('span', null, 'Breaches ', h('span', { class: 'v', text: naInt(w.breaches) })));
    if (w.never_measured === true) extra.push(flagChip('never measured', 'No monitor run produced a reading'));
  }
  if (w.state === 'closed') {
    extra.push(h('span', null, 'Open at close ', h('span', { class: 'v', text: lists(w.open_at_close) })));
    extra.push(h('span', null, 'Unmeasured at close ', h('span', { class: 'v', text: lists(w.unmeasured_at_close) })));
  }
  return h('div', null, h('p', { class: 'window-line', text: line }), extra.length ? h('div', { class: 'plan-stats' }, extra) : null);
}
function operatePanel(p) {
  const o = p.operate;
  const label = `Operate: ${p.slug || p.name}`;
  if (!o) return h('section', { class: 'operate', 'aria-label': label }, h('h4', { text: 'Operate' }), h('p', { class: 'small muted', text: 'Operate state: n/a (not read).' }));
  const deploys = o.deploys || [];
  const lc = o.last_closed_window;
  return h('section', { class: 'operate', 'aria-label': label },
    h('h4', null, 'Operate ', o.state === 'missing' ? flagChip('state missing', 'The checkpoint has no operate block') : null,
      o.monitor ? h('span', { class: 'muted small', text: ` monitor: ${o.monitor}` }) : null),
    o.state === 'missing' ? h('p', { class: 'small muted', text: 'No operate state recorded for this landed plan: nothing deployed or measured.' }) : null,
    o.problems?.length ? h('ul', { class: 'small', 'aria-label': 'Monitor problems' }, o.problems.map((x) => h('li', { text: x }))) : null,
    h('h5', { class: 'eyebrow', text: 'Deploy history' }),
    deploys.length ? tableWrap(['Time', 'Commit', { label: 'Exit', num: true }],
      deploys.map((d) => h('tr', null, td(timeEl(d.ts, 'abs')), td(h('code', { text: naText(d.sha).slice(0, 12) })), td(naInt(d.exit), 'num'))),
      { caption: `Deploys of ${p.name}`, label: `Deploy history of ${p.name}`, class: 'task-table', focusable: true })
      : h('p', { class: 'small muted', text: 'No deploys recorded.' }),
    h('h5', { class: 'eyebrow', text: 'Watch window' }),
    windowEl(o.window),
    lc ? h('p', { class: 'small muted' }, `Windows closed: ${naInt(o.windows_closed)}. Last closed window: ${naText(lc.outcome)} (by ${naText(lc.closed_by)})`) : null,
    h('h5', { class: 'eyebrow', text: 'Checks' }),
    checksTable(o.checks, `Operate checks of ${p.name}`),
    h('h5', { class: 'eyebrow', text: 'Ingested' }),
    ingestedEl(o.ingested, true));
}

// -------------------------------------------------------------- watched --
async function viewWatched() {
  const data = await apiGet('/api/progress');
  return watchedNodes(data);
}
function watchedNodes(data) {
  const out = [pageHead('Watched plans', 'Plans whose watch window is open, and each repo\'s own checks. Read-only: deploys, monitor runs and ingest happen in the CLI.',
    h('button', { class: 'btn', type: 'button', text: 'Refresh', onclick: () => renderView() }))];
  if (!data.repos?.length) out.push(h('div', { class: 'card empty', text: 'No repos registered yet.' }));
  for (const r of data.repos || []) {
    const w = r.watched || [];
    const rc = r.repo_checks;
    out.push(h('section', { class: 'card', 'aria-label': `Watched in ${r.name}` },
      h('h2', { text: r.name }),
      h('h3', { class: 'eyebrow', text: 'Open watch windows' }),
      w.length ? tableWrap(['Plan', { label: 'Day', num: true }, 'Window ends'],
        w.map((x) => h('tr', null, td(h('span', null, h('strong', { text: x.slug }), ' ', h('span', { class: 'plan-path', text: x.path }))),
          td(`day ${naInt(x.day)} of ${naInt(x.days)}`, 'num'), td(x.end ? timeEl(x.end, 'abs') : NA))),
        { caption: `Open watch windows in ${r.name}`, label: `Open watch windows in ${r.name}`, class: 'task-table', focusable: true })
        : h('p', { class: 'small muted', text: 'No plan has an open watch window.' }),
      h('h3', { class: 'eyebrow', text: 'Repo-level checks' }),
      !rc || rc.configured === false ? h('p', { class: 'small muted', text: 'No repo-level checks configured.' }) : [
        h('p', { class: 'small muted' }, `State: ${naText(rc.state)}`),
        rc.problems?.length ? h('ul', { class: 'small', 'aria-label': 'Repo check problems' }, rc.problems.map((x) => h('li', { text: x }))) : null,
        checksTable(rc.checks, `Repo-level checks in ${r.name}`)],
      rc?.ingested ? [h('h3', { class: 'eyebrow', text: 'Ingested' }), ingestedEl(rc.ingested, false)] : null));
  }
  return out;
}
async function refreshProgress() {
  if (ui.tab !== 'progress' || document.hidden || document.querySelector('dialog[open]')) return;
  const token = renderToken;
  try {
    const data = await apiGet('/api/progress');
    if (token !== renderToken || ui.tab !== 'progress') return;
    const view = document.getElementById('view');
    const fkey = document.activeElement?.getAttribute?.('data-fkey');
    const y = window.scrollY;
    clear(view);
    append(view, [progressNodes(data)]);
    window.scrollTo(0, y);
    if (fkey) view.querySelector(`[data-fkey="${CSS.escape(fkey)}"]`)?.focus({ preventScroll: true });
  } catch { /* keep last good view; next tick retries */ }
}
function startPolling() { stopPolling(); pollTimer = setInterval(refreshProgress, 5000); }
function stopPolling() { if (pollTimer) clearInterval(pollTimer); pollTimer = null; }
document.addEventListener('visibilitychange', () => { if (!document.hidden && ui.tab === 'progress') refreshProgress(); });

function haltRepo(r) {
  const reasonId = nextId('reason');
  const reason = h('textarea', { id: reasonId, required: true, 'aria-describedby': `${reasonId}-help`, placeholder: 'e.g. pausing to review auth changes' });
  const err = h('div', { class: 'field-error', 'aria-live': 'polite' });
  let applyBtn;
  const sync = () => { if (applyBtn) applyBtn.disabled = reason.value.trim().length < 3; };
  reason.addEventListener('input', sync);
  openDialog({
    title: `Stop all work in ${r.name}?`,
    body: [
      h('p', null, 'This writes the ', h('code', { text: 'HALT' }), ' kill switch in this repo’s scope-loop state. Nothing is deleted. The running task stops at its next check; no new task starts until you resume.'),
      h('div', { class: 'field' },
        h('label', { class: 'field-label', for: reasonId, text: 'Reason (required, logged)' }),
        reason,
        h('span', { class: 'field-help', id: `${reasonId}-help`, text: 'Shown to anyone who looks at this repo and kept in the audit log.' }),
        err),
    ],
    actions: [
      { label: 'Cancel' },
      {
        label: 'Stop all work', kind: 'danger', disabled: true, ref: (b) => { applyBtn = b; },
        onClick: async (d) => {
          const text = reason.value.trim();
          if (text.length < 3) { err.textContent = 'Write a short reason first.'; reason.focus(); return; }
          try {
            const res = await apiPost('/api/halt', { repo: r.id, on: true, reason: text });
            d.close();
            notifySaved(`${r.name} halted. Logged as ${res.audit_id}.`, res.audit_id, () => renderView());
            await refreshState();
            renderView();
          } catch (e) { err.textContent = e.message; }
        },
      },
    ],
    initialFocus: 'textarea',
  });
}
async function resumeRepo(r) {
  const ok = await confirmDialog({
    title: `Resume work in ${r.name}?`,
    body: h('p', null, 'This removes the ', h('code', { text: 'HALT' }), ' file. The scope loop picks up from where it stopped the next time it runs. The console does not start anything itself.'),
    confirmLabel: 'Resume',
  });
  if (!ok) return;
  try {
    const res = await apiPost('/api/halt', { repo: r.id, on: false, reason: 'resumed from console' });
    notifySaved(`${r.name} resumed. Logged as ${res.audit_id}.`, res.audit_id, () => renderView());
    await refreshState();
    renderView();
  } catch (e) { toastError(e); }
}

// ---------------------------------------------------------------- knobs --
const REVIEW_FIELDS = [
  { k: 'cap', label: 'Review cap', help: 'Blocking review rounds allowed per attempt.' },
  { k: 'ask_human_after', label: 'Ask a human after', help: 'REQUEST_CHANGES rounds before you are asked to decide.' },
  { k: 'adversary_budget', label: 'Adversary budget', help: 'Most [blocking] findings a reviewer may raise in one pass.' },
  { k: 'escalate_after', label: 'Escalate after', help: 'Failures before the task moves to a stronger model.' },
  { k: 'error_budget', label: 'Error budget', help: 'Stalls allowed before the loop halts.' },
  { k: 'attempt_cap', label: 'Attempt cap', help: 'Failed attempts allowed before the loop halts.' },
];
const PRESETS = {
  lenient: { label: 'Lenient', v: [3, 3, 2, 3, 4, 8] },
  standard: { label: 'Standard', v: [3, 2, 3, 2, 3, 6] },
  strict: { label: 'Strict', v: [2, 2, 5, 2, 2, 5] },
  paranoid: { label: 'Paranoid', v: [2, 1, 8, 1, 2, 4] },
};
function srcChip(src) {
  const s0 = src || 'default';
  return h('span', { class: ['src', `src-${s0}`], title: s0 === 'env' ? 'Set by an environment variable; env overrides the file.' : s0 === 'file' ? 'Set in the knobs file.' : 'Built-in default.', text: s0 });
}
function diffPatch(a, b) {
  // Returns the parts of b that differ from a (arrays compared whole).
  const out = {};
  for (const k of Object.keys(b)) {
    const av = a ? a[k] : undefined;
    const bv = b[k];
    if (bv && typeof bv === 'object' && !Array.isArray(bv) && av && typeof av === 'object' && !Array.isArray(av)) {
      const sub = diffPatch(av, bv);
      if (Object.keys(sub).length) out[k] = sub;
    } else if (JSON.stringify(av) !== JSON.stringify(bv)) out[k] = bv;
  }
  return out;
}
const isEmpty = (o) => !o || !Object.keys(o).length;

function panelShell({ title, lede, plugin, repo, knobs, buildPatch, validate, onReset, body, actions, after, onRefresh }) {
  const reviewBtn = h('button', { class: 'btn', type: 'button', text: 'Review change', disabled: true });
  const resetBtn = h('button', { class: 'btn-link', type: 'button', text: 'Discard edits', hidden: true });
  const errEl = h('span', { class: 'field-error', 'aria-live': 'polite' });
  const refresh = () => {
    const problems = validate ? validate() : [];
    const patch = buildPatch();
    errEl.textContent = problems.join(' ');
    reviewBtn.disabled = isEmpty(patch) || problems.length > 0;
    resetBtn.hidden = isEmpty(patch);
    if (onRefresh) onRefresh(patch, problems);
  };
  const review = (patch = buildPatch()) => reviewChange({ title, plugin, repo, patch, knobs });
  reviewBtn.addEventListener('click', () => review());
  resetBtn.addEventListener('click', onReset);
  const panel = h('section', { class: 'card panel', 'aria-label': title },
    h('div', { class: 'panel-head' }, h('div', null, h('h2', { text: title }), lede ? h('p', { class: 'small', text: lede }) : null)),
    body,
    h('div', { class: 'panel-foot' }, errEl, resetBtn, actions || null, reviewBtn),
    after || null);
  return { panel, refresh, review };
}
function fmtVal(v) {
  if (v === null || v === undefined) return 'none';
  if (Array.isArray(v)) return v.length ? v.map((x) => (typeof x === 'object' ? `${x.glob ?? JSON.stringify(x)}${x.reason ? ` (${x.reason})` : ''}` : String(x))).join(', ') : 'empty';
  if (typeof v === 'object') return JSON.stringify(v);
  if (typeof v === 'boolean') return v ? 'on' : 'off';
  return String(v);
}
function changeList(changes) {
  if (!changes?.length) return h('p', { class: 'muted', text: 'No effective change.' });
  return h('ul', { class: 'change-list' }, changes.map((c) => h('li', null,
    h('span', { class: 'change-key', text: c.key }), ' ',
    h('span', { class: 'muted', text: fmtVal(c.from) }), h('span', { class: 'arrow', 'aria-label': 'to', text: '→' }),
    h('span', { class: 'strong', text: fmtVal(c.to) }))));
}
function reviewChange({ title, plugin, repo, patch }) {
  const d = openDialog({
    title: `Review change: ${title}`,
    lede: `${repoName(repo)} · ${plugin}`,
    drawer: true,
    body: h('p', { class: 'loading', text: 'Checking the change…' }),
    actions: [{ label: 'Cancel' }],
  });
  apiPost('/api/knobs/preview', { repo, plugin, patch }).then((res) => {
    const nodes = [];
    for (const w of res.warnings || []) nodes.push(h('div', { class: 'banner warn' }, h('span', { class: 'glyph', 'aria-hidden': 'true', text: '◐' }), h('span', { text: w })));
    nodes.push(h('h3', { class: 'eyebrow', text: `${res.changes?.length || 0} change${res.changes?.length === 1 ? '' : 's'} staged` }));
    nodes.push(h('div', { class: 'table-wrap' },
      h('table', null, h('caption', { class: 'sr-only', text: 'Staged changes' }),
        h('thead', null, h('tr', null, h('th', { scope: 'col', text: 'Key' }), h('th', { scope: 'col', text: 'From' }), h('th', { scope: 'col', text: 'To' }))),
        h('tbody', null, (res.changes || []).map((c) => h('tr', null, td(h('code', { text: c.key })), td(fmtVal(c.from)), td(fmtVal(c.to), 'strong')))))));
    nodes.push(h('p', { class: 'small muted', text: 'Apply writes the file and logs one audit entry you can undo.' }));
    d.setBody(nodes);
    d.setActions([
      { label: 'Cancel' },
      {
        label: 'Apply', kind: 'primary', disabled: !res.changes?.length,
        onClick: async (dd) => {
          try {
            const r2 = await apiPost('/api/knobs', { repo, plugin, patch });
            dd.close();
            const n = r2.changes?.length ?? res.changes.length;
            notifySaved(`Applied ${n} change${n === 1 ? '' : 's'}. Logged as ${r2.audit_id}.`, r2.audit_id, () => (ui.tab === 'knobs' ? renderView() : null));
            renderView();
          } catch (e) { toastError(e); }
        },
      },
    ]);
    d.dlg.querySelector('.btn-primary')?.focus();
  }).catch((e) => {
    d.setBody(h('div', { class: 'banner alert' }, h('span', { class: 'glyph', 'aria-hidden': 'true', text: '✕' }),
      h('div', null, h('p', { text: e.message }), e.errors?.length ? h('ul', { class: 'notes' }, e.errors.map((x) => h('li', { text: x }))) : null)));
  });
}

async function viewKnobs() {
  const repos = ui.state?.repos || [];
  if (!repos.length) return [pageHead('Knobs'), h('div', { class: 'card empty', text: 'Register a repo first.' })];
  if (!repos.some((r) => r.id === ui.knobsRepo)) ui.knobsRepo = repos[0].id;
  const k = await apiGet(`/api/knobs?repo=${encodeURIComponent(ui.knobsRepo)}`);
  const sel = h('select', { id: 'k-repo' }, repos.map((r) => h('option', { value: r.id, text: r.name, selected: r.id === ui.knobsRepo })));
  sel.addEventListener('change', () => { ui.knobsRepo = sel.value; store.set('knobsRepo', sel.value); renderView(); });
  const out = [pageHead('Knobs', 'Every change is previewed first, written only when you approve it, logged, and undoable.',
    h('div', { class: 'filters' }, h('div', { class: 'field' }, h('label', { class: 'eyebrow', for: 'k-repo', text: 'Repo' }), sel)))];
  if (k.active_lock) {
    const l = k.active_lock;
    out.push(h('div', { class: 'banner warn', role: 'note' }, h('span', { class: 'glyph', 'aria-hidden': 'true', text: '◐' }),
      h('span', null, h('strong', { text: 'A task is running ' }), `(${l.kind} ${l.id}, line ${l.line}, ${l.stage}, since ${rel(l.since)}). Changes apply from its next check.`)));
  }
  out.push(k.scope_loop?.available ? reviewPanel(k) : unavailable('Review strictness', 'apex-scope-loop'));
  out.push(k.scope_loop?.available ? tiersPanel(k) : unavailable('Tier definitions', 'apex-scope-loop'));
  out.push(k.dispatch?.available ? providersPanel(k) : unavailable('Reviewers & providers', 'apex-dispatch'));
  out.push(k.decision?.available ? decisionPanel(k) : unavailable('Decision layer', 'apex-decision-layer'));
  return out;
}
function unavailable(title, plugin) {
  return h('section', { class: 'card panel' }, h('h2', { text: title }),
    h('p', { class: 'muted', text: `${plugin} is not installed in this repo, so there is nothing to change here.` }));
}
function reviewPanel(k) {
  const sl = k.scope_loop;
  const base = sl.effective.review;
  const draft = { ...base };
  const limits = (key) => sl.limits?.[`review.${key}`] || [0, 99];
  const inputs = {};
  const presetSlot = h('div');
  const currentPreset = () => Object.entries(PRESETS).find(([, p]) => REVIEW_FIELDS.every((f, i) => draft[f.k] === p.v[i]))?.[0] || null;
  const drawPreset = () => {
    clear(presetSlot);
    const cur = currentPreset();
    presetSlot.append(h('div', { class: 'row' },
      seg(Object.entries(PRESETS).map(([id, p]) => ({ value: id, label: p.label })), cur, (id) => {
        REVIEW_FIELDS.forEach((f, i) => {
          const [lo, hi] = limits(f.k);
          draft[f.k] = Math.min(hi, Math.max(lo, PRESETS[id].v[i]));
          inputs[f.k].value = String(draft[f.k]);
        });
        update();
      }, 'Review strictness preset'),
      h('span', { class: 'muted small', text: cur ? `${PRESETS[cur].label}${cur === 'standard' ? ' (the defaults)' : ''}` : 'Custom' })));
  };
  const envKeys = REVIEW_FIELDS.filter((f) => sl.sources?.[`review.${f.k}`] === 'env');
  const rows = REVIEW_FIELDS.map((f) => {
    const [lo, hi] = limits(f.k);
    const id = nextId('rv');
    const input = h('input', { id, type: 'number', min: String(lo), max: String(hi), step: '1', value: String(draft[f.k]), 'aria-describedby': `${id}-h` });
    inputs[f.k] = input;
    input.addEventListener('input', () => { draft[f.k] = input.value === '' ? NaN : Number(input.value); update(); });
    const src = sl.sources?.[`review.${f.k}`];
    return h('div', { class: 'knob' },
      h('label', { class: 'knob-name', for: id }, f.label, h('code', { text: f.k }), srcChip(src)),
      input,
      h('span', { class: 'field-help', id: `${id}-h` }, f.help, ` Range ${lo}–${hi}.`, src === 'env' ? ' Set by env: env overrides the file, so a change here waits until that variable is unset.' : ''));
  });
  const validate = () => REVIEW_FIELDS.filter((f) => {
    const [lo, hi] = limits(f.k); const v = draft[f.k];
    const bad = !Number.isInteger(v) || v < lo || v > hi;
    inputs[f.k].classList.toggle('changed', !bad && v !== base[f.k]);
    inputs[f.k].setAttribute('aria-invalid', String(bad));
    return bad;
  }).map((f) => `${f.label} must be a whole number in ${limits(f.k).join('–')}.`);
  const shell = panelShell({
    title: 'Review strictness', plugin: 'scope-loop', repo: k.repo, knobs: k,
    lede: 'How hard reviewers push back and how long the loop keeps trying before it stops or asks you.',
    buildPatch: () => { const p = diffPatch(base, draft); return isEmpty(p) ? {} : { review: p }; },
    validate,
    onReset: () => { Object.assign(draft, base); REVIEW_FIELDS.forEach((f) => { inputs[f.k].value = String(base[f.k]); }); update(); },
    body: [
      presetSlot,
      envKeys.length ? h('p', { class: 'small' }, h('span', { class: 'src src-env', text: 'env' }), ` ${envKeys.map((f) => f.k).join(', ')} come${envKeys.length === 1 ? 's' : ''} from the environment. Env overrides the file.`) : null,
      h('div', { class: 'knob-list' }, rows),
      h('p', { class: 'small muted' }, 'File: ', h('code', { text: sl.file }), sl.sha ? ` · ${sl.sha === 'default' ? 'no file yet (defaults)' : `sha ${sl.sha}`}` : ''),
    ],
  });
  function update() { drawPreset(); shell.refresh(); }
  update();
  return shell.panel;
}
function tiersPanel(k) {
  const sl = k.scope_loop;
  const base = sl.effective.tiers;
  const draft = clone(base);
  draft.exempt = (draft.exempt || []).map((e) => (typeof e === 'string' ? { glob: e, reason: '' } : { glob: e.glob ?? '', reason: e.reason ?? '' }));
  const baseNorm = clone(draft);
  const lim = (key, d) => sl.limits?.[`tiers.${key}`] || d;
  let shell;
  const update = () => shell && shell.refresh();
  const exemptBody = h('tbody');
  const drawExempt = () => {
    clear(exemptBody);
    if (!draft.exempt.length) exemptBody.append(h('tr', null, h('td', { colspan: '3', class: 'muted', text: 'No exemptions.' })));
    draft.exempt.forEach((e, i) => {
      const g = h('input', { type: 'text', value: e.glob, 'aria-label': `Exemption ${i + 1} glob`, placeholder: 'docs/**', spellcheck: 'false', autocomplete: 'off' });
      const r = h('input', { type: 'text', value: e.reason, 'aria-label': `Exemption ${i + 1} reason`, placeholder: 'Why this path is safe (8+ characters)' });
      r.style.width = '100%';
      g.addEventListener('input', () => { e.glob = g.value; update(); });
      r.addEventListener('input', () => { e.reason = r.value; update(); });
      exemptBody.append(h('tr', null, td(g), td(r),
        td(h('button', { class: 'btn btn-sm', type: 'button', text: 'Remove', 'aria-label': `Remove exemption ${e.glob || i + 1}`, onclick: () => { draft.exempt.splice(i, 1); drawExempt(); update(); } }))));
    });
  };
  drawExempt();
  const num = (key, label, help, d) => {
    const [lo, hi] = lim(key, d);
    const id = nextId('tb');
    const input = h('input', { id, type: 'number', min: String(lo), max: String(hi), step: '1', value: String(draft[key]) });
    input.addEventListener('input', () => { draft[key] = input.value === '' ? NaN : Number(input.value); update(); });
    return h('div', { class: 'knob' }, h('label', { class: 'knob-name', for: id }, label, h('code', { text: key }), srcChip(sl.sources?.[`tiers.${key}`])),
      input, h('span', { class: 'field-help', text: `${help} Range ${lo}–${hi}.` }));
  };
  const validate = () => {
    const errs = [];
    draft.exempt.forEach((e, i) => {
      if (!e.glob.trim()) errs.push(`Exemption ${i + 1} needs a glob.`);
      if (e.reason.trim().length < 8) errs.push(`Exemption ${i + 1} needs a reason of 8 or more characters.`);
    });
    for (const [key, d] of [['b_max_lines', [1, 100000]], ['b_max_files', [1, 1000]]]) {
      const [lo, hi] = lim(key, d);
      if (!Number.isInteger(draft[key]) || draft[key] < lo || draft[key] > hi) errs.push(`${key} must be a whole number in ${lo}–${hi}.`);
    }
    return errs;
  };
  const buildPatch = () => {
    const out = {};
    for (const key of Object.keys(draft)) {
      const v = key === 'exempt' ? draft.exempt.map((e) => ({ glob: e.glob.trim(), reason: e.reason.trim() })) : draft[key];
      if (JSON.stringify(v) !== JSON.stringify(baseNorm[key])) out[key] = v;
    }
    return isEmpty(out) ? {} : { tiers: out };
  };
  const sim = tierSimulator({ repo: k.repo, buildPatch, review: (patch) => shell.review(patch) });
  shell = panelShell({
    title: 'Tier definitions', plugin: 'scope-loop', repo: k.repo, knobs: k,
    lede: 'Which changes count as Tier C (full review and the human gate) or Tier B. Everything else is Tier A.',
    buildPatch, validate,
    actions: sim.actions, after: sim.section, onRefresh: sim.onRefresh,
    onReset: () => renderView(),
    body: [
      h('div', { class: 'sub-block' },
        h('h3', { text: 'Built-in Tier C triggers' }),
        h('p', { class: 'small', text: 'Read-only. These ship with apex-scope-loop and always apply.' }),
        h('span', { class: 'eyebrow', text: 'Paths' }), h('pre', { class: 'regex', text: sl.builtins?.c_paths || '—' }),
        h('span', { class: 'eyebrow', text: 'Content' }), h('pre', { class: 'regex', text: sl.builtins?.c_terms || '—' })),
      h('div', { class: 'sub-block' },
        h('div', { class: 'row-between' }, h('h3', { text: 'Extra Tier C path terms' }), h('span', { class: 'small tag-tight', text: '▲ adds Tier C triggers' })),
        chipsEditor({ items: draft.c_paths_extra, label: 'Extra Tier C path terms', placeholder: 'e.g. payments/', onChange: update })),
      h('div', { class: 'sub-block' },
        h('div', { class: 'row-between' }, h('h3', { text: 'Extra Tier C content terms' }), h('span', { class: 'small tag-tight', text: '▲ adds Tier C triggers' })),
        chipsEditor({ items: draft.c_terms_extra, label: 'Extra Tier C content terms', placeholder: 'e.g. stripe_secret', onChange: update })),
      h('div', { class: 'sub-block' },
        h('div', { class: 'row-between' }, h('h3', { text: 'Exemptions' }), h('span', { class: 'small tag-loose', text: '▼ loosens' })),
        h('p', { class: 'small', text: 'Loosens: matching paths never trigger Tier C by path or content. [security] and [tier:c] tags still do. Each needs a reason of 8 or more characters.' }),
        h('div', { class: 'table-wrap' }, h('table', null,
          h('thead', null, h('tr', null, h('th', { scope: 'col', text: 'Glob' }), h('th', { scope: 'col', text: 'Reason' }), h('th', { scope: 'col' }, h('span', { class: 'sr-only', text: 'Actions' })))),
          exemptBody)),
        h('div', null, h('button', { class: 'btn btn-sm', type: 'button', text: 'Add exemption', onclick: () => { draft.exempt.push({ glob: '', reason: '' }); drawExempt(); update(); exemptBody.querySelector('tr:last-child input')?.focus(); } }))),
      h('div', { class: 'sub-block' },
        h('h3', { text: 'Tier B thresholds' }),
        h('div', { class: 'knob-list' },
          num('b_max_lines', 'Max lines', 'Changes above this many lines are at least Tier B.', [10, 2000]),
          num('b_max_files', 'Max files', 'Changes touching more files than this are at least Tier B.', [1, 50])),
        h('span', { class: 'field-label', text: 'Shared directories' }),
        h('p', { class: 'small', text: 'A change under any of these is at least Tier B.' }),
        chipsEditor({ items: draft.b_shared_dirs, label: 'Shared directories', placeholder: 'e.g. lib', onChange: update })),
    ],
  });
  shell.refresh();
  return shell.panel;
}
// ------------------------------------------------------- tier simulator --
// Replays completed tasks under the panel's proposed tier definitions (POST /api/tiers/simulate). Writes nothing.
const TIER_RANK = { A: 0, B: 1, C: 2 };
const plural = (n, one, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;
function tierChip(t) {
  return t ? h('span', { class: `tier tier-${t}`, text: t, 'aria-label': `Tier ${t}` }) : h('span', { class: 'muted', text: '—', 'aria-label': 'no tier' });
}
function isLooser(move) {
  const [from, to] = move.split('→');
  return TIER_RANK[to] < TIER_RANK[from];
}
function moveEl(move, count) {
  const loose = isLooser(move);
  return h('span', { class: ['status', 'move', loose ? 'st-watch' : 'st-good'] },
    h('span', { class: 'g', 'aria-hidden': 'true', text: loose ? '◐' : '✓' }),
    h('span', { class: 'move-key', text: count ? `${move} ×${count}` : move }),
    h('span', { class: 'move-label', text: loose ? 'looser' : 'stricter' }));
}
function simSentence(sum) {
  if (!sum.replayed && !sum.errors) return 'There are no completed tasks to replay yet.';
  let txt = `Replayed ${plural(sum.replayed, 'task')}: `;
  if (!sum.changed) txt += 'none would change tier.';
  else {
    const parts = [];
    if (sum.looser) parts.push(`${sum.looser} would get a lower tier`);
    if (sum.stricter) parts.push(sum.looser ? `${sum.stricter} a higher one` : `${sum.stricter} would get a higher tier`);
    parts.push(`${sum.replayed - sum.changed} unchanged`);
    txt += `${parts.join(', ')}.`;
  }
  if (sum.errors) txt += ` ${sum.errors} could not be replayed.`;
  return txt;
}
function simMixRow(label, mix, ref) {
  const tiers = ['A', 'B', 'C'];
  const counts = tiers.map((t) => mix?.[t] ?? 0);
  const total = counts.reduce((a, b) => a + b, 0);
  const desc = tiers.map((t, i) => `Tier ${t} ${counts[i]}`).join(', ');
  const bar = h('div', { class: 'sim-bar', role: 'img', 'aria-label': `${label}: ${desc}.` });
  tiers.forEach((t, i) => {
    if (!counts[i]) return;
    const seg = h('span', { class: `sim-seg sw-s${i + 1}` });
    seg.style.flexGrow = String(counts[i]);
    bar.append(seg);
  });
  if (!total) bar.append(h('span', { class: 'sim-seg sim-seg-empty' }));
  const labels = h('div', { class: 'sim-mix-labels', 'aria-hidden': 'true' }, tiers.map((t, i) => {
    const d = ref ? counts[i] - (ref[t] ?? 0) : 0;
    return h('span', { class: 'mix-label' },
      h('span', { class: `mix-swatch sw-s${i + 1}` }),
      h('b', { text: t }), String(counts[i]),
      d ? h('span', { class: 'sim-delta', text: `${d > 0 ? '+' : '−'}${Math.abs(d)}` }) : null);
  }));
  return h('div', { class: 'sim-mix-row' }, h('span', { class: 'sim-mix-name', text: label }), h('div', { class: 'sim-mix-body' }, bar, labels));
}
function planLabel(t) {
  const base = String(t.plan_path || t.plan || '').split('/').pop();
  return base.replace(/-plan\.md$/, '').replace(/\.md$/, '') || t.plan || '—';
}
function reasonList(title, items) {
  return h('div', { class: 'sim-reason-block' },
    h('h4', { class: 'eyebrow', text: title }),
    items?.length ? h('ul', { class: 'reason-list' }, items.map((x) => h('li', null, h('code', { text: x })))) : h('p', { class: 'small muted', text: 'None' }));
}
function simTable(tasks, onlyChanged) {
  const sorted = [...tasks].sort((a, b) => (!!b.move - !!a.move) || String(b.completed_at || '').localeCompare(String(a.completed_at || '')));
  const rows = [];
  for (const t of sorted) {
    const detailId = nextId('sim-row');
    const label = `${planLabel(t)} line ${t.line}`;
    let titleCell;
    let detail = null;
    if (t.error) {
      titleCell = h('div', null, h('span', { class: 'sim-title-text', text: t.title }),
        h('div', { class: 'sim-error' }, h('span', { 'aria-hidden': 'true', text: '✕ ' }), t.error));
    } else {
      const btn = h('button', { class: 'sim-title', type: 'button', 'aria-expanded': 'false', 'aria-controls': detailId },
        h('span', { class: 'chev', 'aria-hidden': 'true', text: '▸' }), h('span', { text: t.title }),
        h('span', { class: 'sr-only', text: `, show reasons for ${label}` }));
      detail = h('tr', { class: ['sim-detail', t.move && 'moved'], id: detailId, hidden: true },
        h('td', { colspan: '7' }, h('div', { class: 'sim-reasons' }, reasonList('Added reasons', t.added), reasonList('Removed reasons', t.removed))));
      btn.addEventListener('click', () => {
        const open = btn.getAttribute('aria-expanded') !== 'true';
        btn.setAttribute('aria-expanded', String(open));
        btn.querySelector('.chev').textContent = open ? '▾' : '▸';
        detail.hidden = !open;
      });
      titleCell = btn;
    }
    const tr = h('tr', { class: ['sim-row', t.move && 'moved', t.error && 'errored'] },
      h('td', { class: 'sim-plan', 'data-label': 'Plan' }, h('span', { class: 'mono', text: planLabel(t), title: t.plan_path || '' }),
        h('span', { class: 'sim-line-inline', text: ` · line ${t.line ?? '—'}` })),
      h('td', { class: 'num sim-line', 'data-label': 'Line', text: String(t.line ?? '—') }),
      h('td', { class: 'sim-task', 'data-label': 'Task' }, titleCell),
      h('td', { 'data-label': 'Recorded' }, tierChip(t.recorded)),
      h('td', { 'data-label': 'Current' }, tierChip(t.current)),
      h('td', { 'data-label': 'Proposed' }, tierChip(t.proposed)),
      h('td', { class: 'sim-move', 'data-label': 'Move' }, t.move ? moveEl(t.move) : h('span', { class: 'muted', text: t.error ? '—' : 'same' })));
    if (onlyChanged && !t.move) { tr.hidden = true; }
    rows.push(tr);
    if (detail) { detail.dataset.moved = t.move ? '1' : ''; rows.push(detail); }
  }
  const wrap = tableWrap(['Plan', { label: 'Line', num: true }, 'Task', 'Recorded', 'Current', 'Proposed', 'Move'], rows,
    { class: 'sim-table', caption: 'Replayed tasks with recorded, current and proposed tiers' });
  return wrap;
}
function tierSimulator({ repo, buildPatch, review }) {
  const LIMITS = [10, 30, 60];
  let limit = Number(store.get('simLimit', '30'));
  if (!LIMITS.includes(limit)) limit = 30;
  let running = false;
  let canRun = false;
  let lastKey = null;
  let lastPatch = null;
  const limitSel = h('select', { class: 'sim-limit-select', 'aria-label': 'How many past tasks to replay' },
    LIMITS.map((n) => h('option', { value: String(n), text: `${n} tasks`, selected: n === limit })));
  limitSel.addEventListener('change', () => { limit = Number(limitSel.value); store.set('simLimit', String(limit)); });
  const btn = h('button', { class: 'btn btn-ghost', type: 'button', text: 'Simulate on past tasks', disabled: true });
  const actions = h('div', { class: 'sim-actions' }, h('label', { class: 'sim-limit' }, h('span', { class: 'small muted', text: 'Last' }), limitSel), btn);
  const errSlot = h('div', { class: 'sim-err', 'aria-live': 'polite' });
  const busySlot = h('div', { class: 'sim-busy', role: 'status' });
  const results = h('div', { class: 'sim-results-body' });
  const section = h('div', { class: 'sim-section', hidden: true }, errSlot, busySlot, results);
  const staleBanner = h('div', { class: 'banner warn sim-stale', hidden: true },
    h('span', { class: 'glyph', 'aria-hidden': 'true', text: '◐' }),
    h('span', { class: 'sim-stale-text' }, 'Proposal changed since this simulation. ',
      h('button', { class: 'btn-link', type: 'button', text: 'Simulate again', onclick: () => run() })));
  let reviewLink = null;
  const syncBtn = () => { btn.disabled = running || !canRun; };
  const markStale = (patch) => {
    if (lastKey === null) return;
    const stale = JSON.stringify(patch) !== lastKey;
    staleBanner.hidden = !stale;
    results.classList.toggle('is-stale', stale);
    if (reviewLink) reviewLink.hidden = stale;
  };
  const onRefresh = (patch, problems) => {
    canRun = !isEmpty(patch) && !problems.length;
    syncBtn();
    markStale(patch);
  };
  function draw(res) {
    clear(results);
    const sum = res.summary || summarizeSim(res.tasks || []);
    const tasks = res.tasks || [];
    const moved = tasks.some((t) => t.move);
    let onlyChanged = moved;
    reviewLink = h('button', { class: 'btn-link', type: 'button', text: 'Review this change', onclick: () => review(lastPatch) });
    const tableSlot = h('div');
    const countEl = h('span', { class: 'small muted' });
    const drawTable = () => {
      clear(tableSlot);
      tableSlot.append(simTable(tasks, onlyChanged));
      const shown = onlyChanged ? tasks.filter((t) => t.move).length : tasks.length;
      countEl.textContent = `Showing ${shown} of ${plural(tasks.length, 'task')}`;
    };
    const sw = switchEl({ checked: onlyChanged, label: 'Show only changed', showText: false, onChange: (v) => { onlyChanged = v; drawTable(); } });
    sw.append(h('span', { class: 'sim-switch-text', text: 'Show only changed' }));
    const moves = Object.entries(sum.moves || {}).sort((a, b) => b[1] - a[1]);
    append(results, [
      h('div', { class: 'row-between sim-head' },
        h('div', null,
          h('h3', { text: 'Replay on past tasks' }),
          h('p', { class: 'small muted' }, `${repoName(res.repo || repo)} · last ${plural(limit, 'completed task')} · `, timeEl(new Date().toISOString()))),
        reviewLink),
      staleBanner,
      h('p', { class: 'sim-summary', text: simSentence(sum) }),
      h('div', { class: 'sim-mix', role: 'group', 'aria-label': 'Tier mix before and after' },
        simMixRow('Current', sum.mix_current),
        simMixRow('Proposed', sum.mix_proposed, sum.mix_current)),
      moves.length ? h('div', { class: 'sim-moves', role: 'list', 'aria-label': 'Moves' },
        moves.map(([m, n]) => h('span', { class: 'chip move-chip', role: 'listitem' }, moveEl(m, n)))) : null,
      tasks.length ? h('div', { class: 'row-between sim-controls' }, moved ? sw : h('span', { class: 'small muted', text: 'No task would move.' }), countEl) : null,
      tasks.length ? tableSlot : null,
      sum.note ? h('p', { class: 'sim-note', text: sum.note }) : null,
    ]);
    if (tasks.length) drawTable();
    staleBanner.hidden = true;
    results.classList.remove('is-stale');
  }
  async function run() {
    if (running) return;
    const full = buildPatch();
    if (isEmpty(full)) return;
    running = true;
    syncBtn();
    section.hidden = false;
    clear(errSlot);
    btn.textContent = `Replaying ${limit} tasks…`;
    btn.setAttribute('aria-busy', 'true');
    const started = Date.now();
    const secs = h('span', { class: 'sim-secs', 'aria-hidden': 'true', text: '0 s' });
    clear(busySlot);
    busySlot.append(h('span', { class: 'sim-spinner', 'aria-hidden': 'true' }),
      h('span', { text: `Replaying up to ${limit} tasks under the current and the proposed definitions. About 1 s per task, 4 at a time.` }), secs);
    const timer = setInterval(() => {
      if (!section.isConnected) { clearInterval(timer); return; }
      secs.textContent = `${Math.round((Date.now() - started) / 1000)} s`;
    }, 1000);
    try {
      const res = await apiPost('/api/tiers/simulate', { repo, patch: full.tiers || {}, limit });
      lastKey = JSON.stringify(full);
      lastPatch = clone(full);
      draw(res);
      markStale(buildPatch());
    } catch (e) {
      errSlot.append(h('div', { class: 'banner alert' }, h('span', { class: 'glyph', 'aria-hidden': 'true', text: '✕' }),
        h('div', null, h('p', { text: e.message }), e.errors?.length ? h('ul', { class: 'notes' }, e.errors.map((x) => h('li', { text: x }))) : null)));
    } finally {
      clearInterval(timer);
      clear(busySlot);
      running = false;
      btn.textContent = 'Simulate on past tasks';
      btn.removeAttribute('aria-busy');
      syncBtn();
    }
  }
  btn.addEventListener('click', run);
  return { actions, section, onRefresh };
}

function providersPanel(k) {
  const dp = k.dispatch;
  const draft = {};
  for (const p of dp.providers) draft[p.id] = { enabled: p.enabled, reviewer: p.roles_allowed.includes('reviewer'), min_acceptance: p.min_acceptance };
  const base = clone(draft);
  const esc = { ...dp.escalation };
  let shell;
  const update = () => shell && shell.refresh();
  const rows = dp.providers.map((p) => {
    const d = draft[p.id];
    const canReview = (p.roles_default || []).includes('reviewer');
    const rid = nextId('ma');
    const range = h('input', { id: rid, type: 'range', min: String(p.min_acceptance), max: '1', step: '0.01', value: String(p.min_acceptance), 'aria-label': `${p.id} minimum acceptance (can only be raised)` });
    const out = h('output', { for: rid, text: d.min_acceptance.toFixed(2) });
    range.addEventListener('input', () => { d.min_acceptance = +Number(range.value).toFixed(2); out.textContent = d.min_acceptance.toFixed(2); update(); });
    return h('tr', null,
      td(h('div', { class: 'stack' }, h('span', { class: 'row' }, h('strong', { class: 'strong', text: p.id }), p.second_family ? h('span', { class: 'chip chip-accent', title: 'Counts as a second model family for cross-family review', text: 'second family' }) : null),
        h('span', { class: 'muted small', text: `${p.family} · ${(p.roles_allowed || []).join(', ') || 'no roles'}` }))),
      td(switchEl({ checked: d.enabled, label: `${p.id} enabled`, onChange: (v) => { d.enabled = v; update(); } })),
      td(canReview ? switchEl({ checked: d.reviewer, label: `${p.id} may review`, onChange: (v) => { d.reviewer = v; update(); } }) : h('span', { class: 'muted small', text: 'Not a reviewer' })),
      td(h('div', { class: 'range-cell' }, range, out)),
      td(h('span', { class: 'chip', text: p.status })),
      td(okEl(p.available, 'Yes', 'No')),
      td(p.key_env ? h('button', { class: 'btn-link', type: 'button', text: p.key_env, title: 'Open the Keys tab', onclick: () => go('keys') }) : h('span', { class: 'muted small', text: 'none needed' })));
  });
  const maxRounds = dp.escalation?.max_review_rounds ?? 3;
  const mrId = nextId('mr');
  const mr = h('input', { id: mrId, type: 'number', min: '1', max: String(Math.min(3, maxRounds)), step: '1', value: String(maxRounds) });
  mr.addEventListener('input', () => { esc.max_review_rounds = mr.value === '' ? NaN : Number(mr.value); update(); });
  const validate = () => {
    const errs = [];
    if (!Number.isInteger(esc.max_review_rounds) || esc.max_review_rounds < 1 || esc.max_review_rounds > Math.min(3, maxRounds)) errs.push(`Max review rounds must be 1–${Math.min(3, maxRounds)}; it can only be lowered.`);
    return errs;
  };
  const buildPatch = () => {
    const providers = diffPatch(base, draft);
    const e = diffPatch(dp.escalation, esc);
    const out = {};
    if (!isEmpty(providers)) out.providers = providers;
    if (!isEmpty(e)) out.escalation = e;
    return out;
  };
  shell = panelShell({
    title: 'Reviewers & providers', plugin: 'dispatch', repo: k.repo, knobs: k,
    lede: 'Which models may build and review. Overlays can only tighten the shipped policy: acceptance bars go up, review rounds go down.',
    buildPatch, validate, onReset: () => renderView(),
    body: [
      tableWrap(['Provider', 'Enabled', 'May review', 'Min acceptance', 'Status', 'Available', 'Key'], rows, { caption: 'Providers', focusable: true, label: 'Providers table' }),
      h('div', { class: 'grid-2' },
        h('div', { class: 'knob' }, h('label', { class: 'knob-name', for: mrId }, 'Max review rounds', h('code', { text: 'escalation.max_review_rounds' })), mr,
          h('span', { class: 'field-help', text: `Review rounds before escalation. 1–3, and only lowerable from ${maxRounds}.` })),
        h('div', { class: 'stack' }, h('span', { class: 'field-label', text: 'Second families' }),
          h('div', { class: 'editable-chips' }, (dp.second_families || []).length ? dp.second_families.map((f) => h('span', { class: 'chip', text: f })) : h('span', { class: 'muted small', text: 'None' })),
          h('span', { class: 'field-help', text: 'Providers from a different model family than the builder, used for cross-family review.' }))),
      h('p', { class: 'small muted' }, 'Overlay: ', h('code', { text: dp.overlay_path })),
    ],
  });
  shell.refresh();
  return shell.panel;
}
function decisionPanel(k) {
  const dc = k.decision;
  const base = clone(dc.config);
  const draft = clone(dc.config);
  draft.primary = draft.primary || {};
  draft.shadow = draft.shadow || { backend: null, sample: 0 };
  let shell;
  const update = () => { shell && shell.refresh(); hostedWarn.hidden = draft.egress !== 'hosted'; };
  const radios = (name, opts, cur, onPick) => {
    const g = h('div', { class: 'radio-row', role: 'radiogroup', 'aria-label': name });
    const grp = nextId(name);
    for (const o of opts) {
      const input = h('input', { type: 'radio', name: grp, value: o.value, checked: cur === o.value });
      input.addEventListener('change', () => { if (input.checked) onPick(o.value); });
      g.append(h('label', null, input, o.label));
    }
    return g;
  };
  const hostedWarn = h('div', { class: 'banner alert', hidden: draft.egress !== 'hosted' }, h('span', { class: 'glyph', 'aria-hidden': 'true', text: '✕' }),
    h('span', { text: 'Hosted egress sends task state to a model provider outside this machine. Keep state fields structured unless you have reviewed what leaves.' }));
  const rubrics = ['default', ...(dc.rubrics || [])];
  const backendSel = (cur, label, allowNone, onPick) => {
    const sel = h('select', { 'aria-label': label },
      allowNone ? h('option', { value: '', text: 'None', selected: cur === null || cur === undefined }) : null,
      (dc.backends || []).filter((b) => !(allowNone && b === 'none')).map((b) => h('option', { value: b, text: b, selected: cur === b })),
      !allowNone && cur === undefined ? h('option', { value: '', text: '(inherits default)', selected: true }) : null);
    sel.addEventListener('change', () => onPick(sel.value === '' ? null : sel.value));
    return sel;
  };
  const primaryRows = rubrics.map((r) => h('tr', null,
    td(h('code', { text: r })),
    td(backendSel(draft.primary[r], `Primary backend for ${r}`, false, (v) => {
      if (v === null) delete draft.primary[r]; else draft.primary[r] = v;
      update();
    }))));
  const sampleId = nextId('smp');
  const sample = h('input', { id: sampleId, type: 'range', min: '0', max: '1', step: '0.05', value: String(draft.shadow.sample ?? 0) });
  const sampleOut = h('output', { for: sampleId, text: fmtPct(draft.shadow.sample ?? 0) });
  sample.addEventListener('input', () => { draft.shadow.sample = +Number(sample.value).toFixed(2); sampleOut.textContent = fmtPct(draft.shadow.sample); update(); });
  const buildPatch = () => {
    const out = {};
    if (draft.egress !== base.egress) out.egress = draft.egress;
    if (draft.state_fields !== base.state_fields) out.state_fields = draft.state_fields;
    if (JSON.stringify(draft.primary) !== JSON.stringify(base.primary || {})) out.primary = draft.primary;
    const sh = diffPatch(base.shadow || {}, draft.shadow);
    if (!isEmpty(sh)) out.shadow = sh;
    return out;
  };
  shell = panelShell({
    title: 'Decision layer', plugin: 'decision', repo: k.repo, knobs: k,
    lede: 'Where probability-carrying routing and tier decisions are made, and what leaves this machine to make them.',
    buildPatch, onReset: () => renderView(),
    body: [
      h('div', { class: 'sub-block' }, h('h3', { text: 'Egress' }),
        radios('egress', [{ value: 'none', label: 'None (local only)' }, { value: 'hosted', label: 'Hosted' }], draft.egress, (v) => { draft.egress = v; update(); }),
        hostedWarn),
      h('div', { class: 'sub-block' }, h('h3', { text: 'State fields' }),
        radios('state', [{ value: 'structured', label: 'Structured' }, { value: 'raw', label: 'Raw' }], draft.state_fields, (v) => { draft.state_fields = v; update(); }),
        h('p', { class: 'field-help', text: 'Structured passes only typed fields to a backend. Raw passes task state as it is.' })),
      h('div', { class: 'sub-block' }, h('h3', { text: 'Primary backend per rubric' }),
        tableWrap(['Rubric', 'Backend'], primaryRows, { caption: 'Primary backend per rubric' })),
      h('div', { class: 'sub-block' }, h('h3', { text: 'Shadow' }),
        h('p', { class: 'field-help', text: 'A shadow backend sees a sample of decisions and is scored, but never decides.' }),
        h('div', { class: 'row' },
          h('label', { class: 'field-label', text: 'Backend' }),
          backendSel(draft.shadow.backend, 'Shadow backend', true, (v) => { draft.shadow.backend = v; update(); }),
          h('label', { class: 'field-label', for: sampleId, text: 'Sample' }),
          h('div', { class: 'range-cell' }, sample, sampleOut))),
      h('p', { class: 'small muted' }, 'Config: ', h('code', { text: dc.path })),
    ],
  });
  shell.refresh();
  return shell.panel;
}

// ----------------------------------------------------------------- keys --
const KEY_NAME = /^[A-Z][A-Z0-9_]{2,63}$/;
async function viewKeys() {
  const k = await apiGet('/api/keys');
  const snippet = k.profile?.snippet || '';
  const copyBtn = h('button', { class: 'btn btn-sm', type: 'button', text: 'Copy' });
  copyBtn.addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(snippet); copyBtn.textContent = 'Copied'; setTimeout(() => { copyBtn.textContent = 'Copy'; }, 1500); }
    catch { toast('Could not copy. Select the line and copy it by hand.', { error: true }); }
  });
  const sourced = k.profile?.sourced_in || [];
  const header = h('section', { class: 'card stack', 'aria-label': 'Keys file' },
    h('dl', { class: 'kv' },
      h('dt', { text: 'Keys file' }), h('dd', null, h('code', { text: k.path }), k.exists ? '' : h('span', { class: 'muted', text: ' (not created yet)' })),
      h('dt', { text: 'Permissions' }), h('dd', null, k.exists ? okEl(k.mode_ok, '600 (owner only)', 'Not 600. Run chmod 600 on the file.') : h('span', { class: 'muted', text: '—' })),
      h('dt', { text: 'Shell profile' }), h('dd', null, sourced.length ? okEl(true, `Sourced in ${sourced.join(', ')}`, '') : okEl(false, '', 'Not sourced by your shell profile'))),
    h('div', null,
      h('span', { class: 'field-label', text: sourced.length ? 'Profile line' : 'Add this line to your shell profile' }),
      h('div', { class: 'snippet' }, h('code', { text: snippet }), copyBtn)));

  const probe = h('input', { type: 'checkbox', id: 'probe' });
  const results = h('div', { 'aria-live': 'polite' });
  const checkBtn = h('button', { class: 'btn', type: 'button', text: 'Check keys' });
  checkBtn.addEventListener('click', async () => {
    checkBtn.disabled = true;
    clear(results);
    results.append(h('p', { class: 'muted small', text: probe.checked ? 'Checking, with network probes…' : 'Checking…' }));
    try {
      const res = await apiPost('/api/keys/check', { probe: probe.checked });
      clear(results);
      const map = { ok: 'good', warn: 'watch', fail: 'off', skipped: 'none' };
      const lbl = { ok: 'OK', warn: 'Warning', fail: 'Fail', skipped: 'Skipped' };
      results.append(h('ul', { class: 'check-list' }, (res.checks || []).map((c) => h('li', null,
        statusEl(map[c.status] || 'none', lbl[c.status] || c.status), h('code', { text: c.name }), h('span', { class: 'small', text: c.detail || '' })))));
    } catch (e) { clear(results); results.append(h('p', { class: 'field-error', text: e.message })); }
    finally { checkBtn.disabled = false; }
  });
  const checker = h('section', { class: 'card stack', 'aria-label': 'Check keys' },
    h('div', { class: 'row-between' },
      h('div', null, h('h2', { text: 'Check keys' }), h('p', { class: 'small', text: 'Confirms each needed key is set and visible. Values are never shown.' })),
      h('div', { class: 'row' }, h('label', { class: 'row small', for: 'probe' }, probe, 'Probe providers (makes network calls)'), checkBtn)),
    results);

  const rows = (k.keys || []).map((key) => h('tr', null,
    td(h('code', { text: key.name }), 'strong'),
    td(key.set ? h('span', { class: 'status st-good' }, h('span', { class: 'g', 'aria-hidden': 'true', text: '✓' }), 'Set ', h('span', { class: 'mono', 'aria-label': `ending ${key.last4}`, text: `••••${key.last4 || ''}` }))
      : h('span', { class: 'status st-none' }, h('span', { class: 'g', 'aria-hidden': 'true', text: '—' }), 'Not set')),
    td(key.used_by?.length ? h('ul', { class: 'used-by' }, key.used_by.map((u) => h('li', { text: u }))) : h('span', { class: 'muted', text: 'Nothing yet' })),
    td(key.needed ? (key.set ? h('span', { class: 'chip chip-accent', text: 'needed' }) : statusEl('off', 'Needed, missing')) : h('span', { class: 'chip', text: 'optional' })),
    td(key.set ? okEl(key.in_console_env, 'Yes', 'No, restart the console') : h('span', { class: 'muted', text: '—' })),
    td(timeEl(key.updated_at)),
    td(h('div', { class: 'row' },
      h('button', { class: 'btn btn-sm', type: 'button', text: key.set ? 'Replace' : 'Set', onclick: () => setKeyDialog(key.name, key.set) }),
      key.set ? h('button', { class: 'btn btn-sm btn-danger', type: 'button', text: 'Remove', onclick: () => removeKey(key.name) }) : null))));
  return [
    pageHead('Keys', 'API keys live in one file outside every repo. This page writes that file; it never shows a value back.',
      h('button', { class: 'btn', type: 'button', text: 'Add another key', onclick: () => setKeyDialog(null, false) })),
    header,
    tableWrap(['Name', 'Status', 'Used by', 'Needed', 'In this console’s env', 'Updated', { label: 'Actions' }], rows, { caption: 'API keys', focusable: true, label: 'API keys table' }),
    checker,
  ];
}
function setKeyDialog(name, isSet) {
  const nameId = nextId('kn');
  const valId = nextId('kv');
  const nameInput = name ? null : h('input', { id: nameId, type: 'text', autocomplete: 'off', spellcheck: 'false', placeholder: 'MY_PROVIDER_API_KEY' });
  const val = h('input', { id: valId, type: 'password', autocomplete: 'off', spellcheck: 'false', 'aria-describedby': `${valId}-h` });
  val.style.width = '100%';
  if (nameInput) nameInput.style.width = '100%';
  const err = h('div', { class: 'field-error', 'aria-live': 'polite' });
  openDialog({
    title: name ? `${isSet ? 'Replace' : 'Set'} ${name}` : 'Add a key',
    lede: 'Written to the keys file with owner-only permissions. The value is not shown again; only its last four characters are.',
    body: [
      nameInput ? h('div', { class: 'field' }, h('label', { class: 'field-label', for: nameId, text: 'Name' }), nameInput,
        h('span', { class: 'field-help', text: 'Capital letters, digits and underscores, 3 to 64 characters.' })) : null,
      h('div', { class: 'field' }, h('label', { class: 'field-label', for: valId, text: 'Value' }), val,
        h('span', { class: 'field-help', id: `${valId}-h`, text: 'Paste the key. It goes straight to the console server and is not kept in this page.' })),
      err,
    ],
    initialFocus: name ? 'input[type="password"]' : 'input[type="text"]',
    actions: [
      { label: 'Cancel' },
      {
        label: 'Save', kind: 'primary',
        onClick: async (d) => {
          const keyName = name || nameInput.value.trim();
          if (!KEY_NAME.test(keyName)) { err.textContent = 'Use capital letters, digits and underscores, starting with a letter (3–64 characters).'; return; }
          if (!val.value) { err.textContent = 'Paste a value first.'; val.focus(); return; }
          let res;
          try {
            res = await apiPost('/api/keys', { name: keyName, value: val.value });
          } catch (e) {
            err.textContent = e.message;
            return;
          } finally {
            val.value = '';
          }
          d.close();
          notifySaved(`${keyName} saved. Logged as ${res.audit_id}; key changes are not undoable.`);
          await refreshState();
          renderView();
        },
      },
    ],
    onClose: () => { val.value = ''; },
  });
}
async function removeKey(name) {
  const ok = await confirmDialog({
    title: `Remove ${name}?`,
    body: h('p', { text: 'This deletes the line from the keys file. Providers and backends that need it stop working until it is set again. This cannot be undone: the old value is never kept.' }),
    confirmLabel: 'Remove key', kind: 'danger',
  });
  if (!ok) return;
  try {
    const res = await apiPost('/api/keys', { name, remove: true });
    notifySaved(`${name} removed. Logged as ${res.audit_id}.`);
    await refreshState();
    renderView();
  } catch (e) { toastError(e); }
}

// ---------------------------------------------------------------- audit --
async function viewAudit() {
  const a = await apiGet('/api/audit?limit=100');
  const entries = a.entries || [];
  const byId = new Map(entries.map((e) => [e.id, e]));
  const list = h('section', { class: 'card', 'aria-label': 'Audit log' });
  const focusId = ui.auditFocus;
  ui.auditFocus = null;
  if (!entries.length) list.append(h('p', { class: 'empty', text: 'Nothing logged yet. Every change made here will be listed.' }));
  for (const e of entries) {
    let action;
    if (e.undone_by) action = h('span', { class: 'muted small' }, 'Undone by ', h('code', { text: e.undone_by }));
    else if (e.undoable) {
      action = h('button', {
        class: 'btn btn-sm', type: 'button', text: 'Undo', 'aria-label': `Undo ${e.summary}`,
        onclick: async () => {
          const ok = await confirmDialog({ title: 'Undo this change?', body: [h('p', { text: e.summary }), changeList(e.changes), h('p', { class: 'small muted', text: 'The undo is itself logged.' })], confirmLabel: 'Undo' });
          if (ok) undoAudit(e.id, () => renderView());
        },
      });
    } else action = h('span', { class: 'muted small', text: e.kind === 'keys' ? 'Not undoable (values are never kept)' : 'Not undoable' });
    const undoes = /^Undo (a-[\w-]+)/.exec(e.summary || '');
    list.append(h('div', { class: ['audit-item', e.id === focusId && 'audit-focus'], id: `audit-${e.id}`, tabindex: e.id === focusId ? '-1' : null },
      h('div', { class: 'audit-when' }, h('div', null, timeEl(e.at, 'abs')), rel(e.at) !== fmtTime(e.at) ? h('div', { class: 'small', text: rel(e.at) }) : null),
      h('div', null,
        h('div', { class: 'row' }, h('span', { class: 'chip', text: e.kind }), h('span', { class: 'muted small', text: e.repo ? repoName(e.repo) : 'console' }), h('code', { class: 'muted', text: e.id })),
        h('div', { class: 'audit-summary', text: e.summary }),
        changeList(e.changes),
        undoes && byId.has(undoes[1]) ? h('p', { class: 'small muted', text: `Reverts ${undoes[1]}.` }) : null),
      h('div', null, action)));
  }
  if (focusId) {
    requestAnimationFrame(() => {
      const el = document.getElementById(`audit-${focusId}`);
      if (el) { el.scrollIntoView({ block: 'center' }); el.focus({ preventScroll: true }); }
    });
  }
  return [
    pageHead('Audit', 'Every change made from this console, newest first. Undo writes a new entry; nothing is erased.',
      h('button', { class: 'btn', type: 'button', text: 'Refresh', onclick: () => renderView() })),
    list,
  ];
}

// ---------------------------------------------------------------- theme --
function applyTheme(mode) {
  const root = document.documentElement;
  if (mode === 'light' || mode === 'dark') root.setAttribute('data-theme', mode);
  else root.removeAttribute('data-theme');
  const host = document.getElementById('theme-toggle');
  clear(host);
  for (const m of [['light', 'Light'], ['dark', 'Dark'], ['system', 'System']]) {
    host.append(h('button', {
      type: 'button', text: m[1], 'aria-pressed': String((mode || 'system') === m[0]),
      onclick: () => { store.set('theme', m[0]); applyTheme(m[0]); rerenderCharts(); },
    }));
  }
}
function rerenderCharts() {
  if (ui.tab === 'metrics') renderView();
}

// ----------------------------------------------------------------- boot --
async function boot() {
  applyTheme(store.get('theme', 'system'));
  if (DEMO) document.getElementById('demo-chip').hidden = false;
  renderTabs();
  try {
    await refreshState();
  } catch (e) {
    const view = document.getElementById('view');
    clear(view);
    view.append(errorCard(e, () => location.reload()));
    view.setAttribute('aria-busy', 'false');
    return;
  }
  renderView();
}
boot();
