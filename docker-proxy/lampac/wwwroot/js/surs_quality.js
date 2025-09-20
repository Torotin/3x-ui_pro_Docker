

(function () {
    'use strict';

    // Polyfill for AbortController and AbortSignal
    if (typeof AbortController === 'undefined') {
        window.AbortController = function () {
            this.signal = {
                aborted: false,
                addEventListener: function (event, callback) {
                    if (event === 'abort') {
                        this._onabort = callback;
                    }
                }
            };
            this.abort = function () {
                this.signal.aborted = true;
                if (typeof this.signal._onabort === 'function') {
                    this.signal._onabort();
                }
            };
        };
    }

    // Polyfill for performance.now
    if (!window.performance || !window.performance.now) {
        window.performance = window.performance || {};
        window.performance.now = function () {
            return new Date().getTime();
        };
    }

    // Polyfill for String.prototype.padStart
    if (!String.prototype.padStart) {
        String.prototype.padStart = function (targetLength, padString) {
            targetLength = targetLength >> 0; // Convert to integer
            padString = String(padString || ' ');
            if (this.length >= targetLength) {
                return String(this);
            }
            targetLength = targetLength - this.length;
            if (targetLength > padString.length) {
                padString += padString.repeat(Math.ceil(targetLength / padString.length));
            }
            return padString.slice(0, targetLength) + String(this);
        };
    }

    // Переменные настройки
    var ENABLE_LOGGING = true; // Централизованное управление логами
    var Q_CACHE_TIME = 72 * 60 * 60 * 1000; // Время кэша качества (72 часа)
    var QUALITY_CACHE = 'surs_quality_cache';
    var JACRED_PROTOCOL = 'https://';
    var JACRED_URL = Lampa.Storage.get('jacred.xyz') || 'jacred.xyz'; // Адрес JacRed
    var PROXY_LIST = [
        'http://api.allorigins.win/raw?url=',
        'http://cors.bwa.workers.dev/'
    ];
    var PROXY_TIMEOUT = 5000; // Таймаут прокси

    // Логирование
    var SURS_QUALITY = {
        log: function (message) {
            if (ENABLE_LOGGING && typeof console !== 'undefined' && console.log) {
                console.log("[SURS_QUALITY] ", message);
            }
        }
    };

    // Форматирование времени для логов
    function formatTime() {
        var now = new Date();
        var hours = now.getHours().toString().padStart(2, '0');
        var minutes = now.getMinutes().toString().padStart(2, '0');
        var seconds = now.getSeconds().toString().padStart(2, '0');
        return hours + ':' + minutes + ':' + seconds;
    }

    // Функция логирования времени выполнения
    function logExecution(functionName, startTime, additionalInfo) {
        var elapsed = (performance.now() - startTime).toFixed(2);
        var logMessage = functionName + ' время выполнения: ' + formatTime() + ' (' + elapsed + ' мс)';
        if (additionalInfo) {
            logMessage += ' | Информация: ' + additionalInfo;
        }
        SURS_QUALITY.log(logMessage);
    }

    // Добавление стилей для экранок (camrip)
    var style = document.createElement('style');
    style.textContent = [
        '.full-start__status.surs_quality.camrip {',
        '    color: red !important;',
        '}'
    ].join('\n');
    document.head.appendChild(style);

    // Функция для работы с прокси
    function fetchWithProxy(url, cardId, callback) {
        var startTime = performance.now();
        var currentProxyIndex = 0;
        var callbackCalled = false;
        var controller = new AbortController();
        var signal = controller.signal;

        function tryNextProxy() {
            if (currentProxyIndex >= PROXY_LIST.length) {
                if (!callbackCalled) {
                    callbackCalled = true;
                    callback(new Error('Все прокси не сработали для ' + url + ': исчерпаны все попытки'));
                    logExecution('fetchWithProxy', startTime, 'card: ' + cardId + ', Все прокси не сработали');
                }
                return;
            }
            var proxyUrl = PROXY_LIST[currentProxyIndex] + encodeURIComponent(url);
            SURS_QUALITY.log('card: ' + cardId + ', Запрос через прокси: ' + proxyUrl);
            var timeoutId = setTimeout(function () {
                controller.abort();
                if (!callbackCalled) {
                    SURS_QUALITY.log('card: ' + cardId + ', Прокси запрос превысил время ожидания: ' + proxyUrl);
                    currentProxyIndex++;
                    tryNextProxy();
                }
            }, PROXY_TIMEOUT);
            fetch(proxyUrl, { signal: signal })
                .then(function (response) {
                    clearTimeout(timeoutId);
                    if (!response.ok) {
                        throw new Error('Ошибка прокси: ' + response.status + ' ' + response.statusText);
                    }
                    return response.text();
                })
                .then(function (data) {
                    if (!callbackCalled) {
                        callbackCalled = true;
                        clearTimeout(timeoutId);
                        callback(null, data);
                        logExecution('fetchWithProxy', startTime, 'card: ' + cardId + ', Успешный запрос через прокси: ' + proxyUrl);
                    }
                })
                .catch(function (error) {
                    clearTimeout(timeoutId);
                    SURS_QUALITY.log('card: ' + cardId + ', Ошибка запроса через прокси: ' + proxyUrl + ', сообщение: ' + error.message);
                    if (!callbackCalled) {
                        currentProxyIndex++;
                        tryNextProxy();
                    }
                });
        }

        SURS_QUALITY.log('card: ' + cardId + ', Прямой запрос: ' + url);
        var directTimeoutId = setTimeout(function () {
            controller.abort();
            if (!callbackCalled) {
                SURS_QUALITY.log('card: ' + cardId + ', Прямой запрос превысил время ожидания, переходим к прокси.');
                tryNextProxy();
            }
        }, PROXY_TIMEOUT);

        fetch(url, { signal: signal })
            .then(function (response) {
                clearTimeout(directTimeoutId);
                if (!response.ok) {
                    throw new Error('Ошибка прямого запроса: ' + response.status + ' ' + response.statusText);
                }
                return response.text();
            })
            .then(function (data) {
                if (!callbackCalled) {
                    callbackCalled = true;
                    clearTimeout(directTimeoutId);
                    callback(null, data);
                    logExecution('fetchWithProxy', startTime, 'card: ' + cardId + ', Успешный прямой запрос: ' + url);
                }
            })
            .catch(function (error) {
                clearTimeout(directTimeoutId);
                SURS_QUALITY.log('card: ' + cardId + ', Ошибка прямого запроса: ' + url + ', сообщение: ' + error.message);
                if (!callbackCalled) {
                    SURS_QUALITY.log('card: ' + cardId + ', Прямой запрос не удался, переходим к прокси.');
                    tryNextProxy();
                }
            });
    }

    // Функция получения лучшего качества из JacRed
    function getBestReleaseFromJacred(normalizedCard, cardId, callback) {
        var startTime = performance.now();
        if (!JACRED_URL) {
            SURS_QUALITY.log('card: ' + cardId + ', JacRed: JACRED_URL не установлен.');
            callback(null);
            logExecution('getBestReleaseFromJacred', startTime, 'card: ' + cardId + ', JACRED_URL не установлен');
            return;
        }

        function translateQuality(quality, isCamrip) {
            if (isCamrip) {
                return 'Экранка';
            }
            if (typeof quality !== 'number') {
                return quality;
            }
            if (quality >= 2160) {
                return '4K';
            }
            if (quality >= 1080) {
                return 'FHD';
            }
            if (quality >= 720) {
                return 'HD';
            }
            if (quality > 0) {
                return 'SD';
            }
            return null;
        }

        SURS_QUALITY.log('card: ' + cardId + ', JacRed: Начало поиска качества.');
        var year = '';
        var dateStr = normalizedCard.release_date || '';
        if (dateStr.length >= 4) {
            year = dateStr.substring(0, 4);
        }
        if (!year || isNaN(year)) {
            SURS_QUALITY.log('card: ' + cardId + ', JacRed: Отсутствует или неверный год: ' + JSON.stringify(normalizedCard));
            callback(null);
            logExecution('getBestReleaseFromJacred', startTime, 'card: ' + cardId + ', Отсутствует или неверный год');
            return;
        }

        function searchJacredApi(searchTitle, searchYear, exactMatch, strategyName, apiCallback) {
            var apiStartTime = performance.now();
            var userId = Lampa.Storage.get('lampac_unic_id', '');
            var apiUrl = JACRED_PROTOCOL + JACRED_URL + '/api/v1.0/torrents?search=' +
                encodeURIComponent(searchTitle) +
                '&year=' + searchYear +
                (exactMatch ? '&exact=true' : '');

            SURS_QUALITY.log('card: ' + cardId + ', JacRed: ' + strategyName + ' URL: ' + apiUrl);

            fetchWithProxy(apiUrl, cardId, function (error, responseText) {
                if (error) {
                    SURS_QUALITY.log('card: ' + cardId + ', JacRed: ' + strategyName + ' ошибка запроса, сообщение: ' + error.message);
                    apiCallback(null);
                    logExecution('searchJacredApi', apiStartTime, 'card: ' + cardId + ', Ошибка запроса: ' + error.message);
                    return;
                }
                if (!responseText) {
                    SURS_QUALITY.log('card: ' + cardId + ', JacRed: ' + strategyName + ' пустой ответ.');
                    apiCallback(null);
                    logExecution('searchJacredApi', apiStartTime, 'card: ' + cardId + ', Пустой ответ');
                    return;
                }
                try {
                    var torrents = JSON.parse(responseText);
                    if (!Array.isArray(torrents) || torrents.length === 0) {
                        SURS_QUALITY.log('card: ' + cardId + ', JacRed: ' + strategyName + ' не найдены торренты.');
                        apiCallback(null);
                        logExecution('searchJacredApi', apiStartTime, 'card: ' + cardId + ', Торренты не найдены');
                        return;
                    }
                    var bestNumericQuality = -1;
                    var bestFoundTorrent = null;
                    var camripFound = false;
                    var camripQuality = -1;

                    for (var i = 0; i < torrents.length; i++) {
                        var currentTorrent = torrents[i];
                        var currentNumericQuality = currentTorrent.quality;
                        var lowerTitle = (currentTorrent.title || '').toLowerCase();
                        if (!/\b(ts|telesync|camrip|cam|TC|звук с TS)\b/i.test(lowerTitle)) {
                            if (typeof currentNumericQuality !== 'number' || currentNumericQuality === 0) {
                                continue;
                            }
                            if (currentNumericQuality > bestNumericQuality) {
                                bestNumericQuality = currentNumericQuality;
                                bestFoundTorrent = currentTorrent;
                            }
                        }
                    }

                    if (!bestFoundTorrent) {
                        for (var i = 0; i < torrents.length; i++) {
                            var currentTorrent = torrents[i];
                            var currentNumericQuality = currentTorrent.quality;
                            var lowerTitle = (currentTorrent.title || '').toLowerCase();
                        if (!/\b(ts|telesync|camrip|cam|TC|звук с TS)\b/i.test(lowerTitle)) {
                                if (typeof currentNumericQuality !== 'number' || currentNumericQuality === 0) {
                                    continue;
                                }
                                if (currentNumericQuality >= 720) {
                                    camripFound = true;
                                    if (currentNumericQuality > camripQuality) {
                                        camripQuality = currentNumericQuality;
                                        bestFoundTorrent = currentTorrent;
                                    }
                                }
                            }
                        }
                    }

                    if (bestFoundTorrent) {
                        var isCamrip = camripFound && bestNumericQuality === -1;
                        SURS_QUALITY.log('card: ' + cardId + ', JacRed: Найден лучший торрент в ' + strategyName + ': "' + bestFoundTorrent.title + '" с качеством: ' + (bestFoundTorrent.quality || bestNumericQuality) + 'p, camrip: ' + isCamrip);
                        apiCallback({
                            quality: translateQuality(bestFoundTorrent.quality || bestNumericQuality, isCamrip),
                            title: bestFoundTorrent.title,
                            isCamrip: isCamrip
                        });
                        logExecution('searchJacredApi', apiStartTime, 'card: ' + cardId + ', Найден торрент: ' + bestFoundTorrent.title);
                    } else {
                        SURS_QUALITY.log('card: ' + cardId + ', JacRed: Подходящие торренты не найдены в ' + strategyName + '.');
                        apiCallback(null);
                        logExecution('searchJacredApi', apiStartTime, 'card: ' + cardId + ', Торренты не найдены');
                    }
                } catch (e) {
                    SURS_QUALITY.log('card: ' + cardId + ', JacRed: ' + strategyName + ' ошибка парсинга ответа, сообщение: ' + e.message);
                    apiCallback(null);
                    logExecution('searchJacredApi', apiStartTime, 'card: ' + cardId + ', Ошибка парсинга: ' + e.message);
                }
            });
        }

        var searchStrategies = [];
        if (normalizedCard.original_title && /[a-zа-яё0-9]/i.test(normalizedCard.original_title)) {
            searchStrategies.push({
                title: normalizedCard.original_title.trim(),
                year: year,
                exact: true,
                name: 'OriginalTitle Exact Year'
            });
        }
        if (normalizedCard.title && /[a-zа-яё0-9]/i.test(normalizedCard.title)) {
            searchStrategies.push({
                title: normalizedCard.title.trim(),
                year: year,
                exact: true,
                name: 'Title Exact Year'
            });
        }

        function executeNextStrategy(index) {
            if (index >= searchStrategies.length) {
                SURS_QUALITY.log('card: ' + cardId + ', JacRed: Все стратегии не сработали. Качество не найдено.');
                callback(null);
                logExecution('getBestReleaseFromJacred', startTime, 'card: ' + cardId + ', Качество не найдено');
                return;
            }
            var strategy = searchStrategies[index];
            SURS_QUALITY.log('card: ' + cardId + ', JacRed: Пробуем стратегию: ' + strategy.name);
            searchJacredApi(strategy.title, strategy.year, strategy.exact, strategy.name, function (result) {
                if (result !== null) {
                    SURS_QUALITY.log('card: ' + cardId + ', JacRed: Качество найдено с помощью ' + strategy.name + ': ' + result.quality);
                    callback(result);
                    logExecution('getBestReleaseFromJacred', startTime, 'card: ' + cardId + ', Качество найдено: ' + result.quality);
                } else {
                    executeNextStrategy(index + 1);
                }
            });
        }

        if (searchStrategies.length > 0) {
            executeNextStrategy(0);
        } else {
            SURS_QUALITY.log('card: ' + cardId + ', JacRed: Нет подходящих заголовков для поиска.');
            callback(null);
            logExecution('getBestReleaseFromJacred', startTime, 'card: ' + cardId + ', Нет заголовков для поиска');
        }
    }

    // Функции для работы с кэшем качества
    function getQualityCache(key) {
        var startTime = performance.now();
        var cache = Lampa.Storage.get(QUALITY_CACHE) || {};
        var item = cache[key];
        var result = item && (Date.now() - item.timestamp < Q_CACHE_TIME) ? item : null;
        logExecution('getQualityCache', startTime, 'key: ' + key + ', ' + (result ? 'Кэш найден' : 'Кэш не найден'));
        return result;
    }

    function saveQualityCache(key, data, localCurrentCard) {
        var startTime = performance.now();
        SURS_QUALITY.log('card: ' + localCurrentCard + ', Сохранение кэша качества');
        var cache = Lampa.Storage.get(QUALITY_CACHE) || {};
        for (var cacheKey in cache) {
            if (cache.hasOwnProperty(cacheKey)) {
                if (Date.now() - cache[cacheKey].timestamp >= Q_CACHE_TIME) {
                    SURS_QUALITY.log('card: ' + localCurrentCard + ', Удаление устаревшей записи кэша для ключа: ' + cacheKey);
                    delete cache[cacheKey];
                }
            }
        }
        cache[key] = {
            quality: data.quality || null,
            isCamrip: data.isCamrip || false,
            timestamp: Date.now()
        };
        Lampa.Storage.set(QUALITY_CACHE, cache);
        logExecution('saveQualityCache', startTime, 'card: ' + localCurrentCard + ', Кэш сохранен для ключа: ' + key);
    }

    // Удаление элементов качества внутри карточки
    function clearQualityElements(localCurrentCard, render) {
        var startTime = performance.now();
        if (render) {
            $('.full-start__status.surs_quality', render).remove();
        }
        logExecution('clearQualityElements', startTime, 'card: ' + localCurrentCard + ', Элементы качества удалены');
    }

    // Плейсхолдер качества внутри карточки
    function showQualityPlaceholder(localCurrentCard, render) {
        var startTime = performance.now();
        if (!render) {
            logExecution('showQualityPlaceholder', startTime, 'card: ' + localCurrentCard + ', Отсутствует render');
            return;
        }
        var rateLine = $('.full-start-new__rate-line', render);
        if (!rateLine.length) {
            logExecution('showQualityPlaceholder', startTime, 'card: ' + localCurrentCard + ', Отсутствует rateLine');
            return;
        }
        if (!$('.full-start__status.surs_quality', render).length) {
            var placeholder = document.createElement('div');
            placeholder.className = 'full-start__status surs_quality';
            placeholder.textContent = '...';
            placeholder.style.opacity = '0.7';
            rateLine.append(placeholder);
            logExecution('showQualityPlaceholder', startTime, 'card: ' + localCurrentCard + ', Плейсхолдер добавлен');
        }
    }

    // Обновление элемента качества внутри карточки
    function updateQualityElement(quality, isCamrip, localCurrentCard, render) {
        var startTime = performance.now();
        if (!render) {
            logExecution('updateQualityElement', startTime, 'card: ' + localCurrentCard + ', Отсутствует render');
            return;
        }
        var element = $('.full-start__status.surs_quality', render);
        var rateLine = $('.full-start-new__rate-line', render);
        if (!rateLine.length) {
            logExecution('updateQualityElement', startTime, 'card: ' + localCurrentCard + ', Отсутствует rateLine');
            return;
        }
        if (element.length) {
            SURS_QUALITY.log('card: ' + localCurrentCard + ', Обновление элемента качества с "' + quality + '"');
            element.text(quality).css('opacity', '1');
            if (isCamrip) {
                element.addClass('camrip');
            } else {
                element.removeClass('camrip');
            }
            logExecution('updateQualityElement', startTime, 'card: ' + localCurrentCard + ', Элемент качества обновлен: ' + quality);
        } else {
            SURS_QUALITY.log('card: ' + localCurrentCard + ', Создание нового элемента качества с "' + quality + '"');
            var div = document.createElement('div');
            div.className = 'full-start__status surs_quality' + (isCamrip ? ' camrip' : '');
            div.textContent = quality;
            rateLine.append(div);
            logExecution('updateQualityElement', startTime, 'card: ' + localCurrentCard + ', Новый элемент качества создан: ' + quality);
        }
    }

    // Получение качества последовательно
    function fetchQualitySequentially(normalizedCard, localCurrentCard, qCacheKey, render) {
        var startTime = performance.now();
        SURS_QUALITY.log('card: ' + localCurrentCard + ', Начало запроса качества JacRed');
        getBestReleaseFromJacred(normalizedCard, localCurrentCard, function (jrResult) {
            SURS_QUALITY.log('card: ' + localCurrentCard + ', Получен ответ от JacRed');
            var quality = (jrResult && jrResult.quality) || null;
            var isCamrip = (jrResult && jrResult.isCamrip) || false;
            if (quality && quality !== 'NO') {
                SURS_QUALITY.log('card: ' + localCurrentCard + ', JacRed нашел качество: ' + quality + ', camrip: ' + isCamrip);
                saveQualityCache(qCacheKey, { quality: quality, isCamrip: isCamrip }, localCurrentCard);
                updateQualityElement(quality, isCamrip, localCurrentCard, render);
                logExecution('fetchQualitySequentially', startTime, 'card: ' + localCurrentCard + ', Качество найдено: ' + quality);
            } else {
                clearQualityElements(localCurrentCard, render);
                logExecution('fetchQualitySequentially', startTime, 'card: ' + localCurrentCard + ', Качество не найдено');
            }
        });
    }

    // Определение типа карточки
    function getCardType(card) {
        var startTime = performance.now();
        var type = card.media_type || card.type;
        if (type === 'movie' || type === 'tv') {
            logExecution('getCardType', startTime, 'card: ' + card.id + ', Тип определен: ' + type);
            return type;
        }
        var result = card.name || card.original_name ? 'tv' : 'movie';
        logExecution('getCardType', startTime, 'card: ' + card.id + ', Тип определен: ' + result);
        return result;
    }

    // Основная функция обработки качества внутри карточки
    function fetchQualityForCard(card, render) {
        var startTime = performance.now();
        if (!render) {
            logExecution('fetchQualityForCard', startTime, 'card: ' + card.id + ', Отсутствует render');
            return;
        }
        var localCurrentCard = card.id;
        SURS_QUALITY.log('card: ' + localCurrentCard + ', Начало обработки карточки: ' + JSON.stringify(card));
        var normalizedCard = {
            id: card.id,
            title: card.title || card.name || '',
            original_title: card.original_title || card.original_name || '',
            type: getCardType(card),
            release_date: card.release_date || card.first_air_date || ''
        };
        if (normalizedCard.type === 'tv') {
            clearQualityElements(localCurrentCard, render);
            logExecution('fetchQualityForCard', startTime, 'card: ' + localCurrentCard + ', Тип tv, пропускаем');
            return;
        }
        var rateLine = $('.full-start-new__rate-line', render);
        if (rateLine.length) {
            rateLine.css('visibility', 'hidden');
            rateLine.addClass('done');
        }
        var qCacheKey = normalizedCard.type + '_' + (normalizedCard.id || normalizedCard.imdb_id);
        var cacheQualityData = getQualityCache(qCacheKey);

        if (cacheQualityData) {
            SURS_QUALITY.log('card: ' + localCurrentCard + ', Получение качества из кэша');
            updateQualityElement(cacheQualityData.quality, cacheQualityData.isCamrip, localCurrentCard, render);
            logExecution('fetchQualityForCard', startTime, 'card: ' + localCurrentCard + ', Качество из кэша: ' + cacheQualityData.quality);
        } else {
            clearQualityElements(localCurrentCard, render);
            showQualityPlaceholder(localCurrentCard, render);
            fetchQualitySequentially(normalizedCard, localCurrentCard, qCacheKey, render);
            logExecution('fetchQualityForCard', startTime, 'card: ' + localCurrentCard + ', Запрос качества начат');
        }
        if (rateLine.length) {
            rateLine.css('visibility', 'visible');
        }
    }

    // Инициализация плагина
    function startPlugin() {
        var startTime = performance.now();
        SURS_QUALITY.log('Запуск плагина качества!');
        window.sursQualityPlugin = true;

        Lampa.Listener.follow('full', function (e) {
            if (e.type === 'complite') {
                var render = e.object.activity.render();
                fetchQualityForCard(e.data.movie, render);
            }
        });
        logExecution('startPlugin', startTime, 'Плагин запущен');
    }

    if (!window.sursQualityPlugin) {
        startPlugin();
    }
})();