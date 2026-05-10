#!/usr/bin/env bash

build_desired_state() {
	local prefix=${CLIENT_EMAIL_PREFIX:-autogen}
	local vision_email=${CLIENT_EMAIL_VISION:-"$prefix-vision"}
	local xhttp_email=${CLIENT_EMAIL_XHTTP:-"$prefix-xhttp"}
	local sub_id=${CLIENT_SUB_ID:-}
	if [[ -z "$sub_id" ]]; then
		sub_id=$(printf '%s:%s:%s' "${WEBDOMAIN:-localhost}" "$vision_email" "$xhttp_email" | sha256sum | cut -c1-16)
	fi

	jq -nc \
		--arg webListen "${webListen:-0.0.0.0}" \
		--arg webDomain "${webDomain:-}" \
		--arg webPort "${webPort:-2053}" \
		--arg webBasePath "${webBasePath:-}" \
		--arg visionPort "${PORT_LOCAL_VISION:-443}" \
		--arg xhttpPort "${PORT_LOCAL_XHTTP:-8443}" \
		--arg xhttpPath "${URI_VLESS_XHTTP:-/xhttp}" \
		--arg domain "${WEBDOMAIN:-}" \
		--arg visionEmail "$vision_email" \
		--arg xhttpEmail "$xhttp_email" \
		--arg subId "$sub_id" \
		'{
          panel: {
            webListen: $webListen,
            webDomain: $webDomain,
            webPort: $webPort,
            webBasePath: $webBasePath
          },
          inbounds: {
            vision: {managed: true, protocol: "vless", port: ($visionPort|tonumber), remark: "managed:vless-tcp-reality"},
            xhttp: {managed: true, protocol: "vless", port: ($xhttpPort|tonumber), remark: "managed:vless-xhttp", path: $xhttpPath}
          },
          clients: {
            vision: {email: $visionEmail, subId: $subId, flow: "xtls-rprx-vision-udp443"},
            xhttp: {email: $xhttpEmail, subId: $subId, flow: ""}
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

custom_geo_default_resources() {
	cat <<'EOF'
geosite|zxc-rv-adlist|https://github.com/zxc-rv/ad-filter/releases/latest/download/adlist.dat
geoip|zkeenip|https://github.com/jameszeroX/zkeen-ip/releases/latest/download/zkeenip.dat
EOF
}

custom_geo_resources_json() {
	local input=${CUSTOM_GEO_RESOURCES:-} entry typ alias url out='[]'
	[[ -n "$input" ]] || input=$(custom_geo_default_resources)

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

warp_outbound_from_config() {
	local config=$1 private_key=$2 reserved_json=${3:-'[10,14,188]'}
	local v4 v6 peer_pub endpoint ep_v4 config_reserved
	v4=$(jq -r '.interface.addresses.v4 // .config.interface.addresses.v4 // empty' <<<"$config")
	v6=$(jq -r '.interface.addresses.v6 // .config.interface.addresses.v6 // empty' <<<"$config")
	peer_pub=$(jq -r '.peers[0].public_key // .config.peers[0].public_key // empty' <<<"$config")
	config_reserved=$(warp_reserved_json_from_config "$config" || true)
	[[ -n "$config_reserved" ]] && reserved_json=$config_reserved
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

json_field_object() {
	local object=$1 field=$2
	jq -c --arg field "$field" '.[$field] | fromjson? // . // {}' <<<"$object"
}

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
	fallback_dest="${VISION_FALLBACK_HOST:-traefik}:${VISION_FALLBACK_PORT:-4443}"
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

build_external_proxy_json() {
	local host=$1 force_tls=${2:-same}
	if [[ -z "$host" ]]; then
		printf '[]'
	else
		jq -nc --arg dest "$host" --arg forceTls "$force_tls" '[{forceTls:$forceTls,dest:$dest,port:443,remark:""}]'
	fi
}

build_vision_stream_json() {
	local target=$1 sni=$2 private_key=$3 public_key=$4 short_ids=${5:-'[""]'} sockopt=${6:-'{}'} mldsa_seed=${7:-} mldsa_verify=${8:-}
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
		--argjson externalProxy "$external_proxy" '{
          network:"tcp",
          security:"reality",
          externalProxy:$externalProxy,
          realitySettings:{
            show:true,
            xver:0,
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
          Server:"nginx",
          "Content-Type":"text/html; charset=UTF-8",
          "Cache-Control":"no-cache",
          Connection:"keep-alive",
          "Access-Control-Allow-Origin":("https://" + $host),
          "Access-Control-Allow-Methods":"GET, POST, OPTIONS",
          "Access-Control-Allow-Headers":"Content-Type"
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
