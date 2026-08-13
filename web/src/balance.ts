import { $, Lang, setDocumentLang } from './shared.js';

const M_COLORS: Record<string, string> = { PvT: '#2f6fa8', TvZ: '#6fb3d8', ZvP: '#b0508c' };
const MATCHUPS = ['PvT', 'TvZ', 'ZvP'];
const LEAGUES = ['DIAMOND', 'MASTER', 'GRANDMASTER'];
const LEAGUE_LABEL: Record<Lang, Record<string, string>> = {
  en: { DIAMOND: 'Diamond', MASTER: 'Master', GRANDMASTER: 'Grandmaster' },
  zh: { DIAMOND: '钻石', MASTER: '大师', GRANDMASTER: '宗师' },
};
const REGION_LABEL: Record<Lang, Record<string, string>> = {
  en: { ALL: 'ALL', EU: 'EU', US: 'US', KR: 'KR' },
  zh: { ALL: '全部', EU: '欧服', US: '美服', KR: '韩服' },
};

type Row = Record<string, string | null>;

interface Strings {
  title: string;
  season: string;
  region: string;
  league: string;
  updated: (ts: string) => string;
  hHeatmap: string;
  hLength: string;
  hDelta: string;
  hPatch: string;
  deltaHead: [string, string][];
  langLabel: string;
}

const I18N: Record<Lang, Strings> = {
  en: {
    title: 'Balance Observatory',
    season: 'Season', region: 'Region', league: 'League',
    updated: ts => `data updated ${ts}`,
    hHeatmap: 'Winrate by matchup × league',
    hLength: 'Winrate by game length (minutes)',
    hDelta: 'Season-over-season winrate change',
    hPatch: 'Pro winrate shift, 28 days before vs after balance patches',
    deltaHead: [
      ['season_bnet_id', 'Season'], ['region', 'Region'], ['league', 'League'], ['matchup', 'Matchup'],
      ['winrate_prev_pct', 'Prev %'], ['winrate_cur_pct', 'Cur %'], ['delta_pct', 'Δ pp'],
    ],
    langLabel: '中文',
  },
  zh: {
    title: 'Balance Observatory',
    season: '赛季', region: '地区', league: '段位',
    updated: ts => `数据更新于 ${ts}`,
    hHeatmap: '对阵胜率 × 段位',
    hLength: '胜率 × 比赛时长（分钟）',
    hDelta: '赛季环比胜率变化',
    hPatch: '平衡补丁前后 28 天职业胜率变化',
    deltaHead: [
      ['season_bnet_id', '赛季'], ['region', '地区'], ['league', '段位'], ['matchup', '对阵'],
      ['winrate_prev_pct', '上季 %'], ['winrate_cur_pct', '本季 %'], ['delta_pct', 'Δ 百分点'],
    ],
    langLabel: 'EN',
  },
};

const state = {
  lang: 'en' as Lang,
  season: null as number | null,
  seasons: [] as number[],
  region: 'ALL',
  league: 'DIAMOND',
  deltaSort: { key: null as string | null, dir: -1 },
};

const data: Record<string, any> = {};
const NUM_KEYS = new Set(['season_bnet_id', 'winrate_prev_pct', 'winrate_cur_pct', 'delta_pct']);

const t = (): Strings => I18N[state.lang];
const n = (v: string | number | null | undefined): number | null => (v == null ? null : +v);
const pct = (v: number): string => (100 * v).toFixed(1) + '%';
const fmtD = (d: number | null): string => (d === null ? '–' : (d > 0 ? '+' : '') + d);
const leagueLabel = (l: string): string => LEAGUE_LABEL[state.lang][l] ?? l;
const regionLabel = (r: string): string => REGION_LABEL[state.lang][r] ?? r;

let lengthChart: any = null;
let patchChart: any = null;

async function boot(): Promise<void> {
  const names = ['profile', 'game_length', 'season_delta', 'patch_event', 'meta'];
  const loaded = await Promise.all(names.map(f =>
    fetch(`data/${f}.json`).then(r => (r.ok ? r.json() : f === 'meta' ? {} : []))));
  names.forEach((f, i) => { data[f] = loaded[i]; });

  state.seasons = [...new Set((data.profile as Row[]).map(r => n(r.season_bnet_id) as number))]
    .sort((a, b) => b - a);
  state.season = state.seasons[0];

  $<HTMLSelectElement>('f-season').onchange = e => {
    state.season = +(e.target as HTMLSelectElement).value; render();
  };
  $<HTMLSelectElement>('f-region').onchange = e => {
    state.region = (e.target as HTMLSelectElement).value; render();
  };
  $<HTMLSelectElement>('f-league').onchange = e => {
    state.league = (e.target as HTMLSelectElement).value; render();
  };
  applyLang();
}

function fillSelect(id: string, options: [string | number, string | number][], value: string | number): void {
  const el = $<HTMLSelectElement>(id);
  el.innerHTML = options.map(([v, l]) => `<option value="${v}">${l}</option>`).join('');
  el.value = String(value);
}

function refreshSelects(): void {
  fillSelect('f-season', state.seasons.map(s => [s, s]), state.season ?? '');
  fillSelect('f-region', ['ALL', 'EU', 'US', 'KR'].map(r => [r, regionLabel(r)]), state.region);
  fillSelect('f-league', LEAGUES.map(l => [l, leagueLabel(l)]), state.league);
}

function applyLang(): void {
  $('title').textContent = t().title;
  $('lang-toggle').innerHTML = `<b>${t().langLabel}</b>`;
  $('l-season').textContent = t().season;
  $('l-region').textContent = t().region;
  $('l-league').textContent = t().league;
  $('h-heatmap').textContent = t().hHeatmap;
  $('h-length').textContent = t().hLength;
  $('h-delta').textContent = t().hDelta;
  $('h-patch').textContent = t().hPatch;
  $('updated').textContent = data.meta?.generated_at
    ? t().updated(data.meta.generated_at.replace('T', ' ').replace('Z', ''))
    : '';
  refreshSelects();
  render();
}

function render(): void {
  renderHeatmap();
  renderLength();
  renderDelta();
  renderPatch();
}

function heatColor(w: number): string {
  const d = w - 0.5;
  const alpha = Math.min(Math.abs(d) / 0.05, 1) * 0.75;
  const hex = Math.round(alpha * 255).toString(16).padStart(2, '0');
  return (d >= 0 ? '#d4b23c' : '#4f8fd1') + hex;
}

function renderHeatmap(): void {
  const rows = (data.profile as Row[]).filter(r =>
    n(r.season_bnet_id) === state.season && r.region === state.region);
  const byKey = new Map(rows.map(r => [`${r.league}|${r.matchup}`, r]));
  let html = '<tr><th></th>' + MATCHUPS.map(m => `<th class="cell">${m}</th>`).join('') + '</tr>';
  for (const lg of LEAGUES) {
    const hl = lg === state.league ? ' style="color:var(--accent)"' : '';
    html += `<tr><th${hl}>${leagueLabel(lg)}</th>` + MATCHUPS.map(m => {
      const r = byKey.get(`${lg}|${m}`);
      if (!r) return '<td class="cell">–</td>';
      const w = n(r.winrate) as number;
      return `<td class="cell" style="background:${heatColor(w)}" title="${n(r.games)} games">${pct(w)}</td>`;
    }).join('') + '</tr>';
  }
  $('heatmap').innerHTML = html;
}

function renderLength(): void {
  if (typeof Chart === 'undefined') return;
  const rows = (data.game_length as Row[]).filter(r =>
    n(r.season_bnet_id) === state.season && r.region === state.region && r.league === state.league);
  const datasets = MATCHUPS.map(m => ({
    label: m,
    data: rows.filter(r => r.matchup === m)
      .map(r => ({ x: n(r.minute_bucket), y: n(r.winrate) }))
      .sort((a, b) => (a.x as number) - (b.x as number)),
    borderColor: M_COLORS[m],
    backgroundColor: M_COLORS[m],
    borderWidth: 1.8,
    pointRadius: 0,
    parsing: false,
  })).filter(d => d.data.length);
  lengthChart?.destroy();
  lengthChart = new Chart($('length-chart'), {
    type: 'line',
    data: { datasets },
    options: {
      animation: false, responsive: true, maintainAspectRatio: false,
      interaction: { mode: 'nearest', intersect: false },
      plugins: {
        legend: { labels: { color: '#cfd3da', boxWidth: 12 } },
        tooltip: { callbacks: { label: (i: any) => `${i.dataset.label}: ${pct(i.parsed.y)}` } },
      },
      scales: {
        x: { type: 'linear', grid: { color: '#2b2f37' }, ticks: { color: '#7f8791' } },
        y: {
          grid: { color: '#2b2f37' },
          ticks: { color: '#7f8791', callback: (v: number) => Math.round(v * 100) + '%' },
        },
      },
    },
  });
}

function renderDelta(): void {
  const { key, dir } = state.deltaSort;
  const rows = (data.season_delta as Row[])
    .filter(r => (state.region === 'ALL' || r.region === state.region) && r.league === state.league)
    .sort((a, b) => {
      if (!key) {
        return (Number(b.delta_significant === 'true') - Number(a.delta_significant === 'true'))
          || (Math.abs(n(b.delta_pct) as number) - Math.abs(n(a.delta_pct) as number));
      }
      const va = NUM_KEYS.has(key) ? n(a[key]) : a[key];
      const vb = NUM_KEYS.has(key) ? n(b[key]) : b[key];
      if (va === null || va === undefined) return 1;
      if (vb === null || vb === undefined) return -1;
      const cmp = typeof va === 'string' ? va.localeCompare(vb as string) : (va as number) - (vb as number);
      return cmp * dir;
    });

  let html = '<tr>' + t().deltaHead
    .map(([k, h], i) =>
      `<th class="${i >= 4 ? 'num' : ''}" data-k="${k}" style="cursor:pointer">${h}${key === k ? (dir > 0 ? ' ↑' : ' ↓') : ''}</th>`)
    .join('') + '</tr>';
  for (const r of rows) {
    const sig = r.delta_significant === 'true';
    html += `<tr${sig ? ' class="sig"' : ''} title="${r.patches_in_season ?? ''}">
      <td>${n(r.season_bnet_id)}</td><td>${regionLabel(r.region as string)}</td>
      <td>${leagueLabel(r.league as string)}</td><td>${r.matchup}</td>
      <td class="num">${r.winrate_prev_pct}</td><td class="num">${r.winrate_cur_pct}</td>
      <td class="num">${fmtD(n(r.delta_pct))}</td></tr>`;
  }
  $('delta-table').innerHTML = html;
  for (const th of $('delta-table').querySelectorAll('th[data-k]')) {
    th.addEventListener('click', () => {
      const k = (th as HTMLElement).dataset.k as string;
      if (state.deltaSort.key === k) state.deltaSort.dir *= -1;
      else state.deltaSort = { key: k, dir: -1 };
      renderDelta();
    });
  }
}

function renderPatch(): void {
  if (typeof Chart === 'undefined') return;
  const rows = data.patch_event as Row[];
  const versions = [...new Set(rows.map(r => r.version as string))];
  const byKey = new Map(rows.map(r => [`${r.version}|${r.matchup}`, r]));
  const datasets = MATCHUPS.map(m => ({
    label: m,
    data: versions.map(v => n(byKey.get(`${v}|${m}`)?.delta_pct ?? null)),
    backgroundColor: versions.map(v =>
      M_COLORS[m] + (byKey.get(`${v}|${m}`)?.delta_significant === 'true' ? '' : '59')),
    borderColor: M_COLORS[m],
    borderWidth: 1,
  }));
  patchChart?.destroy();
  patchChart = new Chart($('patch-chart'), {
    type: 'bar',
    data: { labels: versions, datasets },
    options: {
      animation: false, responsive: true, maintainAspectRatio: false,
      plugins: {
        legend: { labels: { color: '#cfd3da', boxWidth: 12 } },
        tooltip: {
          callbacks: {
            label: (i: any) => {
              const r = byKey.get(`${i.label}|${i.dataset.label}`);
              return `${i.dataset.label}: ${fmtD(n(r?.delta_pct ?? null))} pp` +
                (r?.delta_significant === 'true' ? ' *' : '') +
                ` (${n(r?.games_pre ?? null)}/${n(r?.games_post ?? null)} games)`;
            },
          },
        },
      },
      scales: {
        x: { grid: { color: '#2b2f37' }, ticks: { color: '#7f8791' } },
        y: {
          grid: { color: '#2b2f37' },
          ticks: { color: '#7f8791', callback: (v: number) => fmtD(v) + 'pp' },
        },
      },
    },
  });
}

$('lang-toggle').addEventListener('click', () => {
  state.lang = state.lang === 'en' ? 'zh' : 'en';
  setDocumentLang(state.lang);
  applyLang();
});
boot();
