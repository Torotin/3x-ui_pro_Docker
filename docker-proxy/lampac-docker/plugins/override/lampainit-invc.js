// Force Lampac TMDB proxy for all clients (string 'true' — Lampa.Storage.field toggle).
// Default lampainit only enables proxy when GeoIP {country} == 'RU'.

var lampainit_invc = {};

lampainit_invc.appload = function appload() {
  Lampa.Storage.set('proxy_tmdb', 'true');
};

lampainit_invc.appready = function appready() {
  Lampa.Storage.set('proxy_tmdb', 'true');
};

lampainit_invc.first_initiale = function firstinitiale() {
  Lampa.Storage.set('proxy_tmdb', 'true');
};
