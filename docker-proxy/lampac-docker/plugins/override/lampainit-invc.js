// Force Lampac TMDB proxy for all clients (string 'true' — Lampa.Storage.field toggle).
// Default lampainit only enables proxy when GeoIP {country} == 'RU'.
// Also persist accsdb account id from privateinit.js?uid=… for /tmdb/* auth.
// CUB sync WebSocket stays enabled (stock lampainit socket_use=true).

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

function lampainit_apply_local() {
  Lampa.Storage.set('proxy_tmdb', 'true');
  lampainit_capture_accsdb_uid();
}

lampainit_invc.appload = function appload() {
  lampainit_apply_local();
};

lampainit_invc.appready = function appready() {
  lampainit_apply_local();
};

lampainit_invc.first_initiale = function firstinitiale() {
  lampainit_apply_local();
};
