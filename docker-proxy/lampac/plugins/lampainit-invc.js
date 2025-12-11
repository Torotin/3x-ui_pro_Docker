// //////////////
// Переименуйте файл lampainit-invc.js в lampainit-invc.my.js
// //////////////


var lampainit_invc = {};


// Лампа готова для использования 
lampainit_invc.appload = function appload() {
  // Lampa.Utils.putScriptAsync(["{localhost}/myplugin.js"]);  // wwwroot/myplugin.js
  // Lampa.Utils.putScriptAsync(["{localhost}/plugins/ts-preload.js", "https://nb557.github.io/plugins/online_mod.js"]);
  // Lampa.Storage.set('proxy_tmdb', 'true');
  // etc
};


// Лампа полностью загружена, можно работать с интерфейсом 
lampainit_invc.appready = function appready() {
  // $('.head .notice--icon').remove();
};


// Выполняется один раз, когда пользователь впервые открывает лампу
lampainit_invc.first_initiale = function firstinitiale() {
  // Здесь можно указать/изменить первоначальные настройки 
  // Lampa.Storage.set('source', 'tmdb');
  Lampa.Utils.putScriptAsync(["https://aviamovie.github.io/surs.js"], function() {});
  Lampa.Utils.putScriptAsync(["{localhost}/js/hide_interface.js"], function() {});
  Lampa.Storage.set('source', 'SURS');
  localStorage.setItem('menu_sort', '["Главная","Фильтр","Каталог","Фильмы","Сериалы","Релизы","Аниме","Избранное","IPTV","История","Расписание"]');
  localStorage.setItem('cub_domain', 'cub.rip');
  localStorage.setItem('cub_mirrors', '["cub.rip"]');
  localStorage.setItem('language', 'ru');
  localStorage.setItem('tmdb_lang', 'ru');
  localStorage.setItem('proxy_tmdb','true');
  localStorage.setItem('proxy_tmdb_auto','true');
  localStorage.setItem('source', 'cub');
  localStorage.setItem('video_quality_default', '2160');
  localStorage.setItem('protocol', 'http');
  localStorage.setItem('poster_size','w500');
  localStorage.setItem('background_type','complex');
  localStorage.setItem('glass_style','true');
  localStorage.setItem('keyboard_type', 'system');
  localStorage.setItem('animation', 'true');
  localStorage.setItem('account_use','true');
  localStorage.setItem('parser_use','true'); 
  localStorage.setItem('jackett_url','{jachost}'); 
  localStorage.setItem('internal_torrclient','true');
  localStorage.setItem('torrserver_use_link','one');
  localStorage.setItem('parser_torrent_type','jackett');
  localStorage.setItem('torrserver_url', '');
};


// Ниже код выполняется до загрузки лампы, например можно изменить настройки 
// window.lampa_settings.push_state = false;
// localStorage.setItem('cub_domain', 'mirror-kurwa.men');
// localStorage.setItem('cub_mirrors', '["mirror-kurwa.men"]');


/* Контекстное меню в online.js
window.lampac_online_context_menu = {
  push: function(menu, extra, params) {
    menu.push({
      title: 'TEST',
      test: true
    });
  },
  onSelect: function onSelect(a, params) {
    if (a.test)
      console.log(a);
  }
};
*/


// Ниже код выполняется до загрузки лампы, например можно изменить настройки 
// localStorage.setItem('menu_sort', '["Главная","Фильтр","Каталог","Фильмы","Сериалы","Релизы","Аниме","Избранное","IPTV","История","Расписание"]');
// localStorage.setItem('cub_domain', 'cub.rip');
// localStorage.setItem('cub_mirrors', '["cub.rip"]');
// localStorage.setItem('language', 'ru');
// localStorage.setItem('tmdb_lang', 'ru');
// localStorage.setItem('proxy_tmdb','true');
// localStorage.setItem('proxy_tmdb_auto','true');
// localStorage.setItem('source', 'cub');
// localStorage.setItem('video_quality_default', '2160');
// localStorage.setItem('protocol', 'http');
// localStorage.setItem('poster_size','w500');
// localStorage.setItem('background_type','complex');
// localStorage.setItem('glass_style','true');
// localStorage.setItem('keyboard_type', 'system');
// localStorage.setItem('animation', 'true');
// localStorage.setItem('account_use','true');
// localStorage.setItem('parser_use','true'); 
// localStorage.setItem('jackett_url','{jachost}'); 
// localStorage.setItem('internal_torrclient','true');
// localStorage.setItem('torrserver_use_link','one');
// localStorage.setItem('parser_torrent_type','jackett');
// localStorage.setItem('torrserver_url', 'http://ts.docker.local');
