// Вот такую функцию когда то на коленке склепал по загрузке плагинов пользователю.
// https://t.me/c/2008902836/68227

function addScripts() {
    var unicID = "?uid=" + encodeURIComponent(Lampa.Storage.get('lampac_unic_id', ''));
    var excludedAccounts = ['promo1', 'promo2']; //к этим аккаунтам не будут подгружаться исключенные плагины (например синхронизация )

    var testAccounts = ['test1']; //тестовые аккаунты для отладки плагинов
    var currentAccountUid = Lampa.Storage.get('lampac_unic_id', '');

    //белый список, грузим всем
    var whiteListScripts = [
        "https://nb557.github.io/plugins/rating.js",
        "https://nb557.github.io/plugins/kp_source.js",
        "https://levende.github.io/lampa-plugins/profiles.js",
        "https://aviamovie.github.io/surs.js",
        "https://igorek1986.github.io/lampa-plugins/reset.js",
        "{localhost}/online.js",
        "{localhost}/tracks.js",
        "{localhost}/cubproxy.js",
        //"{localhost}/plugins/gold_theme.js",
         
        "{localhost}/js/sisihide.js",

        
        // "{localhost}/hiden/need_coffee.js" + unicID
    ];

    //грузим всем кроме исключенных аккаунтов
    var restrictedListScripts = [
        "{localhost}/sync.js",
        "{localhost}/hiden/devices.js" + unicID
    ];

    //тестовые скрипты
    var testScripts = [
        '{localhost}/test.js'
    ];

    var scriptsToLoad = [];

    if (excludedAccounts.indexOf(currentAccountUid) === -1) {
        scriptsToLoad = scriptsToLoad.concat(restrictedListScripts);
    }

    if (testAccounts.indexOf(currentAccountUid) !== -1) {
        scriptsToLoad = scriptsToLoad.concat(testScripts);
    }

    scriptsToLoad = scriptsToLoad.concat(whiteListScripts);

    //предотвращаем кэширование
    scriptsToLoad = scriptsToLoad.map(function (url) {
        if (url.indexOf("?uid=") !== -1) {
            return url + "&v=" + Math.random();
        } else {
            return url + "?v=" + Math.random();
        }
    });

    Lampa.Utils.putScriptAsync(scriptsToLoad);
}

//запускаем 
// addScripts();