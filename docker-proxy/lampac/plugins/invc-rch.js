(function() {
  'use strict';

  function getAndroidVersion() {
    if (Lampa.Platform.is('android')) {
      try {
        var current = AndroidJS.appVersion().split('-');

        return parseInt(current.pop());
      } catch (e) {
        return 0;
      }
    } else {
      return 0;
    }
  }

  var hostkey = '{localhost}'.replace('http://', '').replace('https://', '');

  if (!window.rch || !window.rch[hostkey]) {
    if (!window.rch) {
      window.rch = {
        type: undefined,
        startTypeInvoke: false,
        apkVersion: getAndroidVersion()
      };
    }
	
    window.rch[hostkey] = {
      type: undefined,
      startTypeInvoke: false,
      apkVersion: getAndroidVersion()
    };


    window.rch[hostkey].typeInvoke = function rchtypeInvoke(host, call) {
      if (window.rch[hostkey].type == undefined) {
        window.rch[hostkey].startTypeInvoke = true;
        var check = function check(good) {
          window.rch[hostkey].type = Lampa.Platform.is('android') ? 'apk' : good ? 'cors' : 'web';
          call();
        };

        if (Lampa.Platform.is('android') || Lampa.Platform.is('tizen')) check(true);
        else {
          var net = new Lampa.Reguest();
          var isLocal =
            /^(localhost|127\.0\.0\.1)(:\d+)?$/.test(location.host) ||
            location.hostname.endsWith('.local');
          net.silent(isLocal ? 'https://github.com/' : host + '/cors/check', function() {
            check(true);
          }, function() {
            check(false);
          }, false, {
            dataType: 'text'
          });
        }
      } else call();
    };


    window.rch[hostkey].Registry = function RchRegistry(hubConnection, startConnection) {
      window.rch[hostkey].typeInvoke('{localhost}', function() {
        hubConnection.invoke("RchRegistry", JSON.stringify({
          version: 147,
          host: location.host,
          rchtype: window.rch[hostkey].type,
          apkVersion: window.rch[hostkey].apkVersion,
          player: Lampa.Storage.field('player')
        })).then(function() {
          startConnection();
          hubConnection.on("RchClient", function(rchId, url, data, headers, returnHeaders) {	  
            var network = new Lampa.Reguest();
            function result(html) {
              if (Lampa.Arrays.isObject(html) || Lampa.Arrays.isArray(html)) {
                html = JSON.stringify(html);
              }
              if (typeof CompressionStream !== 'undefined' && html && html.length > 100) {
                var compressionStream = new CompressionStream('gzip');
                var encoder = new TextEncoder();
                var readable = new ReadableStream({
                  start: function(controller) {
                    controller.enqueue(encoder.encode(html));
                    controller.close();
                  }
                });
                var compressedStream = readable.pipeThrough(compressionStream);
                new Response(compressedStream).arrayBuffer()
                  .then(function(compressedBuffer) {
                    var compressedArray = new Uint8Array(compressedBuffer);
                    if (compressedArray.length > html.length) hubConnection.invoke("RchResult", rchId, html);
                    else {
                      $.ajax({
                        url: '{localhost}/rch/gzresult?id='+rchId,
                        type: 'POST',
                        data: compressedArray,
                        async: true,
                        cache: false,
                        contentType: false,
                        processData: false,
                        success: function(j) {},
                        error: function() {
                          hubConnection.invoke("RchResult", rchId, html);
                        }
                      });
                    }
                  })
                  .catch(function(error) {
                    hubConnection.invoke("RchResult", rchId, html);
                  });

              } else {
                hubConnection.invoke("RchResult", rchId, html);
              }
            }
            if (url == 'eval') {
              console.log('RCH', url, data);
              result(eval(data));
            } else if (url == 'ping') {
              result('pong');
            } else {
              console.log('RCH', url);
              network["native"](url, result, function() {
                console.log('RCH', 'result empty');
                result('');
              }, data, {
                dataType: 'text',
                timeout: 1000 * 8,
                headers: headers,
                returnHeaders: returnHeaders
              });
            }
          });
        });
      });
    };
  }

})();