/* synthetic Arcane-like shapes for rewrite regression; names intentionally unstable */
location.replace(`/login?redirect=` + encodeURIComponent("/"));
const AUTH=[`/login`,`/logout`,`/oidc`,`/auth/oidc`,`/mobile/passkey`];
var Guard=(e,t)=>t.some(t=>e===t||e.startsWith(`${t}/`));
function Xx(e,t,n,r,i=!1,a=`/dashboard`){if(e===`/`)return t?a:`/login`;return null}
