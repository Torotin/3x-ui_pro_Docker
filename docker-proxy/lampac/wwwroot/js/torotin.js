const plugins_add = [
  { url: 'https://levende.github.io/lampa-plugins/profiles.js',    status: 1, name: 'Profiles.js',  author: 'levende' },
  { url: 'https://aviamovie.github.io/surs.js',                    status: 1, name: 'Surs.js',      author: 'aviamovie' },
];

function _Logger() {
    var levels = ['info', 'warning', 'error', 'debug'];
    var tags = { info: 'INF', warning: 'WRN', error: 'ERR', debug: 'DBG' };

    levels.forEach(function (level) {
        this[level] = function () {
            this.log(tags[level] + ':', arguments);
        };
    }, this);

    this.log = function (tag, args) {
        console.log.apply(console, ['_Torotin', tag].concat(Array.prototype.slice.call(args)));
    };
}

// === Функция для запроса данных о текущем пользователе ===
async function getCurrentUserData(accountEmail, baseUrl = window.location.origin) {
  try {
    if (!accountEmail) {
      accountEmail = Lampa.Storage.get('lampac_unic_id');
      _Logger.info('_Torotin','Using lampac_unic_id:', accountEmail);
      if (!accountEmail) {
        _Logger.error('UID не найден в Lampa.Storage');
        return { error: true, msg: 'Account email (UID) is required' };
      }
    }

    const encoded = encodeURIComponent(accountEmail.toLowerCase().trim());
    const res = await fetch(
      `${baseUrl}/merchant/user?account_email=${encoded}`,
      { method: 'GET', headers: { 'Content-Type': 'application/json' } }
    );
    if (!res.ok) throw new Error(`HTTP error! status: ${res.status}`);

    const data = await res.json();
    if (data.error) throw new Error(data.msg || 'Unknown API error');

    const { id, ids, ban_msg: banMsg, expires: expiresStr, group } = data;
    return { id, ids, banMsg, expires: new Date(expiresStr), group };
  } catch (e) {
    _Logger.error('Error fetching user data:', e);
    return { error: true, msg: e.message };
  }
}

async function isKidsProfile(profileId = '') {  
    const email = Lampa.Storage.get('account_email');  
    const profile = await getUserProfile(email, profileId);  
    return profile?.params?.forKids || false;  
}

async function getCurrentUserParams() {  
    const email = Lampa.Storage.get('account_email');  
    if (!email) {  
        _Logger.warn('No account_email found in Lampa.Storage');  
        return null;  
    }  
      
    return await getUserParams(email);  
}

async function getCurrentUserParams() {  
    const email = Lampa.Storage.get('account_email');  
    if (!email) {  
        _Logger.warning('No account_email found in Lampa.Storage');  
        return null;  
    }  
      
    try {  
        const userData = await getCurrentUserData(email);  
        return userData?.params || null;  
    } catch (error) {  
        _Logger.error('Error fetching user params:', error);  
        return null;  
    }  
}  

// getCurrentUserData()
//   .then(user => {
//     if (user.error) {
//       _Logger.error('Plugins API error:', user.msg);
//       return;
//     }
//     _Logger.info('User data fetched:', user);
//     _Logger.info('Plugins', 'Запущена установка плагинов для группы', user.group);
  
//     if (user.group >= 2) {
//       ensurePlugins(plugins_add);
//       _Logger.log('Plugins', 'Запущена установка плагинов для группы', user.group);
//       Lampa.Utils.putScriptAsync(["https://levende.github.io/lampa-plugins/profiles.js"]);
//       Lampa.Utils.putScriptAsync(["https://aviamovie.github.io/surs.js"]);
//       Lampa.Listener.follow('profile', function(event) {
//         if (event.type != 'changed') return;
//         if (event.params.forKids) {
//             _Logger.log('1','Kids profile detected, applying restrictions');
//         }
//       })
//     }
// });