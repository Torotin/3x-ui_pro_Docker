// Force Lampac TMDB proxy for all clients (string 'true' — Lampa.Storage.field toggle).
// Default lampainit only enables proxy when GeoIP {country} == 'RU'.
// Also persist accsdb account id from privateinit.js?uid=… for /tmdb/* auth.
// CUB sync WebSocket stays enabled (stock lampainit socket_use=true).
//
// Alcopa hub plugins all end with /plugin.js — stock lampainit pluginBaseName()
// collapses them to family "plugin", so only the first customPlugins entry installs.
// Re-add by exact URL after start() finishes.

// alc_auto v2.1.44 free-notice: decrypts to
//   window.__alc_pack_seen + Lampa.Storage key alc_pack_seen_v1
// Plugin often runs before lampainit (Storage plugins). Window flag alone is too
// late then; Modal may also be replaced after a one-shot hook. Kill via Storage +
// perpetual Modal re-hook + DOM observer.
(function lampainit_alcopa_notice_early() {
  var KEY = 'alc_pack_seen_v1';
  var FLAG = '__alc_pack_seen';
  var stamp = String(Date.now());
  // \u escapes stay valid even if the file is re-saved as non-UTF-8
  var NEEDLES = [
    'plugins are free',
    'Lampa and these plugins are free',
    'popil_poel_bot',
    '\u0431\u0435\u0441\u043f\u043b\u0430\u0442\u043d\u044b', // бесплатны
    '\u0431\u0435\u0437\u043a\u043e\u0448\u0442\u043e\u0432\u043d\u0456', // безкоштовні
    '\u0415\u0441\u043b\u0438 \u0432\u0430\u043c \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u043b\u0438' // Если вам установили
  ];

  function textOf(params) {
    if (!params) return '';
    var parts = [];
    if (typeof params.title === 'string') parts.push(params.title);
    try {
      var h = params.html;
      if (typeof h === 'string') parts.push(h);
      else if (h && h.textContent) parts.push(h.textContent);
      else if (h && h[0] && h[0].textContent) parts.push(h[0].textContent);
    } catch (e) {}
    return parts.join(' ');
  }

  function isNoticeText(s) {
    if (!s || typeof s !== 'string') return false;
    for (var i = 0; i < NEEDLES.length; i++) {
      if (s.indexOf(NEEDLES[i]) !== -1) return true;
    }
    return false;
  }

  try {
    window[FLAG] = 1;
  } catch (e) {}
  try {
    localStorage.setItem(KEY, stamp);
  } catch (e) {}

  function markStorage() {
    try {
      window[FLAG] = 1;
    } catch (e) {}
    try {
      localStorage.setItem(KEY, stamp);
    } catch (e) {}
    try {
      if (window.Lampa && Lampa.Storage && Lampa.Storage.set) {
        Lampa.Storage.set(KEY, stamp);
      }
    } catch (e) {}
  }

  function hookModal() {
    try {
      if (!window.Lampa || !Lampa.Modal || typeof Lampa.Modal.open !== 'function') return false;
      var open = Lampa.Modal.open;
      if (open && open.__alc_notice_wrapped) return true;
      var wrapped = function (params) {
        try {
          if (isNoticeText(textOf(params))) {
            markStorage();
            return;
          }
        } catch (e) {}
        return open.apply(this, arguments);
      };
      wrapped.__alc_notice_wrapped = true;
      Lampa.Modal.open = wrapped;
      Lampa.Modal.__alc_notice_hooked = true;
      return true;
    } catch (e) {
      return false;
    }
  }

  function killDom() {
    try {
      var nodes = document.querySelectorAll('.modal, .modal__content');
      for (var i = 0; i < nodes.length; i++) {
        var el = nodes[i];
        var t = el.textContent || '';
        if (!isNoticeText(t)) continue;
        markStorage();
        var modal = el.classList && el.classList.contains('modal') ? el : el.closest && el.closest('.modal');
        if (modal && modal.parentNode) modal.parentNode.removeChild(modal);
        else if (el.parentNode) el.parentNode.removeChild(el);
        try {
          if (window.Lampa && Lampa.Modal && Lampa.Modal.close) Lampa.Modal.close();
        } catch (e2) {}
      }
    } catch (e) {}
  }

  function observe() {
    try {
      if (!document.documentElement || window.__alc_notice_obs) return;
      window.__alc_notice_obs = new MutationObserver(function () {
        killDom();
      });
      window.__alc_notice_obs.observe(document.documentElement, {
        childList: true,
        subtree: true
      });
      killDom();
    } catch (e) {}
  }

  markStorage();
  hookModal();
  observe();
  var n = 0;
  var iv = setInterval(function () {
    markStorage();
    hookModal();
    observe();
    killDom();
    n += 1;
    // Keep going long enough for auth screen + alc_auto's 6s delay (+ retries)
    if (n > 300) clearInterval(iv);
  }, 200);
})();

var lampainit_invc = {};

function lampainit_capture_accsdb_uid() {
  try {
    var scripts = document.getElementsByTagName('script');
    for (var i = 0; i < scripts.length; i++) {
      var src = scripts[i].getAttribute('src') || '';
      var m = src.match(/privateinit\.js[^'"]*[?&]uid=([^&]+)/i);
      if (m && m[1] && m[1].indexOf('{') === -1) {
        var id = decodeURIComponent(m[1]);
        if (id) {
          Lampa.Storage.set('lampac_accsdb_uid', id);
          return id;
        }
      }
    }
  } catch (e) {}
  return Lampa.Storage.get('lampac_accsdb_uid', '');
}

function lampainit_suppress_alcopa_free_notice() {
  try {
    window.__alc_pack_seen = 1;
    localStorage.setItem('alc_pack_seen_v1', String(Date.now()));
    if (window.Lampa && Lampa.Storage) {
      Lampa.Storage.set('alc_pack_seen_v1', String(Date.now()));
    }
  } catch (e) {}
}

function lampainit_apply_local() {
  // CUB domain/mirrors: leave Lampa defaults (no forced cub_domain / cub_mirrors).
  Lampa.Storage.set('proxy_tmdb', 'true');
  lampainit_capture_accsdb_uid();
  lampainit_suppress_alcopa_free_notice();
}

function lampainit_ensure_exact_plugins(list) {
  if (!window.Lampa || !Lampa.Plugins || !Lampa.Utils) return;

  var installed = Lampa.Plugins.get() || [];
  var push = [];

  list.forEach(function (plugin) {
    if (installed.some(function (p) { return p.url === plugin.url; })) return;
    Lampa.Plugins.add(plugin);
    push.push(plugin.url);
    installed.push(plugin);
  });

  if (!push.length) return;

  Lampa.Plugins.save();
  Lampa.Utils.putScript(push, function () {}, function () {}, function () {}, true);
}

// Keep in sync with LampaWeb.customPlugins (status:1 Alcopa entries) in init.conf.
function lampainit_ensure_alcopa_plugins() {
  lampainit_ensure_exact_plugins([
    {
      url: 'https://hub.alcopa.cc/dl/alc_auto/v2.1.44/plugin.js',
      name: 'Автопилот · Закусь',
      status: 1
    },
    {
      url: 'https://hub.alcopa.cc/dl/alc_trailers/v1.1.8/plugin.js',
      name: 'Трейлеры · Закусь',
      status: 1
    },
    {
      url: 'https://hub.alcopa.cc/dl/opensubs_menu/v1.2.9/plugin.js',
      name: 'OpenSubtitles · Закусь',
      status: 1
    }
  ]);
}

lampainit_invc.appload = function appload() {
  lampainit_apply_local();
};

lampainit_invc.appready = function appready() {
  lampainit_apply_local();
  // start() calls appready() before plugins_add; defer past family-dedup install.
  setTimeout(lampainit_ensure_alcopa_plugins, 0);
};

lampainit_invc.first_initiale = function firstinitiale() {
  lampainit_apply_local();
};
