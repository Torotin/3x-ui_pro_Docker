// Функция для удаления и сортировки элементов в настройках
function removeSettingsComponents() {
  var settingsToggled = false;

  Lampa.Settings.listener.follow('open', function(e) {
    if (e.name === 'main' && !settingsToggled) {
      settingsToggled = true;

      // сортируем меню
      setTimeout(function() {
        $('div[data-component="interface"]').before($('div[data-component="surs"]'));
        $('div[data-component="sisi"]').after($('div[data-component="account"]'));
      }, 10);

      setTimeout(function() {
        var hiddenSelectors = [
            'div[data-component="account"]',
            'div[data-component="plugins"]', 
            'div[data-component="tmdb"]', 
            'div[data-component="parser"]', 
            'div[data-component="server"]', 
            'div[data-component="parental_control"]',

            'div[data-component="backup"]'
        ];

        hiddenSelectors.forEach(function(selector) {
            $(selector).hide();
        });

        Lampa.Controller.toggle('settings');
      }, 40);
    }
  });

  // Отслеживание комбинации клавиш
  var keySequence = [38, 38, 39, 39, 40, 40, 38];
  var keyIndex = 0;

  $(document).on('keydown', function(e) {
    if (e.keyCode === keySequence[keyIndex]) {
      keyIndex++;
      if (keyIndex === keySequence.length) {
        keyIndex = 0;

        // Показываем скрытые пункты меню
        var hiddenSelectors = [
            'div[data-component="account"]',
            'div[data-component="plugins"]', 
            'div[data-component="tmdb"]', 
            'div[data-component="parser"]', 
            'div[data-component="server"]', 
            'div[data-component="parental_control"]',

            'div[data-component="backup"]'
        ];

        hiddenSelectors.forEach(function(selector) {
            $(selector).show();
        });

        Lampa.Noty.show('Алохамора... Скрытые пункты меню отображены');
      }
    } else {
      keyIndex = 0; // Сброс при неправильной клавише
    }
  });
}


var timer = setInterval(
    function() {
        //------------------Ваш код---------------------------
        // Скрыть разделы в боковом меню
        Lampa.Listener.follow('app', function(e) {
        if (e.type === 'ready') {
        //  Полный список пунктов:
        //    ['catalog', 'feed', 'filter', 'myperson', 'relise', 'anime', 'favorite', 'subscribes', 'timetable', 'mytorrents', 'console', 'about']
        //  вставьте то, что хотите скрыть:
        $(['anime','feed','myperson','subscribes','mytorrents','relise','about','console','timetable']
            .map(c => `[data-action="${c}"]`)
            .join(','), e.body).hide();
        }
        });
        // Скрыть пункты меню в настройках
        Lampa.Settings.listener.follow('open', function(e) {
        //  Полный список пунктов:
        //    ['account', 'interface', 'player', 'parser', 'torrserver', 'plugins', 'rest', 'iptv', 'sisi', 'console', 'about']
        //  вставьте то, что хотите скрыть:      
        $(['account', 'parser', 'parental_control', 'plugins', 'iptv', 'sisi']
            .map(c => `[data-component="${c}"]`)
            .join(','), e.body).remove();
        });
        // Скрыть колокольчик в верхнем баре
        Lampa.Listener.follow('app', function(e) {
        if (e.type === 'ready') {
            $('.head .notice--icon').remove();
        }
        });
        // Скрыть кнопку броадкаст (Посмотреть на другом устройстве)
        Lampa.Listener.follow('full', function(e) {
        if (e.type == 'complite') {
            $('.open--broadcast').remove();
        }
        });
        //------------------Ваш код---------------------------
    }
)




// Главная функция для инициализации скриптов и настроек
function initializeExample(params) {
    // Базовый URL твоего сервиса, нужен для работы на старых телеках.
    var domainUrl = "https://example.com";

    // Объект с информацией о пользователе
    var userInfo = {
        account_is_promo: false,
        account_is_test: false,
        account_is_vip: false
    };

    // Флаг готовности пользовательской информации
    var isUserInfoReady = false;

    // Создание URL с учетом параметров пользователя
    function buildAccountUrl(url) {
        url = url.charAt(0) === "/" ? domainUrl + url : url;
        var email = Lampa.Storage.get("account_email");
        if (email && url.indexOf("account_email=") === -1) {
            url = Lampa.Utils.addUrlComponent(url, "account_email=" + encodeURIComponent(email));
        }
        var uid = Lampa.Storage.get("lampac_unic_id", "");
        if (uid && url.indexOf("uid=") === -1) {
            url = Lampa.Utils.addUrlComponent(url, "uid=" + encodeURIComponent(uid));
        }
        return url;
    }

    // Запрос информации о пользователе
    function reqUserInfo(callback) {
        var network = new Lampa.Reguest();
        network.silent(buildAccountUrl("/reqinfo"), function (response) {
            userInfo.account_is_promo = response.user && response.user.params && response.user.params.account_is_promo || false;
            userInfo.account_is_test = response.user && response.user.params && response.user.params.account_is_test || false;
            userInfo.account_is_vip = response.user && response.user.params && response.user.params.account_is_vip || false;
            isUserInfoReady = true;
            if (typeof callback === "function") callback();
        }, function () {
            isUserInfoReady = true;
            if (typeof callback === "function") callback();
        });
    }

    // Загрузка основных скриптов
    function loadCoreScripts() {
        var userIdRaw = Lampa.Storage.get("lampac_unic_id", "");
        var coreScripts = [
            "https://example.com/backup.js",
            "https://example.com/online.js",
            "https://example.com/tracks.js",
            "https://example.com/plugins/ts-preload.js",
            "https://example.com/sisihide.js",
            "https://example.com/PWA_notice.js",
            "https://example.com/hide.js",
            "https://levende.github.io/lampa-plugins/lnum.js"
        ];

        if (!Lampa.Platform.is("browser")) {
            // при https грузим телек только для не браузеров
            coreScripts.push("https://example.com/tv.js");
        }

        if (Lampa.Platform.is("android") || Lampa.Platform.is("tizen")) {
            coreScripts.push(["https://cub.rip/plugin/radio"], function () {});
        }

        coreScripts = coreScripts.map(function (script) {
            return script.indexOf("?") !== -1 ? script + "&v=" + Math.random() : script + "?v=" + Math.random();
        });

        Lampa.Utils.putScriptAsync(coreScripts, function () {});
    }

    // Загрузка условных скриптов в зависимости от типа аккаунта
    function loadConditionalScripts() {
        var userIdRaw = Lampa.Storage.get("lampac_unic_id", "");
        var userIdParam = "?uid=" + encodeURIComponent(userIdRaw);
        var regularScripts = [
            "https://example.com/telegram_bot_bind.js",
            "https://example.com/sync.js",
            "https://levende.github.io/lampa-plugins/profiles.js",
            "https://example.com/devices.js" + userIdParam
        ];

        var promoScripts = [
            "https://levende.github.io/lampa-plugins/profiles.js"
        ];

        var testScripts = [
            // скрипты для тестов
        ];

        var vipScripts = [
            // скрипты для випов
        ];
        var allScripts = [
            // скрипты для всех
        ];

        // Настройки для обычного аккаунта
        if (!userInfo.account_is_promo) {
          // как пример настройка профилей от Levende, выполняется до загрузки самого скрипта
            window.profiles_settings = {
                syncEnabled: true,
                broadcastEnabled: true,
                showSettings: false
            };
            allScripts = allScripts.concat(regularScripts);
        }

        // Настройки для промо-аккаунта
        if (userInfo.account_is_promo) {
            // как пример настройка профилей от Levende, выполняется до загрузки самого скрипта, тут отключили подгрузку sync.js
            window.profiles_settings = {
                syncEnabled: false,
                broadcastEnabled: false,
                showSettings: false
            };
            allScripts = allScripts.concat(promoScripts);
        }

        // Настройки для тестового аккаунта
        if (userInfo.account_is_test) {
            // что то для тестового аккаунта пишем сюда
            allScripts = allScripts.concat(testScripts);
        }

        // Настройки для VIP-аккаунта
        if (userInfo.account_is_vip) {
            // что то до загрузки скриптов для тестового аккаунта пишем сюда
            allScripts = allScripts.concat(vipScripts);
        }

        allScripts = allScripts.map(function (script) {
            return script.indexOf("?") !== -1 ? script + "&v=" + Math.random() : script + "?v=" + Math.random();
        });

        Lampa.Utils.putScriptAsync(allScripts, function () {});
    }

    // Скрытие элементов в зависимости от типа аккаунта ПРИМЕР
    function hideElementsByAccountType() {
        var elementsToHide = [];

        if (!userInfo.account_is_promo) {
            elementsToHide.push('div[data-component="account"]'); // Скрытие блока аккаунта для обычных пользователей
        }

        if (!userInfo.account_is_vip) {
            elementsToHide.push('div[data-component="plugins"]'); // Скрытие плагинов для не-VIP пользователей
        }

        if (!userInfo.account_is_test) {
            elementsToHide.push('div[data-component="tmdb"]'); // Скрытие TMDB для не-тестовых аккаунтов
        }

        elementsToHide.push('div[data-component="parser"]'); // Скрытие парсера для всех пользователей

        elementsToHide.forEach(function (selector) {
            var elements = document.querySelectorAll(selector);
            elements.forEach(function (element) {
                element.style.display = 'none';
            });
        });
    }

    // Инициализация приложения
    reqUserInfo(function () {
        loadCoreScripts();
        loadConditionalScripts();
        hideElementsByAccountType();
    });
}

// Пример вызова функции с параметрами
//вызывать после готовности приложения
initializeExample({});