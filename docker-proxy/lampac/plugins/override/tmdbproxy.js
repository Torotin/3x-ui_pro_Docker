(function () {
  'use strict';

  // Always route TMDB via Lampac. Relative paths avoid wrong http/https from listen.scheme.
  // Stock lampainit first_initiale can set proxy_tmdb=false when GeoIP {country} is empty
  // behind Traefik ('' == 'RU'). Episode stills use TMDB.img → TMDB.image — keep override hot.
  // privateinit.js is loaded as ?uid=demo|family — prefer that over random lampac_unic_id.
  var unic_id = Lampa.Storage.get('lampac_unic_id', '');
  if (!unic_id) {
    unic_id = Lampa.Utils.uid(8).toLowerCase();
    Lampa.Storage.set('lampac_unic_id', unic_id);
  }

  function resolveAccsdbUid() {
    var stored = Lampa.Storage.get('lampac_accsdb_uid', '');
    if (stored) return stored;

    try {
      var scripts = document.getElementsByTagName('script');
      for (var i = 0; i < scripts.length; i++) {
        var src = scripts[i].getAttribute('src') || '';
        var m = src.match(/[?&]uid=([^&]+)/i);
        if (m && m[1] && m[1].indexOf('{') === -1) {
          var id = decodeURIComponent(m[1]);
          if (id) {
            Lampa.Storage.set('lampac_accsdb_uid', id);
            return id;
          }
        }
      }
    } catch (e) {}

    var email = Lampa.Storage.get('account_email');
    if (email) return email;
    return unic_id;
  }

  function account(url) {
    if (url.indexOf('account_email=') == -1) {
      var email = Lampa.Storage.get('account_email');
      if (email) url = Lampa.Utils.addUrlComponent(url, 'account_email=' + encodeURIComponent(email));
    }
    if (url.indexOf('uid=') == -1) {
      var uid = resolveAccsdbUid();
      if (uid) url = Lampa.Utils.addUrlComponent(url, 'uid=' + encodeURIComponent(uid));
    }
    if (url.indexOf('token=') == -1) {
      var token = '{token}';
      if (token != '') url = Lampa.Utils.addUrlComponent(url, 'token={token}');
    }
    return url;
  }

  // TMDB.img(still_path, size) builds t/p/{size}/+src; some episode cards pass
  // 't/p/w300'+still_path already — collapse duplicate prefixes and hosts.
  function normalizeImgPath(url) {
    if (!url || typeof url !== 'string') return url;
    url = url.replace(/^https?:\/\/image\.tmdb\.org\//i, '');
    url = url.replace(/^\/+/, '');
    url = url.replace(/^(t\/p\/[^/]+\/)+(?=t\/p\/)/, '');
    url = url.replace(/^(t\/p\/[^/]+)\/{2,}/, '$1/');
    return url;
  }

  function forceProxyFlags() {
    try {
      Lampa.Storage.set('proxy_tmdb', 'true');
      // Stock image()/api() fall back to these when override is late/missing.
      if (!Lampa.Storage.get('tmdb_proxy_image', '')) {
        Lampa.Storage.set('tmdb_proxy_image', '/tmdb/img');
      }
      if (!Lampa.Storage.get('tmdb_proxy_api', '')) {
        Lampa.Storage.set('tmdb_proxy_api', '/tmdb/api');
      }
    } catch (e) {}
  }

  forceProxyFlags();

  Lampa.TMDB.image = function (url) {
    return '/tmdb/img/' + account(normalizeImgPath(url));
  };

  Lampa.TMDB.api = function (url) {
    return '/tmdb/api/3/' + account(url);
  };

  Lampa.Settings.listener.follow('open', function (e) {
    if (e.name == 'tmdb') {
      e.body.find('[data-parent="proxy"]').remove();
    }
  });

  // Re-assert after lampainit first_initiale (GeoIP empty → proxy_tmdb false).
  setTimeout(forceProxyFlags, 0);
  setTimeout(forceProxyFlags, 2000);
})();
