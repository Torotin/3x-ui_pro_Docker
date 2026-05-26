#!/usr/bin/env bash

# Преобразует двухбуквенный код страны в emoji-флаг для подписи inbound.
country_code_to_flag() {
	local code=${1:-}
	[[ "$code" =~ ^[A-Za-z][A-Za-z]$ ]] || return 1
	jq -nr --arg code "$code" '$code | ascii_upcase | explode | map(. + 127397) | implode'
}

# Извлекает флаг из ответа выбранного источника в соответствии с его форматом.
country_flag_value() {
	local mode=$1 value=${2:-} code
	case "$mode" in
	emoji)
		printf '%s' "$value"
		;;
	iso2)
		country_code_to_flag "$value"
		;;
	trace_loc)
		code=$(sed -n 's/^loc=//p' <<<"$value" | head -n1)
		country_code_to_flag "$code"
		;;
	*)
		return 1
		;;
	esac
}

# Печатает приоритетный список источников определения страны по публичному IP.
country_flag_sources() {
	cat <<'EOF'
http://1.1.1.1/cdn-cgi/trace||trace_loc
http://1.0.0.1/cdn-cgi/trace||trace_loc
https://ipwho.is/|.flag.emoji|emoji
https://ipwhois.io/json/|.country_flag_emoji|emoji
https://ipapi.co/json/|.country_code|iso2
https://ipinfo.io/json|.country|iso2
https://api.country.is/|.country|iso2
http://ip-api.com/json/|.countryCode|iso2
EOF
}

# Получает диагностический URL через заданный SOCKS5 proxy.
socks_proxy_get() {
	local host=$1 port=$2 url=$3
	curl --fail --silent \
		--max-time "${EXTERNAL_PROXY_PROBE_TIMEOUT:-10}" \
		--socks5-hostname "$host:$port" \
		"$url"
}

# Подтверждает, что SOCKS endpoint действительно выводит трафик через WARP.
warp_proxy_available() {
	local host=$1 port=$2 trace
	trace=$(socks_proxy_get "$host" "$port" "${WARP_PROXY_PROBE_URL:-https://www.cloudflare.com/cdn-cgi/trace}") || return 1
	grep -qx 'warp=on' <<<"$trace"
}

# Подтверждает, что SOCKS endpoint действительно выводит трафик через TOR.
tor_proxy_available() {
	local host=$1 port=$2 result
	result=$(socks_proxy_get "$host" "$port" "${TOR_PROXY_PROBE_URL:-https://check.torproject.org/api/ip}") || return 1
	jq -e '.IsTor == true' <<<"$result" >/dev/null
}

# Возвращает устойчивый суффикс имени для управляемого VLESS inbound.
inbound_remark_slug() {
	case "$1" in
	vision) printf '%s' vless-tcp-reality ;;
	xhttp) printf '%s' vless-xhttp ;;
	*) return 1 ;;
	esac
}

# Строит отображаемое имя inbound с флагом обнаруженной страны.
inbound_remark() {
	local kind=$1 flag=${EMOJI_FLAG:-⚠} slug
	slug=$(inbound_remark_slug "$kind") || return 1
	printf '%s %s' "$flag" "$slug"
}

# Строит старое имя управляемого inbound для бесшовного распознавания миграции.
legacy_managed_inbound_remark() {
	local kind=$1 slug
	slug=$(inbound_remark_slug "$kind") || return 1
	printf 'managed:%s' "$slug"
}

# Формирует набор допустимых имен управляемого inbound: нового и прежнего.
managed_inbound_remarks_json() {
	local kind=$1 desired=$2 desired_remark legacy_remark
	desired_remark=$(jq -r ".inbounds.$kind.remark" <<<"$desired")
	legacy_remark=$(legacy_managed_inbound_remark "$kind")
	jq -nc --arg desired "$desired_remark" --arg legacy "$legacy_remark" '[$desired, $legacy] | unique'
}

# Собирает декларативное желаемое состояние панели, inbound и общего клиента.
build_desired_state() {
	local prefix=${CLIENT_EMAIL_PREFIX:-autogen}
	local shared_email=${CLIENT_EMAIL_SHARED:-"$prefix"}
	local sub_id=${CLIENT_SUB_ID:-}
	local vision_remark xhttp_remark
	if [[ -z "$sub_id" ]]; then
		# Стабильный subId производен от домена и общей метки клиента.
		sub_id=$(printf '%s:%s' "${WEBDOMAIN:-localhost}" "$shared_email" | sha256sum | cut -c1-16)
	fi
	vision_remark=$(inbound_remark vision)
	xhttp_remark=$(inbound_remark xhttp)

	jq -nc \
		--arg webListen "${webListen:-0.0.0.0}" \
		--arg webDomain "${webDomain:-}" \
		--arg webPort "${webPort:-2053}" \
		--arg webBasePath "${webBasePath:-}" \
		--arg visionPort "${PORT_LOCAL_VISION:-443}" \
		--arg xhttpPort "${PORT_LOCAL_XHTTP:-8443}" \
		--arg xhttpPath "${URI_VLESS_XHTTP:-/xhttp}" \
		--arg domain "${WEBDOMAIN:-}" \
		--arg sharedEmail "$shared_email" \
		--arg subId "$sub_id" \
		--arg visionRemark "$vision_remark" \
		--arg xhttpRemark "$xhttp_remark" \
		'{
          panel: {
            webListen: $webListen,
            webDomain: $webDomain,
            webPort: $webPort,
            webBasePath: $webBasePath
          },
          inbounds: {
            vision: {managed: true, protocol: "vless", port: ($visionPort|tonumber), remark: $visionRemark},
            xhttp: {managed: true, protocol: "vless", port: ($xhttpPort|tonumber), remark: $xhttpRemark, path: $xhttpPath}
          },
          clients: {
            shared: {email: $sharedEmail, subId: $subId, flow: "xtls-rprx-vision"}
          },
          integrations: {
            warp: {enabled: true},
            tor: {enabled: true}
          },
          xray: {
            domain: $domain,
            dns: {managed: true},
            routing: {managed: true},
            outbounds: {managed: true}
          }
        }'
}

# Перечисляет настройки панели, которыми разрешено управлять из окружения.
desired_panel_keys() {
	printf '%s\n' \
		webListen webDomain webPort webCertFile webKeyFile webBasePath \
		sessionMaxAge pageSize expireDiff trafficDiff remarkModel datepicker \
		tgBotEnable tgBotToken tgBotProxy tgBotAPIServer tgBotChatId tgRunTime \
		tgBotBackup tgBotLoginNotify tgCpu tgLang timeLocation \
		twoFactorEnable twoFactorToken xrayTemplateConfig \
		subEnable subJsonEnable subTitle subSupportUrl subProfileUrl subAnnounce \
		subEnableRouting subRoutingRules subListen subPort subPath subDomain \
		externalTrafficInformEnable externalTrafficInformURI subCertFile subKeyFile \
		subUpdates subEncrypt subShowInfo subURI subJsonPath subJsonURI \
		subClashEnable subClashPath subClashURI \
		subJsonFragment subJsonNoises subJsonMux subJsonRules \
		ldapEnable ldapHost ldapPort ldapUseTLS ldapBindDN ldapPassword ldapBaseDN \
		ldapUserFilter ldapUserAttr ldapVlessField ldapSyncCron ldapFlagField \
		ldapTruthyValues ldapInvertFlag ldapInboundTags ldapAutoCreate ldapAutoDelete \
		ldapDefaultTotalGB ldapDefaultExpiryDays ldapDefaultLimitIP
}

# Печатает штатный набор внешних geo-файлов для регистрации через API.
custom_geo_default_resources() {
	cat <<'EOF'
geosite|geosite_refilter|https://github.com/1andrevich/Re-filter-lists/releases/latest/download/geosite.dat
geosite|geosite_v2fly|https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat
geosite|geosite_zkeen|https://github.com/jameszeroX/zkeen-domains/releases/latest/download/zkeen.dat
geoip|geoip_zkeenip|https://github.com/jameszeroX/zkeen-ip/releases/latest/download/zkeenip.dat
geoip|geoip_v2fly|https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
geoip|geoip_refilter|https://github.com/1andrevich/Re-filter-lists/releases/latest/download/geoip.dat
geosite|adlist|https://github.com/zxc-rv/ad-filter/releases/latest/download/adlist.dat
EOF
}

# Преобразует строки geo-ресурсов в JSON-массив, игнорируя пустые и неверные записи.
custom_geo_resources_json() {
	local input=${CUSTOM_GEO_RESOURCES:-} entry typ alias url out='[]'
	[[ -n "$input" ]] || input=$(custom_geo_default_resources)

	# Формат допускает комментарии и пробелы в пользовательском env-списке.
	while IFS= read -r entry || [[ -n "$entry" ]]; do
		entry=${entry#"${entry%%[![:space:]]*}"}
		entry=${entry%"${entry##*[![:space:]]}"}
		[[ -n "$entry" && "${entry:0:1}" != "#" ]] || continue
		IFS='|' read -r typ alias url _rest <<<"$entry"
		typ=${typ#"${typ%%[![:space:]]*}"}
		typ=${typ%"${typ##*[![:space:]]}"}
		alias=${alias#"${alias%%[![:space:]]*}"}
		alias=${alias%"${alias##*[![:space:]]}"}
		url=${url#"${url%%[![:space:]]*}"}
		url=${url%"${url##*[![:space:]]}"}
		[[ -n "$typ" && -n "$alias" && -n "$url" ]] || continue
		out=$(jq -c --arg type "$typ" --arg alias "$alias" --arg url "$url" '. + [{type:$type, alias:$alias, url:$url}]' <<<"$out")
	done <<<"$input"

	printf '%s' "$out"
}

# Извлекает три reserved-байта WireGuard из идентификатора клиента WARP.
warp_reserved_json_from_config() {
	local config=$1 client_id decoded bytes
	client_id=$(jq -r '.client_id // .config.client_id // .config.config.client_id // empty' <<<"$config")
	[[ -n "$client_id" ]] || return 1
	decoded=$(printf '%s' "$client_id" | base64 -d 2>/dev/null | od -An -t u1 -N3 | awk '{$1=$1; print}' || true)
	[[ -n "$decoded" ]] || return 1
	read -r -a bytes <<<"$decoded"
	((${#bytes[@]} == 3)) || return 1
	jq -nc --argjson b1 "${bytes[0]}" --argjson b2 "${bytes[1]}" --argjson b3 "${bytes[2]}" '[$b1,$b2,$b3]'
}

# Создает WireGuard outbound Xray из конфигурации, полученной от WARP API.
warp_outbound_from_config() {
	local config=$1 private_key=$2 reserved_json=${3:-'[10,14,188]'}
	local v4 v6 peer_pub endpoint ep_v4 config_reserved
	v4=$(jq -r '.interface.addresses.v4 // .config.interface.addresses.v4 // empty' <<<"$config")
	v6=$(jq -r '.interface.addresses.v6 // .config.interface.addresses.v6 // empty' <<<"$config")
	peer_pub=$(jq -r '.peers[0].public_key // .config.peers[0].public_key // empty' <<<"$config")
	config_reserved=$(warp_reserved_json_from_config "$config" || true)
	[[ -n "$config_reserved" ]] && reserved_json=$config_reserved
	# Предпочитается hostname endpoint: он остается совместимым с конфигурацией панели.
	endpoint=$(jq -r '.peers[0].endpoint.host // .config.peers[0].endpoint.host // empty' <<<"$config")
	if [[ -z "$endpoint" ]]; then
		endpoint=${WARP_ENDPOINT_HOST:-engage.cloudflareclient.com:2408}
	fi
	if [[ -z "$endpoint" ]]; then
		ep_v4=$(jq -r '.peers[0].endpoint.v4 // .config.peers[0].endpoint.v4 // empty' <<<"$config")
		[[ -n "$ep_v4" ]] && endpoint="${ep_v4%:*}:2408"
	fi
	[[ -n "$endpoint" ]] || endpoint="engage.cloudflareclient.com:2408"
	[[ -n "$peer_pub" && -n "$private_key" ]] || return 1
	jq -nc \
		--arg sk "$private_key" \
		--arg v4 "$v4" \
		--arg v6 "$v6" \
		--arg pub "$peer_pub" \
		--arg ep "$endpoint" \
		--argjson reserved "$reserved_json" '{
          tag:"warp",
          protocol:"wireguard",
          settings:{
            mtu:1420,
            secretKey:$sk,
            address:([$v4,$v6] | map(select(. != "")) | map(if contains(":") then . + "/128" else . + "/32" end)),
            numWorkers:2,
            workers:2,
            domainStrategy:"ForceIP",
            reserved:$reserved,
            peers:[{
              publicKey:$pub,
              public_key:$pub,
              allowedIPs:["0.0.0.0/0","::/0"],
              allowedIps:["0.0.0.0/0","::/0"],
              endpoint:$ep,
              keepAlive:0
            }],
            isClient:true,
            noKernelTun:false
          }
        }'
}

# Возвращает существующему WARP outbound канонический hostname endpoint.
normalize_warp_outbound_endpoint() {
	local outbound=$1 endpoint=${WARP_ENDPOINT_HOST:-engage.cloudflareclient.com:2408}
	jq -c --arg ep "$endpoint" '
      if (.tag == "warp" and .protocol == "wireguard") then
        .settings.peers = ((.settings.peers // []) | map(.endpoint = $ep))
      else
        .
      end
    ' <<<"$outbound"
}

# Читает JSON-поле API, которое панель может вернуть объектом либо JSON-строкой.
json_field_object() {
	local object=$1 field=$2
	jq -c --arg field "$field" '.[$field] | fromjson? // . // {}' <<<"$object"
}

# Формирует VLESS settings, сохраняя клиентов и обязательные параметры Vision/XHTTP.
build_vless_settings_json() {
	local kind=$1 current=${2:-} existing='{}' clients='[]' dec enc label fallback_dest
	if [[ -n "$current" && "$current" != "null" ]]; then
		existing=$(json_field_object "$current" settings)
		clients=$(jq -c '.clients // []' <<<"$existing")
		dec=$(jq -r '.decryption // empty' <<<"$existing")
		enc=$(jq -r '.encryption // empty' <<<"$existing")
		label=$(jq -r '.selectedAuth // empty' <<<"$existing")
	fi
	if [[ -z "${dec:-}" || -z "${enc:-}" ]]; then
		# Параметры шифрования запрашиваются только когда их нет в существующем inbound.
		get_vless_auth || true
		dec=${dec:-${VLESS_DEC:-none}}
		enc=${enc:-${VLESS_ENC:-none}}
		label=${label:-${VLESS_LABEL:-}}
	fi
	if [[ "${USE_VLESS_PQ:-true}" != "true" ]]; then
		dec=none
		enc=none
		label=
	fi
	fallback_dest="${VISION_FALLBACK_HOST:-telemt}:${VISION_FALLBACK_PORT:-${PORT_LOCAL_TELEMT_PROXY:-9443}}"
	jq -nc \
		--arg kind "$kind" \
		--arg dec "$dec" \
		--arg enc "$enc" \
		--arg label "${label:-}" \
		--arg fallbackDest "$fallback_dest" \
		--argjson fallbackXver "${VISION_FALLBACK_XVER:-1}" \
		--argjson clients "$clients" '
        if $kind == "vision" then
          {clients:$clients, decryption:"none", encryption:"none", fallbacks:[{dest:$fallbackDest,xver:$fallbackXver}]}
        else
          {clients:$clients, decryption:$dec, encryption:$enc}
          | if ($label|length)>0 then . + {selectedAuth:$label} else . end
        end
      '
}

# Формирует клиентский объект в контракте API 3x-ui 3.1.
vless_client_api_json() {
	local client_id=$1 email=$2 sub_id=$3 flow=$4
	jq -nc --arg id "$client_id" --arg email "$email" --arg sid "$sub_id" --arg flow "$flow" '{
      id:$id, flow:$flow, email:$email, limitIp:0, totalGB:0, expiryTime:0,
      enable:true, tgId:0, subId:$sid, comment:"", reset:0
    }'
}

# Оборачивает клиента списком inbound для операции создания и привязки.
vless_client_create_payload_json() {
	local inbound_ids=$1 client=$2
	jq -nc --argjson inboundIds "$inbound_ids" --argjson client "$client" '{
      client:$client,
      inboundIds:$inboundIds
    }'
}

# Строит общие socket options для создаваемых Xray inbound.
build_sockopt_json() {
	local accept_proxy=${1:-false} domain_strategy=${2:-AsIs} tproxy=${3:-off}
	jq -nc --argjson acceptProxyProtocol "$accept_proxy" --arg domainStrategy "$domain_strategy" --arg tproxy "$tproxy" '{
      V6Only:false,
      acceptProxyProtocol:$acceptProxyProtocol,
      dialerProxy:"",
      domainStrategy:$domainStrategy,
      interface:"",
      mark:0,
      penetrate:true,
      tcpFastOpen:true,
      tcpKeepAliveIdle:300,
      tcpKeepAliveInterval:0,
      tcpMaxSeg:1440,
      tcpMptcp:false,
      tcpUserTimeout:10000,
      tcpWindowClamp:600,
      tcpcongestion:"bbr",
      tproxy:$tproxy
    }'
}

# Строит список внешнего proxy для маскирующего соединения, если задан домен.
build_external_proxy_json() {
	local host=$1 force_tls=${2:-same}
	if [[ -z "$host" ]]; then
		printf '[]'
	else
		jq -nc --arg dest "$host" --arg forceTls "$force_tls" '[{forceTls:$forceTls,dest:$dest,port:443,remark:""}]'
	fi
}

# Строит streamSettings для TCP/REALITY Vision с ключами и fallback-назначением.
build_vision_stream_json() {
	local target=$1 sni=$2 private_key=$3 public_key=$4 short_ids=${5:-'[""]'} sockopt=${6:-'{}'} mldsa_seed=${7:-} mldsa_verify=${8:-} target_xver=${9:-0}
	local external_proxy
	external_proxy=$(build_external_proxy_json "$sni")
	jq -nc \
		--arg target "$target" \
		--arg sni "$sni" \
		--arg privateKey "$private_key" \
		--arg publicKey "$public_key" \
		--arg mldsaSeed "$mldsa_seed" \
		--arg mldsaVerify "$mldsa_verify" \
		--argjson shortIds "$short_ids" \
		--argjson sockopt "$sockopt" \
		--argjson targetXver "$target_xver" \
		--argjson externalProxy "$external_proxy" '{
          network:"tcp",
          security:"reality",
          externalProxy:$externalProxy,
          realitySettings:{
            show:false,
            xver:$targetXver,
            target:$target,
            serverNames:[$sni],
            privateKey:$privateKey,
            minClientVer:"",
            maxClientVer:"",
            maxTimediff:0,
            shortIds:$shortIds,
            mldsa65Seed:$mldsaSeed,
            settings:{
              publicKey:$publicKey,
              fingerprint:"chrome",
              serverName:"",
              spiderX:"/",
              mldsa65Verify:$mldsaVerify
            }
          },
          sockopt:$sockopt,
          tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}}
        }'
}

# Строит streamSettings для XHTTP backend, TLS которого завершается в Traefik.
build_xhttp_stream_json() {
	local path=$1 host=$2 sockopt external_proxy
	sockopt=$(build_sockopt_json false UseIP tproxy)
	external_proxy=$(build_external_proxy_json "$host" tls)
	jq -nc --arg path "$path" --arg host "$host" --argjson sockopt "$sockopt" --argjson externalProxy "$external_proxy" '{
      network:"xhttp",
      security:"none",
      externalProxy:$externalProxy,
      sockopt:$sockopt,
      xhttpSettings:{
        path:$path,
        host:$host,
        headers:{
          "Cache-Control":"no-store",
          "Access-Control-Allow-Origin":"*",
          "Access-Control-Allow-Methods":"GET, POST"
        },
        scMaxBufferedPosts:50,
        scMaxEachPostBytes:"5000000",
        scStreamUpServerSecs:"5-20",
        noSSEHeader:true,
        xPaddingBytes:"100-1000",
        mode:"packet-up"
      }
    }'
}
