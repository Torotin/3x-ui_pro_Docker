(function() {
    'use strict';
    
    if (window.lampac_hide_interface) return;
    window.lampac_hide_interface = true;

    var SETTINGS_KEY = 'hide_interface_settings';
    var defaultSettings = {
        sidebar: [],
        settings: [],
        hideBell: false,
        hideBroadcast: false
    };

    function HideInterface() {
        this.settings = Lampa.Storage.get(SETTINGS_KEY, Lampa.Utils.clone(defaultSettings));
    }

    HideInterface.prototype.init = function() {
        this.applySidebar();
        this.applySettings();
        this.applyOther();
        
        Lampa.Listener.follow('app', (e) => {
            if (e.type === 'ready') this.applySidebar();
        });
        
        Lampa.Settings.listener.follow('open', (e) => {
            this.applySettings(e.body);
        });
        
        Lampa.Listener.follow('full', (e) => {
            if (e.type === 'complite') this.applyOther();
        });
    };

    HideInterface.prototype.applySidebar = function() {
        if (this.settings.sidebar.length) {
            let selector = this.settings.sidebar.map(c => `[data-action="${c}"]`).join(',');
            $(selector).hide();
        }
    };

    HideInterface.prototype.applySettings = function(body = document.body) {
        if (this.settings.settings.length) {
            let selector = this.settings.settings.map(c => `[data-component="${c}"]`).join(',');
            $(selector, body).remove();
        }
    };

    HideInterface.prototype.applyOther = function() {
        if (this.settings.hideBell) $('.head .notice--icon').remove();
        if (this.settings.hideBroadcast) $('.open--broadcast').remove();
    };

    // Wait for Lampa to be fully loaded
    function initPlugin() {
        // Check if Settings API is available
        if (typeof Lampa.Settings === 'object' && typeof Lampa.Settings.add === 'function') {
            // Add settings panel
            Lampa.Settings.add({
                title: 'Скрыть интерфейс',
                name: 'hide_interface',
                component: {
                    template: function() {
                        let current = Lampa.Storage.get(SETTINGS_KEY, defaultSettings);
                        
                        const sidebarItems = [
                            {id: 'catalog', name: 'Каталог'},
                            {id: 'feed', name: 'Лента'},
                            {id: 'filter', name: 'Фильтр'},
                            {id: 'myperson', name: 'Мои персоны'},
                            {id: 'relise', name: 'Релізи'},
                            {id: 'anime', name: 'Аніме'},
                            {id: 'favorite', name: 'Улюблене'},
                            {id: 'subscribes', name: 'Підписки'},
                            {id: 'timetable', name: 'Розклад'},
                            {id: 'mytorrents', name: 'Мої торренти'},
                            {id: 'console', name: 'Консоль'},
                            {id: 'about', name: 'Про додаток'}
                        ];
                        
                        const settingsItems = [
                            {id: 'account', name: 'Акаунт'},
                            {id: 'interface', name: 'Інтерфейс'},
                            {id: 'player', name: 'Плеєр'},
                            {id: 'parser', name: 'Парсер'},
                            {id: 'torrserver', name: 'TorrServer'},
                            {id: 'plugins', name: 'Плагіни'},
                            {id: 'rest', name: 'Rest API'},
                            {id: 'iptv', name: 'IPTV'},
                            {id: 'sisi', name: 'Sisi'},
                            {id: 'console', name: 'Консоль'},
                            {id: 'about', name: 'Про додаток'}
                        ];
                        
                        return {
                            tag: 'div',
                            style: 'padding: 20px;',
                            children: [
                                // Боковое меню
                                {
                                    tag: 'div',
                                    style: 'margin-bottom: 25px;',
                                    children: [
                                        {tag: 'div', class: 'settings-param__name', text: 'Боковое меню'},
                                        ...sidebarItems.map(item => ({
                                            tag: 'div',
                                            style: 'display: flex; align-items: center; margin: 5px 0;',
                                            children: [
                                                {
                                                    tag: 'input',
                                                    attributes: {
                                                        type: 'checkbox',
                                                        id: 'sidebar_' + item.id,
                                                        checked: current.sidebar.includes(item.id)
                                                    }
                                                },
                                                {
                                                    tag: 'label',
                                                    attributes: {for: 'sidebar_' + item.id},
                                                    style: 'margin-left: 10px;',
                                                    text: item.name
                                                }
                                            ]
                                        }))
                                    ]
                                },
                                
                                // Меню настроек
                                {
                                    tag: 'div',
                                    style: 'margin-bottom: 25px;',
                                    children: [
                                        {tag: 'div', class: 'settings-param__name', text: 'Меню настроек'},
                                        ...settingsItems.map(item => ({
                                            tag: 'div',
                                            style: 'display: flex; align-items: center; margin: 5px 0;',
                                            children: [
                                                {
                                                    tag: 'input',
                                                    attributes: {
                                                        type: 'checkbox',
                                                        id: 'settings_' + item.id,
                                                        checked: current.settings.includes(item.id)
                                                    }
                                                },
                                                {
                                                    tag: 'label',
                                                    attributes: {for: 'settings_' + item.id},
                                                    style: 'margin-left: 10px;',
                                                    text: item.name
                                                }
                                            ]
                                        }))
                                    ]
                                },
                                
                                // Другие элементы
                                {
                                    tag: 'div',
                                    children: [
                                        {tag: 'div', class: 'settings-param__name', text: 'Другие элементы'},
                                        {
                                            tag: 'div',
                                            style: 'display: flex; align-items: center; margin: 5px 0;',
                                            children: [
                                                {
                                                    tag: 'input',
                                                    attributes: {
                                                        type: 'checkbox',
                                                        id: 'hideBell',
                                                        checked: current.hideBell
                                                    }
                                                },
                                                {
                                                    tag: 'label',
                                                    attributes: {for: 'hideBell'},
                                                    style: 'margin-left: 10px;',
                                                    text: 'Скрыть колокольчик (уведомления)'
                                                }
                                            ]
                                        },
                                        {
                                            tag: 'div',
                                            style: 'display: flex; align-items: center; margin: 5px 0;',
                                            children: [
                                                {
                                                    tag: 'input',
                                                    attributes: {
                                                        type: 'checkbox',
                                                        id: 'hideBroadcast',
                                                        checked: current.hideBroadcast
                                                    }
                                                },
                                                {
                                                    tag: 'label',
                                                    attributes: {for: 'hideBroadcast'},
                                                    style: 'margin-left: 10px;',
                                                    text: 'Скрыть кнопку трансляции (broadcast)'
                                                }
                                            ]
                                        }
                                    ]
                                },
                                
                                // Кнопка сохранения
                                {
                                    tag: 'button',
                                    class: 'settings-param__button',
                                    text: 'Сохранить',
                                    on: {
                                        click: () => {
                                            let newSettings = {
                                                sidebar: [],
                                                settings: [],
                                                hideBell: document.getElementById('hideBell').checked,
                                                hideBroadcast: document.getElementById('hideBroadcast').checked
                                            };
                                            
                                            sidebarItems.forEach(item => {
                                                if (document.getElementById('sidebar_' + item.id).checked) {
                                                    newSettings.sidebar.push(item.id);
                                                }
                                            });
                                            
                                            settingsItems.forEach(item => {
                                                if (document.getElementById('settings_' + item.id).checked) {
                                                    newSettings.settings.push(item.id);
                                                }
                                            });
                                            
                                            Lampa.Storage.set(SETTINGS_KEY, newSettings);
                                            Lampa.Noty.show('Настройки сохранены. Перезагрузите страницу для применения изменений.');
                                        }
                                    }
                                }
                            ]
                        };
                    }
                }
            });

            // Initialize the plugin
            let plugin = new HideInterface();
            plugin.init();
        } else {
            // If Settings API not ready, try again shortly
            setTimeout(initPlugin, 100);
        }
    }

    // Start initialization process
    if (typeof Lampa !== 'undefined') {
        initPlugin();
    } else {
        Lampa.Listener.follow('app', function(e) {
            if (e.type === 'ready') {
                initPlugin();
            }
        });
    }
})();