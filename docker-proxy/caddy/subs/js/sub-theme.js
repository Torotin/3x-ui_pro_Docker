(function () {
  window.__SUB_THEME_READY = (window.__SUB_ASSETS_READY || Promise.resolve()).then(() => {
    function createThemeSwitcher() {
      const isDarkTheme = localStorage.getItem('dark-mode') === 'true';
      const isUltra = localStorage.getItem('isUltraDarkThemeEnabled') === 'true';
      if (isUltra) document.documentElement.setAttribute('data-theme', 'ultra-dark');
      const theme = isDarkTheme ? 'dark' : 'light';
      document.querySelector('body').setAttribute('class', theme);
      return {
        animationsOff() {
          document.documentElement.setAttribute('data-theme-animations', 'off');
          const themeAnimations = document.querySelector('#change-theme');
          if (!themeAnimations) return;
          themeAnimations.addEventListener('mouseleave', () => document.documentElement.removeAttribute('data-theme-animations'));
          themeAnimations.addEventListener('touchend', () => document.documentElement.removeAttribute('data-theme-animations'));
        },
        animationsOffUltra() {
          document.documentElement.setAttribute('data-theme-animations', 'off');
          const themeAnimationsUltra = document.querySelector('#change-theme-ultra');
          if (!themeAnimationsUltra) return;
          themeAnimationsUltra.addEventListener('mouseleave', () => document.documentElement.removeAttribute('data-theme-animations'));
          themeAnimationsUltra.addEventListener('touchend', () => document.documentElement.removeAttribute('data-theme-animations'));
        },
        isDarkTheme,
        isUltra,
        get currentTheme() {
          return this.isDarkTheme ? 'dark' : 'light';
        },
        toggleTheme() {
          this.isDarkTheme = !this.isDarkTheme;
          localStorage.setItem('dark-mode', this.isDarkTheme);
          document.querySelector('body').setAttribute('class', this.isDarkTheme ? 'dark' : 'light');
          document.getElementById('message').className = themeSwitcher.currentTheme;
        },
        toggleUltra() {
          this.isUltra = !this.isUltra;
          if (this.isUltra) document.documentElement.setAttribute('data-theme', 'ultra-dark');
          else document.documentElement.removeAttribute('data-theme');
          localStorage.setItem('isUltraDarkThemeEnabled', this.isUltra.toString());
        }
      };
    }

    const themeSwitcher = window.themeSwitcher = createThemeSwitcher();

    Vue.component('a-theme-switch', {
      template: `
<template>
  <a-menu :theme="themeSwitcher.currentTheme" mode="inline" selected-keys="">
    <a-sub-menu>
      <span slot="title">
        <a-icon type="bulb" :theme="themeSwitcher.isDarkTheme ? 'filled' : 'outlined'"></a-icon>
        <span>Тема</span>
      </span>
      <a-menu-item id="change-theme" class="ant-menu-theme-switch" @mousedown="themeSwitcher.animationsOff()">
        <span>Темная</span>
        <a-switch :style="{ marginLeft: '2px' }" size="small" :default-checked="themeSwitcher.isDarkTheme"
          @change="themeSwitcher.toggleTheme()"></a-switch>
      </a-menu-item>
      <a-menu-item id="change-theme-ultra" v-if="themeSwitcher.isDarkTheme" class="ant-menu-theme-switch"
        @mousedown="themeSwitcher.animationsOffUltra()">
        <span>Очень темная</span>
        <a-checkbox :style="{ marginLeft: '2px' }" :checked="themeSwitcher.isUltra"
          @click="themeSwitcher.toggleUltra()"></a-checkbox>
      </a-menu-item>
    </a-sub-menu>
  </a-menu>
</template>
`,
      data: () => ({ themeSwitcher }),
      mounted() {
        this.$message.config({ getContainer: () => document.getElementById('message') });
        document.getElementById('message').className = themeSwitcher.currentTheme;
      }
    });

    Vue.component('a-theme-switch-login', {
      template: `
<template>
  <a-space @mousedown="themeSwitcher.animationsOff()" id="change-theme" direction="vertical" :size="10" :style="{ width: '100%' }">
    <a-space direction="horizontal" size="small">
      <a-switch size="small" :default-checked="themeSwitcher.isDarkTheme" @change="themeSwitcher.toggleTheme()"></a-switch>
      <span>Темная</span>
    </a-space>
    <a-space v-if="themeSwitcher.isDarkTheme" direction="horizontal" size="small">
      <a-checkbox :checked="themeSwitcher.isUltra" @click="themeSwitcher.toggleUltra()"></a-checkbox>
      <span>Очень темная</span>
    </a-space>
  </a-space>
</template>
`,
      data: () => ({ themeSwitcher }),
      mounted() {
        this.$message.config({ getContainer: () => document.getElementById('message') });
        document.getElementById('message').className = themeSwitcher.currentTheme;
      }
    });

    return themeSwitcher;
  }).catch((err) => {
    console.error('Не удалось инициализировать переключатель темы', err);
  });
})();
