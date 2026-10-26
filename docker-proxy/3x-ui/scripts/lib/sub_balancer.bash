#!/usr/bin/env bash

# Builds the panel AllSetting value for JSON subscription observatory probes.
build_admin_sub_json_observatory() {
	jq -nc '{
      destination:"https://www.gstatic.com/generate_204",
      connectivity:"",
      interval:"300s",
      sampling:2,
      timeout:"5s",
      httpMethod:"HEAD"
    }'
}

sub_balancer_ids_csv() {
	local ids=("$@") joined='' id
	for id in "${ids[@]}"; do
		[[ -n "$id" ]] || continue
		if [[ -n "$joined" ]]; then
			joined+=",$id"
		else
			joined=$id
		fi
	done
	printf '%s' "$joined"
}

sub_balancer_ids_json() {
	jq -nc '$ARGS.positional | map(tonumber) | sort' --args "$@"
}

sub_balancer_form_args() {
	local id
	printf '%s\0%s\0' --data-urlencode 'remark=AUTO'
	printf '%s\0%s\0' --data-urlencode 'strategy=leastPing'
	printf '%s\0%s\0' --data-urlencode 'sortOrder=1'
	printf '%s\0%s\0' --data-urlencode 'enabled=true'
	for id in "$@"; do
		printf '%s\0%s\0' --data-urlencode "inboundIds=$id"
	done
}

sub_balancer_warn_success() {
	log WARN "$*"
	return 0
}

# Ensures the native JSON subscription balancer AUTO uses leastPing for managed inbound IDs.
ensure_auto_sub_balancer() {
	local ids=() id ids_csv desired_ids current current_auto current_id current_strategy current_enabled current_ids
	local form_args=()
	for id in "$@"; do
		[[ -n "$id" ]] || continue
		ids+=("$id")
	done
	if ((${#ids[@]} == 0)); then
		sub_balancer_warn_success "AUTO sub balancer skipped: no inbound IDs."
		return 0
	fi

	ids_csv=$(sub_balancer_ids_csv "${ids[@]}")
	if ! plan_or_apply "AUTO sub balancer ensured inboundIds=$ids_csv"; then
		return 0
	fi

	if ! xui_list_sub_balancers; then
		sub_balancer_warn_success "AUTO sub balancer skipped: list API request failed."
		return 0
	fi
	if ! http_success_json; then
		sub_balancer_warn_success "AUTO sub balancer skipped: list API returned failure: $(http_body)"
		return 0
	fi

	current=$(api_obj_json)
	desired_ids=$(sub_balancer_ids_json "${ids[@]}")
	current_auto=$(jq -c '[.[]? | select(.remark == "AUTO")] | first // empty' <<<"$current")
	mapfile -d '' -t form_args < <(sub_balancer_form_args "${ids[@]}")
	if [[ -z "$current_auto" ]]; then
		if xui_add_sub_balancer "${form_args[@]}" && http_success_json; then
			log INFO "AUTO sub balancer created inboundIds=$ids_csv."
		else
			sub_balancer_warn_success "AUTO sub balancer create skipped after API failure: $(http_body)"
		fi
		return 0
	fi

	current_id=$(jq -r '.id // empty' <<<"$current_auto")
	current_strategy=$(jq -r '.strategy // ""' <<<"$current_auto")
	current_enabled=$(jq -r 'if has("enabled") then .enabled else true end' <<<"$current_auto")
	current_ids=$(jq -c '[.inboundIds[]? | tonumber] | sort' <<<"$current_auto")
	if [[ "$current_strategy" == "leastPing" && "$current_enabled" == "true" && "$current_ids" == "$desired_ids" ]]; then
		log INFO "AUTO sub balancer already matches desired state."
		return 0
	fi
	if [[ -z "$current_id" ]]; then
		sub_balancer_warn_success "AUTO sub balancer update skipped: existing row has no id."
		return 0
	fi
	if xui_update_sub_balancer "$current_id" "${form_args[@]}" && http_success_json; then
		log INFO "AUTO sub balancer updated inboundIds=$ids_csv."
	else
		sub_balancer_warn_success "AUTO sub balancer update skipped after API failure: $(http_body)"
	fi
	return 0
}
