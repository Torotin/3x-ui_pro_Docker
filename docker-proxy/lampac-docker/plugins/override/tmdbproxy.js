(function () {
  'use strict';

  // Always route TMDB via Lampac. Relative paths avoid wrong http/https from listen.scheme.
  // With accsdb.enable, /tmdb/img and /tmdb/api require a known account uid (init.conf users).
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

  Lampa.Storage.set('proxy_tmdb', 'true');

  Lampa.TMDB.image = function (url) {
    return '/tmdb/img/' + account(url);
  };

  Lampa.TMDB.api = function (url) {
    return '/tmdb/api/3/' + account(url);
  };

  Lampa.Settings.listener.follow('open', function (e) {
    if (e.name == 'tmdb') {
      e.body.find('[data-parent="proxy"]').remove();
    }
  });
})();
