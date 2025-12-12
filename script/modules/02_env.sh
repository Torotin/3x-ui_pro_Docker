#!/bin/bash
# lib/01_env.sh
# Bash utilities for .env file management and environment variable handling

# --- CONFIGURABLES ---
PROFILE_FILE="/etc/profile.d/custom_env.sh"

# --- RANDOM GENERATORS (STUBS, TO BE IMPLEMENTED) ---
generate_random_string() {
    local min_len="${1:-16}"
    local max_len="${2:-32}"
    local len=$((RANDOM % (max_len - min_len + 1) + min_len))
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
}

generate_random_port() {
    # Returns a random port in the range 20000-65000
    echo $((RANDOM % 45000 + 20000))
}

# --- ENV FILE GENERATION ---
generate_env_file() {
    local template_file="$1"
    local output_file="$2"

    if [[ ! -f "$template_file" ]]; then
        log "ERROR" "Template not found: $template_file"
        return 1
    fi

    log "INFO" "Generating $output_file from template $template_file"
    envsubst < "$template_file" > "$output_file"

    if [[ ! -s "$output_file" ]]; then
        log "ERROR" "File $output_file is empty or was not created"
        return 1
    fi

    log "OK" "File generated: $output_file"
}

# --- PERSIST VARIABLE TO PROFILE ---
update_profile_custom_env() {
    local var_name="$1"
    local var_value="${!var_name}"

    [[ "$PERSIST_ENV" == true ]] || return 0

    # Create file if missing
    if [[ ! -f "$PROFILE_FILE" ]]; then
        touch "$PROFILE_FILE"
        chmod +x "$PROFILE_FILE"
        log "INFO" "Created profile file: $PROFILE_FILE"
    fi

    # Remove old value and append new
    sed -i "/^export ${var_name}=/d" "$PROFILE_FILE"
    echo "export ${var_name}=\"${var_value}\"" >> "$PROFILE_FILE"
    log "DEBUG" "Exported to $PROFILE_FILE: $var_name=${var_value}"

    # Remove duplicates
    sort -u "$PROFILE_FILE" -o "$PROFILE_FILE"
}

# --- PROMPT FOR REQUIRED VARIABLE ---
read_required_var() {
    local var_name="$1"
    local prompt_text="$2"
    local default_value="${3:-}"
    local input

    [[ -n "${!var_name:-}" ]] && return 0

    echo -ne "$prompt_text"
    [[ -n "$default_value" ]] && echo -n " [$default_value]"
    echo -n ": "
    IFS= read -r input

    [[ -z "$input" && -n "$default_value" ]] && input="$default_value"

    if [[ -n "$input" ]]; then
        export "$var_name"="$input"
        return 0
    fi

    log "WARN" "$var_name not set"
    return 1
}

# --- LOAD EXISTING ENV FILE ---
load_existing_env_file() {
    local env_file="$1"
    if [[ -f "$env_file" ]]; then
        log "INFO" "Loading variables from: $env_file"
        set -o allexport
        source "$env_file" 2>/dev/null
        set +o allexport
    else
        log "WARN" "File $env_file not found. Will create a new one."
    fi
}

# --- DETECT PUBLIC IP ADDRESSES ---
detect_public_ips() {
    export PUBLIC_IPV4=$(curl -s --max-time 3 -4 ifconfig.me || echo "")
    export PUBLIC_IPV6=$(curl -s --max-time 3 -6 ifconfig.me || echo "")

    if [[ -z "$PUBLIC_IPV4" ]]; then
        exit_error "Could not determine external IPv4 address"
    fi
    if [[ -z "$PUBLIC_IPV6" || "$PUBLIC_IPV6" == "::" ]]; then
        export PUBLIC_IPV6="$PUBLIC_IPV4"
        log "WARN" "IPv6 not obtained or invalid (::), using IPv4 instead"
    fi
    log "DEBUG" "PUBLIC_IPV4: $PUBLIC_IPV4"
    log "DEBUG" "PUBLIC_IPV6: $PUBLIC_IPV6"
}

# --- POPULATE ENV VARS FROM TEMPLATE ---
populate_env_vars_from_template() {
    local template_file="$1"

    # Extract all variable names from template
    local vars
    vars=$(grep -oP '\$\{?\K[A-Za-z_][A-Za-z0-9_]*(?=\}?)' "$template_file" | sort -u)

    for var in $vars; do
        if [[ -z "${!var}" ]]; then
            case "$var" in
                CROWDSEC_API_KEY_*|crowdsec_api_key_*)
                    export "$var"="$(generate_random_string 32 48)"
                    ;;
                URI_*)
                    export "$var"="$(generate_random_string 16 32)"
                    ;;
                PORT_*)
                    export "$var"="$(generate_random_port)"
                    ;;
                USER_*)
                    read_required_var "$var" "Enter username ($var)" || {
                        export "$var"="$(generate_random_string 8 12)"
                        log "WARN" "$var not set, generated automatically: ${!var}"
                    }
                    ;;
                PASS_*)
                    read_required_var "$var" "Enter password ($var)" || {
                        export "$var"="$(generate_random_string 16 24)"
                        log "WARN" "$var not set, generated automatically: ${!var}"
                    }
                    ;;
                SSH_PBK)
                    read_required_var "$var" "Enter public key ($var)" || {
                        export "$var"=""
                        log "WARN" "Empty data set for $var. Replace manually in .env"
                    }
                    ;;
                WEBDOMAIN)
                    read_required_var "$var" "Enter domain ($var)"
                    ;;
                *)
                    export "$var"=""
                    ;;
            esac
            log "INFO" "[AUTO] Set: $var=${!var}"
        else
            log "DEBUG" "Variable already set: $var=${!var}"
        fi

        update_profile_custom_env "$var"
    done
}

generate_htpasswd() {
  if [[ -n "$USER_WEB" ]]; then
    if [[ -z "$PASS_WEB" ]]; then
      log "ERROR" "USER_WEB is set but PASS_WEB is missing or empty."
      return 1
    fi

    log "INFO" "Generating htpasswd for user $USER_WEB..."
    local raw_htpasswd
    # Use bcrypt; trim newlines in case htpasswd outputs them (e.g., on some platforms).
    if ! raw_htpasswd=$(htpasswd -nBb "$USER_WEB" "$PASS_WEB" 2>/dev/null | tr -d '\r\n'); then
      log "ERROR" "htpasswd failed to generate hash."
      return 1
    fi
    # Verify the generated entry matches the provided credentials.
    if ! htpasswd -vb <(printf '%s\n' "$raw_htpasswd") "$USER_WEB" "$PASS_WEB" >/dev/null 2>&1; then
      log "ERROR" "htpasswd verification failed; please retry."
      return 1
    fi
    # Escape $ so docker compose does not try to expand $apr1... when substituting variables;
    # compose will convert $$ back to $ inside the container.
    HT_PASS_ENCODED="${raw_htpasswd//$/\$\$}"

    log "OK" "htpasswd successfully generated."
  else
    log "DEBUG" "USER_WEB is not set — skipping htpasswd generation."
  fi
}

# --- MAIN SCRIPT FUNCTION ---
envfile_script() {
    : "${PERSIST_ENV:=false}"  # Default to false if not set

    local ENV_FILE="${1:-$ENV_FILE}"
    local ENV_TEMPLATE_FILE="${2:-$ENV_TEMPLATE_FILE}"

    log "INFO" "Processing .env file: $ENV_FILE"

    [[ -f "$ENV_TEMPLATE_FILE" ]] || exit_error "Template not found: $ENV_TEMPLATE_FILE"
    log "INFO" "Template found: $ENV_TEMPLATE_FILE"

    load_existing_env_file "$ENV_FILE"
    detect_public_ips
    populate_env_vars_from_template "$ENV_TEMPLATE_FILE"
    generate_htpasswd
    backup_file "$ENV_FILE"
    generate_env_file "$ENV_TEMPLATE_FILE" "$ENV_FILE"
    log "INFO" ".env file updated: $ENV_FILE"
}

# --- SANITIZE ENV FILE (REMOVE COLORS, DATES) ---
sanitize_env_file() {
    local env_file="$1"
    sed -i \
        -e 's/\\033\[[0-9;]*m//g' \
        -e 's/\x1b\[[0-9;]*m//g' \
        -e 's/\[202[0-9]-[0-9]\{2\}-[0-9]\{2\}.*$//' \
        "$env_file"
}

# --- END OF FILE ---
