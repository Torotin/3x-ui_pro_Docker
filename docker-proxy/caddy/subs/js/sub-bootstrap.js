(function () {
  const cfgEl = document.getElementById('sub-config');
  let cfg = {};
  try {
    cfg = JSON.parse(cfgEl?.textContent || '{}');
  } catch (_) {
    cfg = {};
  }

  const rawSubPath = cfg.URI_SUB_PATH || '';
  const rawJsonPath = cfg.URI_JSON_PATH || '';
  const rawDomain = cfg.WEBDOMAIN || '';
  const strip = (s) => String(s || '').replace(/^\/+|\/+$/g, '');
  const segments = window.location.pathname.replace(/\/+$/, '').split('/').filter(Boolean);
  const params = new URLSearchParams(window.location.search);
  let sid = params.get('name') || params.get('id') || '';
  const subNeedle = strip(rawSubPath);
  const jsonNeedle = strip(rawJsonPath || rawSubPath);
  const resolveFromNeedle = (needle) => {
    if (sid || !needle) return;
    const idx = segments.indexOf(needle);
    if (idx !== -1 && segments[idx + 1]) {
      sid = decodeURIComponent(segments[idx + 1]);
    }
  };
  resolveFromNeedle(subNeedle);
  resolveFromNeedle(jsonNeedle);
  if (!sid && segments.length) {
    const last = segments[segments.length - 1];
    if (last !== subNeedle && last !== jsonNeedle) {
      sid = decodeURIComponent(last);
    }
  }
  if (!sid) sid = 'subscription-id';

  const subPath = '/' + subNeedle;
  const jsonPath = '/' + jsonNeedle;
  const origin = window.location.origin || `https://${rawDomain}`;
  const subUrl = `${origin}${subPath}/${encodeURIComponent(sid)}`;
  const subJsonUrl = `${origin}${jsonPath}/${encodeURIComponent(sid)}`;
  const baseHref = `${subPath}/${encodeURIComponent(sid)}/`;
  const assetBase = `${baseHref}assets/`;

  const baseEl = document.createElement('base');
  baseEl.href = baseHref;
  document.head.appendChild(baseEl);

  window.__SUBPAGE = {
    sid,
    subPath,
    jsonPath,
    subUrl,
    subJsonUrl,
    domain: rawDomain,
    origin,
    baseHref,
    assetBase,
    assetVersion: cfg.ver || cfg.version || ''
  };
  if (rawDomain) {
    document.title = `${rawDomain} – Информация о подписке`;
  }

  const assetBaseUrl = new URL(assetBase, window.location.origin);
  const cssFiles = ['ant-design-vue/antd.min.css', 'css/custom.min.css'];
  const jsFiles = [
    'moment/moment.min.js',
    'moment/moment-jalali.min.js',
    'vue/vue.min.js',
    'ant-design-vue/antd.min.js',
    'js/util/index.js',
    'js/util/date-util.js',
    'qrcode/qrious2.min.js'
  ];

  const withVer = (file, ver) => ver ? `${file}?${encodeURIComponent(ver)}` : file;
  const loadStyle = (file, ver) => new Promise((resolve, reject) => {
    const href = new URL(withVer(file, ver), assetBaseUrl).toString();
    const link = document.createElement('link');
    link.rel = 'preload';
    link.as = 'style';
    link.href = href;
    link.onload = () => {
      link.rel = 'stylesheet';
      resolve();
    };
    link.onerror = () => reject(new Error(`Не удалось загрузить стиль ${file}`));
    document.head.appendChild(link);
  });
  const loadScript = (file, ver) => new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = new URL(withVer(file, ver), assetBaseUrl).toString();
    s.defer = true;
    s.onload = resolve;
    s.onerror = () => reject(new Error(`Не удалось загрузить скрипт ${file}`));
    document.head.appendChild(s);
  });

  const detectVersion = () => {
    const params = new URLSearchParams(window.location.search);
    const fromQuery = params.get('ver') || params.get('v') || params.get('version');
    if (fromQuery) return String(fromQuery).trim();
    const fromCtx = window.__SUBPAGE.assetVersion || '';
    if (fromCtx) return String(fromCtx).trim();
    return '';
  };

  window.__SUB_ASSETS_READY = (async () => {
    const ver = detectVersion();
    window.__SUB_ASSET_VERSION = ver;
    window.__SUB_ASSET_BASE = assetBaseUrl.href;
    for (const css of cssFiles) {
      await loadStyle(css, ver);
    }
    for (const js of jsFiles) {
      await loadScript(js, ver);
    }
    return { ver, assetBase: assetBaseUrl.href };
  })();
})();
