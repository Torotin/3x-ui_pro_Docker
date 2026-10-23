  {invc-rch_nws}
  window.rch_nws[hostkey].typeInvoke('{localhost}', function() {});

  // Single-flight loader: upstream putScript(..., true) force-reloads nws-client on
  // every RCH call, which opens competing WebSockets for the same nws_id and flaps
  // Firefox (dozens of GET /js/nws-client-es5.js + failed wss://…/nws).
  if (!window.__lampacNwsLoader) {
    window.__lampacNwsLoader = {
      loading: false,
      waiters: []
    };
  }

  function rchInvoke(json, call) {
    if (!window.nwsClient)
      window.nwsClient = {};

    var client = window.nwsClient[hostkey];
    if (client && client.connectionId != null) {
      call();
    }
    else if (client) {
      console.log('RCH', 'Reconnecting...');
      client.reconnect(function() {
        call();
      });
    }
    else {
      window.nwsClient[hostkey] = new NativeWsClient(json.nws, {
        autoReconnect: true,
        reconnectDelay: 3000
      });

      window.nwsClient[hostkey].on('Connected', function(connectionId) {
        window.rch_nws[hostkey].Registry(window.nwsClient[hostkey], function() {
          call();
        });
      });

      window.nwsClient[hostkey].connect();
    }
  }

  function rchRun(json, call) {
    if (typeof NativeWsClient !== 'undefined') {
      rchInvoke(json, call);
      return;
    }

    var loader = window.__lampacNwsLoader;
    loader.waiters.push(function() {
      rchInvoke(json, call);
    });

    if (loader.loading)
      return;

    loader.loading = true;
    Lampa.Utils.putScript(
      ["{localhost}/js/nws-client-es5.js?v21042026"],
      function() {},
      false,
      function() {
        loader.loading = false;
        var q = loader.waiters.splice(0, loader.waiters.length);
        for (var i = 0; i < q.length; i++) {
          try { q[i](); } catch (e) {}
        }
      },
      false
    );
  }
