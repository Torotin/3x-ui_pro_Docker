#!/usr/bin/env bash

json_upsert_outbound_by_tag() {
	local current=$1 outbound=$2
	jq -c --argjson ob "$outbound" '
      .xraySetting.outbounds = (.xraySetting.outbounds // []) |
      .xraySetting.outbounds = (
        if any(.xraySetting.outbounds[]?; .tag == $ob.tag) then
          [.xraySetting.outbounds[] | if .tag == $ob.tag then $ob else . end]
        else
          .xraySetting.outbounds + [$ob]
        end
      )
    ' <<<"$current"
}

json_upsert_routing_rule_by_key() {
	local current=$1 key=$2 value=$3 rule=$4
	jq -c --arg key "$key" --arg value "$value" --argjson rule "$rule" '
      .xraySetting.routing = (.xraySetting.routing // {}) |
      .xraySetting.routing.rules = (.xraySetting.routing.rules // []) |
      .xraySetting.routing.rules = (
        if any(.xraySetting.routing.rules[]?; .[$key] == $value) then
          [.xraySetting.routing.rules[] | if .[$key] == $value then $rule else . end]
        else
          [$rule] + .xraySetting.routing.rules
        end
      )
    ' <<<"$current"
}

json_upsert_balancer_by_tag() {
	local current=$1 balancer=$2
	jq -c --argjson bal "$balancer" '
      .xraySetting.routing = (.xraySetting.routing // {}) |
      .xraySetting.routing.balancers = (.xraySetting.routing.balancers // []) |
      .xraySetting.routing.balancers = (
        if any(.xraySetting.routing.balancers[]?; .tag == $bal.tag) then
          [.xraySetting.routing.balancers[] | if .tag == $bal.tag then $bal else . end]
        else
          .xraySetting.routing.balancers + [$bal]
        end
      )
    ' <<<"$current"
}

json_burst_observatory_for_selectors() {
	local selectors=$1
	jq -nc --argjson selectors "$selectors" '{
      subjectSelector:$selectors,
      pingConfig:{
        destination:"https://connectivitycheck.gstatic.com/generate_204",
        connectivity:"",
        interval:"1m",
        sampling:10,
        timeout:"5s",
        httpMethod:"HEAD"
      }
    }'
}

json_managed_observatory_selectors() {
	jq -nc '["tor-proxy","torproxy","warp","warp-docker","usque"]'
}

json_remove_managed_subject_selectors() {
	local current=$1 selectors
	selectors=$(json_managed_observatory_selectors)
	jq -c --argjson managed "$selectors" '
      def strip_managed:
        if type == "object" and (.subjectSelector? | type == "array") then
          .subjectSelector = ([.subjectSelector[] | . as $selector | select(
            (($managed | index($selector)) == null)
            and (($selector | startswith("warp")) | not)
            and (($selector | startswith("tor")) | not)
            and ($selector != "usque")
          )])
        else
          .
        end;
      .xraySetting.observatory = null |
      .xraySetting.burstObservatory = (
        (.xraySetting.burstObservatory // null) | strip_managed |
        if type == "object" and ((.subjectSelector // []) | length) == 0 then null else . end
      )
    ' <<<"$current"
}

json_replace_dns_servers() {
	local current=$1 servers=$2
	jq -c --argjson servers "$servers" '
      .xraySetting.dns = (.xraySetting.dns // {}) |
      .xraySetting.dns.disableCache = (.xraySetting.dns.disableCache // false) |
      .xraySetting.dns.queryStrategy = (.xraySetting.dns.queryStrategy // "UseIP") |
      .xraySetting.dns.servers = $servers
	' <<<"$current"
}

json_warp_managed_domains() {
	local webdomain=${1:-}
	jq -nc --arg webdomain "$webdomain" '
      [
        "ext:geosite_RU.dat:category-gov-ru",
        "ext:geosite_RU.dat:yandex",
        "ext:geosite_RU.dat:steam",
        "ext:geosite_RU.dat:vk",
        "regexp:\\.ru",
        "regexp:\\.org",
        "regexp:\\.su",
        "regexp:\\.xn--d1acj3b$",
        "regexp:\\.xn--80adxhks$",
        "regexp:\\.xn--80asehdb$",
        "regexp:\\.xn--c1avg$",
        "regexp:\\.xn--80aswg$",
        "regexp:\\.p1ai$",
        "regexp:\\.xn--j1amh$",
        "regexp:\\.xn--90ae$",
        "regexp:\\.xn--90a3ac$",
        "regexp:\\.xn--l1acc$",
        "regexp:\\.xn--d1alf$",
        "regexp:\\.xn--90ais$"
      ] + (if ($webdomain // "") != "" then ["domain:" + $webdomain] else [] end)
    '
}

json_apply_managed_xray_state() {
	local current=$1 dns_servers=$2 warp_enabled=$3 tor_enabled=$4 dns_enabled=$5 warp_socks_available=$6 webdomain=$7 tor_endpoints=${8:-'[{"tag":"tor-proxy","host":"tor-proxy","port":1080}]'} warp_console_ob=${9:-}
	local updated=$current tor_ob tor_rule tor_balancer tor_selectors warp_ob usque_ob warp_rule warp_balancer selectors warp_domains endpoint_count index tag host port observatory_selectors='[]' burst_observatory
	: "$warp_socks_available"
	if [[ "$dns_enabled" == "true" ]]; then
		updated=$(json_replace_dns_servers "$updated" "$dns_servers")
	fi
	if [[ "$tor_enabled" == "true" ]]; then
		tor_selectors='[]'
		endpoint_count=$(jq 'length' <<<"$tor_endpoints")
		for ((index = 0; index < endpoint_count; index++)); do
			tag=$(jq -r ".[$index].tag" <<<"$tor_endpoints")
			host=$(jq -r ".[$index].host" <<<"$tor_endpoints")
			port=$(jq -r ".[$index].port" <<<"$tor_endpoints")
			tor_ob=$(jq -nc --arg tag "$tag" --arg host "$host" --argjson port "$port" '{tag:$tag,protocol:"socks",settings:{servers:[{address:$host,port:$port}]}}')
			updated=$(json_upsert_outbound_by_tag "$updated" "$tor_ob")
			tor_selectors=$(jq -c --arg tag "$tag" '. + [$tag]' <<<"$tor_selectors")
		done
		if [[ "$(jq 'length' <<<"$tor_selectors")" -gt 0 ]]; then
			tor_rule=$(jq -nc '{type:"field",balancerTag:"tor-balancer",domain:["domain:onion","domain:torproject.org","domain:ntc.party"]}')
			tor_balancer=$(jq -nc --argjson selector "$tor_selectors" '{tag:"tor-balancer",selector:$selector,strategy:{type:"leastPing"}}')
			updated=$(json_upsert_routing_rule_by_key "$updated" balancerTag tor-balancer "$tor_rule")
			updated=$(json_upsert_balancer_by_tag "$updated" "$tor_balancer")
			observatory_selectors=$(jq -c --argjson selectors "$tor_selectors" '. + $selectors | unique' <<<"$observatory_selectors")
		fi
	fi
	if [[ "$warp_enabled" == "true" ]]; then
		selectors='[]'
		if [[ -n "$warp_console_ob" && "$warp_console_ob" != "null" ]]; then
			updated=$(json_upsert_outbound_by_tag "$updated" "$warp_console_ob")
			selectors=$(jq -c '. + ["warp"]' <<<"$selectors")
		fi
		warp_ob=$(jq -nc '{tag:"warp-docker",protocol:"socks",settings:{servers:[{address:"warp",port:1080}]}}')
		updated=$(json_upsert_outbound_by_tag "$updated" "$warp_ob")
		selectors=$(jq -c '. + ["warp-docker"]' <<<"$selectors")
		usque_ob=$(jq -nc '{tag:"usque",protocol:"socks",settings:{servers:[{address:"usque",port:1080}]}}')
		updated=$(json_upsert_outbound_by_tag "$updated" "$usque_ob")
		selectors=$(jq -c '. + ["usque"]' <<<"$selectors")
		if [[ "$(jq 'length' <<<"$selectors")" -gt 0 ]]; then
			warp_domains=$(json_warp_managed_domains "$webdomain")
			warp_rule=$(jq -nc --argjson dom "$warp_domains" '{type:"field",balancerTag:"warp-balancer",domain:$dom}')
			warp_balancer=$(jq -nc --argjson selector "$selectors" '{tag:"warp-balancer",fallbackTag:"blocked",selector:$selector,strategy:{type:"leastPing"}}')
			updated=$(json_upsert_routing_rule_by_key "$updated" balancerTag warp-balancer "$warp_rule")
			updated=$(json_upsert_balancer_by_tag "$updated" "$warp_balancer")
			observatory_selectors=$(jq -c --argjson selectors "$selectors" '. + $selectors | unique' <<<"$observatory_selectors")
		fi
	fi
	if [[ "$(jq 'length' <<<"$observatory_selectors")" -gt 0 ]]; then
		burst_observatory=$(json_burst_observatory_for_selectors "$observatory_selectors")
		updated=$(jq -c --argjson burst "$burst_observatory" '
          .xraySetting.observatory = null |
          .xraySetting.burstObservatory = (
            if ((.xraySetting.burstObservatory.subjectSelector? // []) | length) > 0 then
              .xraySetting.burstObservatory
              | .subjectSelector = ((.subjectSelector + $burst.subjectSelector) | unique)
              | .pingConfig = $burst.pingConfig
            else
              $burst
            end
          )
        ' <<<"$updated")
	fi
	printf '%s' "$updated"
}

json_remove_managed_xray_artifacts() {
	local current=$1
	current=$(json_remove_managed_subject_selectors "$current")
	jq -c '
      .xraySetting.outbounds = ((.xraySetting.outbounds // []) | map(select((.tag // "") as $tag | ($tag != "warp-docker" and $tag != "tor-proxy")))) |
      .xraySetting.outbounds = ((.xraySetting.outbounds // []) | map(select((.tag // "") != "warp" and (.tag // "") != "usque"))) |
      .xraySetting.routing = (.xraySetting.routing // {}) |
      .xraySetting.outbounds = ((.xraySetting.outbounds // []) | map(select((.tag // "") != "torproxy"))) |
      .xraySetting.routing.rules = ((.xraySetting.routing.rules // []) | map(select((.outboundTag // "") != "tor-proxy" and (.balancerTag // "") != "tor-balancer" and (.balancerTag // "") != "warp-balancer"))) |
      .xraySetting.routing.balancers = ((.xraySetting.routing.balancers // []) | map(select((.tag // "") != "tor-balancer" and (.tag // "") != "warp-balancer")))
    ' <<<"$current"
}

json_equal() {
	local left=$1 right=$2
	diff -u <(jq -S . <<<"$left") <(jq -S . <<<"$right") >/dev/null
}
