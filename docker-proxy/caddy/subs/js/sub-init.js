(function () {
  const ctx = window.__SUBPAGE || {};
  const assetsPromise = window.__SUB_ASSETS_READY || Promise.resolve({ ver: '', assetBase: ctx.assetBase || 'assets/' });
  const tpl = document.getElementById('subscription-data');
  const textarea = document.getElementById('subscription-links');
  const mask = document.getElementById('loading-mask');
  const loadingText = document.getElementById('loading-text');
  const loadingError = document.getElementById('loading-error');
  const loadingRetry = document.getElementById('loading-retry');

  const showLoading = (msg) => {
    if (!mask) return;
    mask.style.display = 'flex';
    mask.classList.remove('hidden');
    if (loadingText) loadingText.textContent = msg || 'Загрузка подписки…';
    if (loadingError) loadingError.style.display = 'none';
    if (loadingRetry) loadingRetry.style.display = 'none';
  };
  const showError = (msg) => {
    if (!mask) return;
    mask.classList.remove('hidden');
    if (loadingError) {
      loadingError.textContent = msg;
      loadingError.style.display = 'block';
    }
    if (loadingRetry) loadingRetry.style.display = 'inline-block';
  };
  const hideLoading = () => {
    if (!mask) return;
    mask.classList.add('hidden');
    setTimeout(() => { mask.style.display = 'none'; }, 350);
  };
  if (loadingRetry) loadingRetry.onclick = () => window.location.reload();

  const toInt = (v) => {
    const n = parseInt(v || '0', 10);
    return Number.isFinite(n) ? n : 0;
  };
  const fmtBytes = (bytes) => {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let b = bytes;
    let u = 0;
    while (b >= 1024 && u < units.length - 1) {
      b /= 1024;
      u++;
    }
    if (b === 0) return '';
    return `${b.toFixed(u ? 2 : 0)}${units[u]}`;
  };
  const parseUserInfo = (headerVal) => {
    if (!headerVal) return null;
    const map = {};
    headerVal.split(';').forEach((pair) => {
      const [k, v] = pair.split('=').map((s) => s.trim());
      if (k) map[k.toLowerCase()] = v;
    });
    const upload = toInt(map.upload);
    const download = toInt(map.download);
    const total = toInt(map.total);
    const expire = toInt(map.expire);
    return { upload, download, total, expire };
  };

  const setDefaults = () => {
    if (!tpl) return;
    tpl.setAttribute('data-sid', ctx.sid || '');
    tpl.setAttribute('data-sub-url', ctx.subUrl || '');
    tpl.setAttribute('data-subjson-url', ctx.subJsonUrl || '');
    tpl.setAttribute('data-download', '—');
    tpl.setAttribute('data-upload', '—');
    tpl.setAttribute('data-used', '—');
    tpl.setAttribute('data-total', '—');
    tpl.setAttribute('data-remained', '—');
    tpl.setAttribute('data-expire', '0');
    tpl.setAttribute('data-lastonline', '0');
    tpl.setAttribute('data-downloadbyte', '0');
    tpl.setAttribute('data-uploadbyte', '0');
    tpl.setAttribute('data-totalbyte', '0');
    tpl.setAttribute('data-datepicker', 'gregorian');
  };

  const loadScript = (src) => new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = src;
    s.defer = true;
    s.onload = resolve;
    s.onerror = () => reject(new Error(`Не удалось загрузить ${src}`));
    document.body.appendChild(s);
  });

  const run = async () => {
    showLoading('Загрузка подписки…');
    const loadingTimeout = setTimeout(() => {
      showError('Долго загружается. Проверьте доступность ассетов и подписки.');
    }, 12000);
    setDefaults();

    if (textarea) textarea.value = '';

    if (ctx.subUrl) {
      try {
        const res = await fetch(ctx.subUrl, { headers: { Accept: 'text/plain' } });
        if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);

        const infoHeader = res.headers.get('subscription-userinfo')
          || res.headers.get('subcription-userinfo')
          || res.headers.get('x-subscription-userinfo');
        const info = parseUserInfo(infoHeader);
        if (info && tpl) {
          const usedByte = info.upload + info.download;
          const remained = info.total > 0 ? Math.max(info.total - usedByte, 0) : 0;
          tpl.setAttribute('data-downloadbyte', String(info.download));
          tpl.setAttribute('data-uploadbyte', String(info.upload));
          tpl.setAttribute('data-totalbyte', String(info.total));
          tpl.setAttribute('data-expire', String(info.expire || 0));
          tpl.setAttribute('data-download', fmtBytes(info.download) || '0B');
          tpl.setAttribute('data-upload', fmtBytes(info.upload) || '0B');
          tpl.setAttribute('data-used', fmtBytes(usedByte) || '0B');
          tpl.setAttribute('data-total', info.total > 0 ? fmtBytes(info.total) : 'Без лимита');
          tpl.setAttribute('data-remained', info.total > 0 ? fmtBytes(remained) : '');
        }

        const base64Body = (await res.text()).replace(/\s+/g, '');
        const decoded = atob(base64Body);
        if (textarea) textarea.value = decoded.trim();
      } catch (err) {
        console.error('Не удалось загрузить подписку', err);
        showError(`Ошибка загрузки подписки: ${err.message || err}`);
      }
    }

    const assets = await assetsPromise.catch((err) => {
      console.error('Загрузка ассетов не удалась, пробуем без версии', err);
      return { ver: '', assetBase: ctx.assetBase || 'assets/' };
    });
    await (window.__SUB_THEME_READY || assetsPromise).catch(() => {});

    const assetBaseUrl = new URL(assets.assetBase || ctx.assetBase || 'assets/', window.location.origin);
    const withVer = (file) => assets.ver ? `${file}?${encodeURIComponent(assets.ver)}` : file;
    const subscriptionScript = new URL(withVer('js/subscription.js'), assetBaseUrl).toString();

    // Добавляем глобальный миксин, чтобы popover/modal/drawer из manuals имели реактивные флаги
    if (window.Vue && !window.__SUB_MANUAL_FLAGS_ADDED) {
      Vue.mixin({
        data() {
          return {
            showManualModal: false,
            showManualDrawer: false
          };
        }
      });
      window.__SUB_MANUAL_FLAGS_ADDED = true;
    }

    try {
      await loadScript(subscriptionScript);
      hideLoading();
      clearTimeout(loadingTimeout);
    } catch (err) {
      console.error(err);
      showError(`Ошибка загрузки скрипта: ${err.message || err}`);
      clearTimeout(loadingTimeout);
    }
  };

  run();
})();
