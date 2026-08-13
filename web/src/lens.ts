import { $, esc, fmtDelta, Lang, RaceName, RACE_COLORS, setDocumentLang } from './shared.js';

const API = 'https://sc2pulse.nephest.com/sc2/api';
const RACE_BY_ID: Record<string, RaceName> = { 1: 'TERRAN', 2: 'PROTOSS', 3: 'ZERG', 4: 'RANDOM' };
const MAX_OPPONENTS = 30;

interface SearchResult {
  ratingMax?: number;
  totalGamesPlayed?: number;
  members: {
    character: { id: number; name: string; region?: string };
    account?: { battleTag?: string };
  };
}

interface Point { day: number; x: number; y: number; }

interface Opponent {
  uid: string;
  race: RaceName;
  name: string;
  btag: string;
  characterId?: number;
  pro?: string;
  rating?: number;
  faced: number;
  wins: number;
  losses: number;
  lastDate: string;
  points: Point[];
  d30: number | null;
  mmr: number | null;
  wl: number;
}

type SortKey = 'name' | 'btag' | 'race' | 'faced' | 'wl' | 'mmr' | 'd30';

interface Strings {
  subtitle: string;
  placeholder: string;
  search: string;
  searching: string;
  results: (n: number) => string;
  noResults: string;
  loadingMatches: string;
  loadingHistories: (a: number, b: number) => string;
  no1v1: string;
  chartFail: string;
  reset: string;
  resultsHead: string[];
  card: (n: number, w: number, l: number, d: string) => string;
  oppHead: () => [SortKey, string][];
  myDelta: (d: string) => string;
  langLabel: string;
}

const state = {
  lang: 'en' as Lang,
  days: 30,
  char: null as SearchResult | null,
  opps: [] as Opponent[],
  me: null as { uid?: string; name: string; points: Point[]; d30: number | null } | null,
  raceFilter: null as RaceName | null,
  soloUid: null as string | null,
  sortKey: 'faced' as SortKey,
  sortDir: -1,
};

const I18N: Record<Lang, Strings> = {
  en: {
    subtitle: 'Search a player to see recent 1v1 opponents’ MMR trends',
    placeholder: 'Player name or BattleTag, e.g. Serral',
    search: 'Search',
    searching: 'Searching…',
    results: n => `${n} results, click to view`,
    noResults: 'No results',
    loadingMatches: 'Loading matches…',
    loadingHistories: (a, b) => `Loading opponent MMR history… ${a}/${b}`,
    no1v1: 'No recent 1v1 matches',
    chartFail: 'Chart library failed to load; the table below still works',
    reset: 'Reset',
    resultsHead: ['Character', 'BattleTag', 'Region', 'Max MMR', 'Games'],
    card: (n, w, l, d) => `<div>Opponents <span>${n}</span>, record <span>${w}–${l}</span></div>
      <div>Opp ${state.days}d MMR Δ median <span>${d}</span></div>`,
    oppHead: () => [
      ['name', 'Opponent'], ['btag', 'BattleTag'], ['race', 'Race'],
      ['faced', 'Met'], ['wl', 'W–L'], ['mmr', 'MMR'], ['d30', `${state.days}d Δ`],
    ],
    myDelta: d => `${d} MMR in ${state.days} days`,
    langLabel: '中文',
  },
  zh: {
    subtitle: '搜索玩家，查看近期 1v1 对手的 MMR 变化',
    placeholder: '玩家名或 BattleTag，如 Serral',
    search: '搜索',
    searching: '搜索中…',
    results: n => `${n} 个结果，点击查看`,
    noResults: '无结果',
    loadingMatches: '拉取比赛记录…',
    loadingHistories: (a, b) => `拉取对手 MMR 历史… ${a}/${b}`,
    no1v1: '近期没有 1v1 比赛记录',
    chartFail: '图表库加载失败，下方表格仍可用',
    reset: '重置',
    resultsHead: ['角色', 'BattleTag', '地区', '最高 MMR', '总场次'],
    card: (n, w, l, d) => `<div>对手 <span>${n}</span> 人，战绩 <span>${w}–${l}</span></div>
      <div>对手 ${state.days} 天 MMR Δ 中位 <span>${d}</span></div>`,
    oppHead: () => [
      ['name', '对手'], ['btag', 'BattleTag'], ['race', '种族'],
      ['faced', '交手'], ['wl', '胜–负'], ['mmr', '当前 MMR'], ['d30', `${state.days} 天 Δ`],
    ],
    myDelta: d => `近 ${state.days} 天 ${d} MMR`,
    langLabel: 'EN',
  },
};

const t = (): Strings => I18N[state.lang];
const status = (msg = ''): void => { $('status').textContent = msg; };
let chart: any = null;
let hoverIdx: number | null = null;

async function get(path: string, params: Record<string, string | number>): Promise<any> {
  const query = new URLSearchParams(params as Record<string, string>);
  const r = await fetch(`${API}${path}?${query}`);
  if (!r.ok) throw new Error(`Pulse API ${r.status}`);
  return r.json();
}

function applyLang(): void {
  $('subtitle').textContent = t().subtitle;
  $<HTMLInputElement>('q').placeholder = t().placeholder;
  $('go').textContent = t().search;
  $('lang-toggle').innerHTML = `<b>${t().langLabel}</b>`;
  $('results-head').innerHTML = t().resultsHead
    .map((h, i) => `<th class="${i >= 3 ? 'num' : ''}">${h}</th>`).join('');
  if (state.opps.length) renderDetail();
}

async function search(): Promise<void> {
  const q = $<HTMLInputElement>('q').value.trim();
  if (!q) return;
  status(t().searching);
  $('detail').style.display = 'none';
  try {
    const found: SearchResult[] = await get('/characters', { query: q });
    const body = $('results-body');
    body.innerHTML = '';
    for (const c of found.slice(0, 20)) {
      const ch = c.members.character;
      const tr = document.createElement('tr');
      tr.className = 'sel';
      tr.innerHTML = `<td>${esc(ch.name)}</td><td>${esc(c.members.account?.battleTag)}</td>
        <td>${esc(ch.region)}</td>
        <td class="num">${c.ratingMax ?? '–'}</td><td class="num">${c.totalGamesPlayed ?? '–'}</td>`;
      tr.onclick = () => load(c);
      body.appendChild(tr);
    }
    $('results').style.display = 'block';
    status(found.length ? t().results(found.length) : t().noResults);
  } catch (e) { status((e as Error).message); }
}

function collectOpponents(matches: any[], myId: number): Opponent[] {
  const opps = new Map<string, Opponent>();
  for (const m of matches) {
    if (m.match.type !== '_1V1' || m.participants.length !== 2) continue;
    const mine = m.participants.find((p: any) => p.participant.playerCharacterId === myId);
    const theirs = m.participants.find((p: any) => p.participant.playerCharacterId !== myId);
    if (!mine || !theirs || !theirs.team) continue;
    const uid: string = theirs.team.legacyUid;
    const race = RACE_BY_ID[(uid.match(/\.([1-4])$/) || [])[1]];
    if (!race) continue;
    const member = theirs.team.members[0];
    const o = opps.get(uid) ?? {
      uid, race,
      name: (member?.character.name || '?').split('#')[0],
      btag: member?.account?.battleTag || '',
      characterId: member?.character.id,
      pro: member?.proNickname,
      rating: theirs.team.rating,
      faced: 0, wins: 0, losses: 0,
      lastDate: m.match.date,
      points: [], d30: null, mmr: null, wl: 0,
    };
    o.faced++;
    if (mine.participant.decision === 'WIN') o.wins++;
    if (mine.participant.decision === 'LOSS') o.losses++;
    opps.set(uid, o);
  }
  return [...opps.values()]
    .sort((a, b) => +new Date(b.lastDate) - +new Date(a.lastDate))
    .slice(0, MAX_OPPONENTS);
}

async function fetchHistories(uids: string[]): Promise<Map<string, Point[]>> {
  const from = new Date(Date.now() - state.days * 86400e3).toISOString();
  const byUid = new Map<string, Point[]>();
  for (let i = 0; i < uids.length; i += 10) {
    const chunk = uids.slice(i, i + 10);
    status(t().loadingHistories(Math.min(i + 10, uids.length), uids.length));
    const rows = await get('/team-histories', {
      teamLegacyUid: chunk.join(','), history: 'TIMESTAMP,RATING', from,
    });
    for (const row of rows ?? []) {
      byUid.set(row.staticData.LEGACY_UID, dailyLast(row.history.TIMESTAMP, row.history.RATING));
    }
  }
  return byUid;
}

function dailyLast(ts: number[], rating: number[]): Point[] {
  const out: Point[] = [];
  for (let i = 0; i < ts.length; i++) {
    const point = { day: Math.floor(ts[i] / 86400), x: ts[i] * 1000, y: rating[i] };
    if (out.length && out[out.length - 1].day === point.day) out[out.length - 1] = point;
    else out.push(point);
  }
  return out;
}

const delta = (points: Point[]): number | null =>
  points.length > 1 ? points[points.length - 1].y - points[0].y : null;

async function load(c: SearchResult): Promise<void> {
  state.char = c;
  const myId = c.members.character.id;
  $('results').style.display = 'none';
  $('detail').style.display = 'block';
  $('player-title').innerHTML = esc(c.members.character.name.split('#')[0]) +
    (c.members.account?.battleTag ? ` <span class="btag">${esc(c.members.account.battleTag)}</span>` : '');
  $('cards').innerHTML = '';
  $('opp-body').innerHTML = '';
  state.opps = [];
  state.me = null;
  state.raceFilter = null;
  state.soloUid = null;
  status(t().loadingMatches);
  try {
    const page = await get('/character-matches', { characterId: myId, type: '_1V1', limit: 100 });
    const matches: any[] = page.result ?? [];
    const opps = collectOpponents(matches, myId);
    if (!opps.length) { status(t().no1v1); return; }

    const myTeams = new Map<string, number>();
    for (const m of matches) {
      const mine = m.participants.find((p: any) => p.participant.playerCharacterId === myId);
      if (mine?.team) myTeams.set(mine.team.legacyUid, (myTeams.get(mine.team.legacyUid) ?? 0) + 1);
    }
    const myUid = [...myTeams.entries()].sort((a, b) => b[1] - a[1])[0]?.[0];

    const histories = await fetchHistories(myUid ? [...opps.map(o => o.uid), myUid] : opps.map(o => o.uid));
    for (const o of opps) {
      o.points = histories.get(o.uid) ?? [];
      o.d30 = delta(o.points);
      o.mmr = o.points.at(-1)?.y ?? o.rating ?? null;
      o.wl = o.wins * 1000 - o.losses;
    }
    const myPoints = myUid ? histories.get(myUid) ?? [] : [];
    state.me = {
      uid: myUid,
      name: c.members.character.name.split('#')[0],
      points: myPoints,
      d30: delta(myPoints),
    };
    state.opps = opps;
    renderDetail();
    status();
  } catch (e) { status((e as Error).message); }
}

function renderDetail(): void {
  $('player-delta').textContent = state.me?.d30 != null ? t().myDelta(fmtDelta(state.me.d30)) : '';
  $('days-toggle').innerHTML = state.days === 30 ? '<b>30d</b> · 90d' : '30d · <b>90d</b>';
  renderCards();
  renderChart();
  renderTable();
}

function renderCards(): void {
  const cards = $('cards');
  cards.innerHTML = '';
  for (const race of ['TERRAN', 'PROTOSS', 'ZERG', 'RANDOM'] as RaceName[]) {
    const group = state.opps.filter(o => o.race === race);
    if (!group.length) continue;
    const wins = group.reduce((s, o) => s + o.wins, 0);
    const losses = group.reduce((s, o) => s + o.losses, 0);
    const deltas = group.map(o => o.d30).filter((d): d is number => d !== null).sort((a, b) => a - b);
    const med = deltas.length ? fmtDelta(deltas[deltas.length >> 1]) : '–';
    const el = document.createElement('div');
    el.className = 'card' + (state.raceFilter === race ? ' active' : '');
    el.innerHTML = `<b class="race ${race}">${race}</b>` + t().card(group.length, wins, losses, med);
    el.onclick = () => {
      state.raceFilter = state.raceFilter === race ? null : race;
      state.soloUid = null;
      renderDetail();
    };
    cards.appendChild(el);
  }
}

const filtered = (): Opponent[] =>
  state.raceFilter ? state.opps.filter(o => o.race === state.raceFilter) : state.opps;

function renderTable(): void {
  const head = $('opp-head');
  head.innerHTML = t().oppHead()
    .map(([k, h], i) => {
      const arrow = state.sortKey === k ? (state.sortDir > 0 ? ' ↑' : ' ↓') : '';
      return `<th class="${i >= 3 ? 'num' : ''}" data-k="${k}">${h}${arrow}</th>`;
    }).join('');
  for (const th of head.querySelectorAll('th')) {
    th.addEventListener('click', () => {
      const k = (th as HTMLElement).dataset.k as SortKey;
      if (state.sortKey === k) state.sortDir *= -1;
      else { state.sortKey = k; state.sortDir = -1; }
      renderTable();
    });
  }

  const rows = [...filtered()].sort((a, b) => {
    const va = a[state.sortKey];
    const vb = b[state.sortKey];
    if (va === null || va === undefined) return 1;
    if (vb === null || vb === undefined) return -1;
    const cmp = typeof va === 'string' ? va.localeCompare(vb as string) : (va as number) - (vb as number);
    return cmp * state.sortDir;
  });

  const body = $('opp-body');
  body.innerHTML = '';
  for (const o of rows) {
    const tr = document.createElement('tr');
    tr.innerHTML = `<td>${esc(o.name)}${o.pro ? ` <span class="race ${o.race}">[${esc(o.pro)}]</span>` : ''}</td>
      <td><span class="btag">${esc(o.btag)}</span></td>
      <td class="race ${o.race}">${o.race[0]}</td>
      <td class="num">${o.faced}</td><td class="num">${o.wins}–${o.losses}</td>
      <td class="num">${o.mmr ?? '–'}</td>
      <td class="num">${fmtDelta(o.d30)}</td>`;
    if (o.characterId) {
      const nameCell = tr.firstElementChild as HTMLElement;
      nameCell.classList.add('plink');
      nameCell.onclick = () => loadOpp(o);
    }
    body.appendChild(tr);
  }
}

function loadOpp(o: Opponent): void {
  $<HTMLInputElement>('q').value = o.name;
  load({
    members: {
      character: { id: o.characterId as number, name: o.name },
      account: { battleTag: o.btag },
    },
  });
}

function renderChart(): void {
  if (typeof Chart === 'undefined') { status(t().chartFail); return; }
  let opps = filtered().filter(o => o.points.length > 1);
  if (state.soloUid) {
    const solo = opps.filter(o => o.uid === state.soloUid);
    if (solo.length) opps = solo; else state.soloUid = null;
  }
  const datasets: any[] = opps.map(o => ({
    label: `${o.name} (${o.race[0]})`,
    uid: o.uid,
    data: o.points,
    baseColor: RACE_COLORS[o.race], baseAlpha: '73', baseWidth: 1.1,
    borderColor: RACE_COLORS[o.race] + '73',
    borderWidth: 1.1,
    pointRadius: 0,
    parsing: false,
  }));
  if (state.me && state.me.points.length > 1) {
    datasets.push({
      label: state.me.name,
      uid: state.me.uid,
      me: true,
      data: state.me.points,
      baseColor: '#e8eaed', baseAlpha: 'ff', baseWidth: 2.4,
      borderColor: '#e8eaed',
      borderWidth: 2.4,
      pointRadius: 0,
      parsing: false,
    });
  }
  $('chartwrap').style.display = datasets.length ? 'block' : 'none';
  $('chart-reset').textContent = t().reset;
  $('chart-reset').style.display = state.soloUid ? 'block' : 'none';
  chart?.destroy();
  hoverIdx = null;
  if (!datasets.length) return;
  chart = new Chart($('chart'), {
    type: 'line',
    data: { datasets },
    options: {
      animation: false,
      responsive: true,
      maintainAspectRatio: false,
      interaction: { mode: 'nearest', intersect: false },
      onClick: (e: any, _els: any, ch: any) => {
        const els = ch.getElementsAtEventForMode(e, 'nearest', { intersect: false }, true);
        if (!els.length) return;
        const d = ch.data.datasets[els[0].datasetIndex];
        if (d.me) return;
        state.soloUid = state.soloUid === d.uid ? null : d.uid;
        renderChart();
      },
      onHover: (e: any, _els: any, ch: any) => {
        const els = ch.getElementsAtEventForMode(e, 'nearest', { intersect: false }, true);
        const idx = els.length ? els[0].datasetIndex : null;
        if (idx === hoverIdx) return;
        hoverIdx = idx;
        ch.data.datasets.forEach((d: any, i: number) => {
          if (d.me || idx === null) {
            d.borderColor = d.baseColor + (d.baseAlpha === 'ff' ? '' : d.baseAlpha);
            d.borderWidth = d.baseWidth;
          } else {
            d.borderColor = d.baseColor + (i === idx ? '' : '2e');
            d.borderWidth = i === idx ? Math.max(d.baseWidth, 2.2) : d.baseWidth;
          }
        });
        ch.update('none');
      },
      plugins: {
        legend: { display: false },
        tooltip: {
          callbacks: {
            title: (items: any[]) => new Date(items[0].parsed.x).toLocaleDateString(),
            label: (item: any) => `${item.dataset.label}: ${item.parsed.y}`,
          },
        },
      },
      scales: {
        x: {
          type: 'linear',
          grid: { color: '#2b2f37' },
          ticks: {
            color: '#7f8791', maxTicksLimit: 10,
            callback: (v: number) =>
              new Date(v).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }),
          },
        },
        y: {
          title: { display: true, text: 'MMR', color: '#7f8791' },
          grid: { color: '#2b2f37' },
          ticks: { color: '#7f8791' },
        },
      },
    },
  });
}

$('go').addEventListener('click', search);
$('q').addEventListener('keydown', e => { if ((e as KeyboardEvent).key === 'Enter') search(); });
$('chart-reset').addEventListener('click', () => {
  state.soloUid = null;
  renderChart();
});
$('days-toggle').addEventListener('click', () => {
  state.days = state.days === 30 ? 90 : 30;
  if (state.char) load(state.char);
});
$('lang-toggle').addEventListener('click', () => {
  state.lang = state.lang === 'en' ? 'zh' : 'en';
  setDocumentLang(state.lang);
  applyLang();
});
applyLang();
