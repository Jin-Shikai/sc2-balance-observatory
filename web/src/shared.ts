export type Lang = 'en' | 'zh';

export type RaceName = 'TERRAN' | 'PROTOSS' | 'ZERG' | 'RANDOM';

export const RACE_COLORS: Record<RaceName, string> = {
  TERRAN: '#4f8fd1',
  PROTOSS: '#d4b23c',
  ZERG: '#9b59d0',
  RANDOM: '#8a9199',
};

export const $ = <T extends HTMLElement = HTMLElement>(id: string): T =>
  document.getElementById(id) as T;

export const esc = (s: unknown): string => {
  const d = document.createElement('span');
  d.textContent = s == null ? '' : String(s);
  return d.innerHTML;
};

export const fmtDelta = (d: number | null): string =>
  d === null ? '–' : (d > 0 ? '+' : '') + d;

export function setDocumentLang(lang: Lang): void {
  document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
}
