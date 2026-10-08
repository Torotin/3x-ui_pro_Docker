(function () {
  'use strict';

  // Always proxy CUB hosts through Lampac (Manifest.cub_mirrors can be late/empty).
  var proxy_url = '/cub/';
  var extra = ['cub.rip', 'cub.red', 'geo.cub.red', 'mirror-kurwa.men'];

  Lampa.Listener.follow('request_before', function (e) {
    if (!e || !e.params || !e.params.url) return;
    if (e.params.url.indexOf('/cub/') !== -1) return;

    var mirrors = extra.slice();
    try {
      if (Lampa.Manifest && Lampa.Manifest.cub_mirrors && Lampa.Manifest.cub_mirrors.length) {
        mirrors = mirrors.concat(Lampa.Manifest.cub_mirrors);
      }
    } catch (err) {}

    var need = mirrors.some(function (mirror) {
      return mirror && e.params.url.indexOf(mirror) > -1;
    });

    if (need) {
      e.params.url = proxy_url + e.params.url.replace(/^https?:\/\//, '');
    }
  });
})();
