#!/bin/bash

: "${sitedir:=$DOCKER_DIR/caddy/site/fake}"

random_html() {
    # === ПЕРЕМЕННЫЕ ===
    sitedir="${SITEDIR:-/srv}"
    temp_dir="${TMPDIR:-/tmp}"
    temp_extract="$temp_dir/random_html_tmp"
    repo_url="${TEMPLATE_REPO_URL:-https://github.com/GFW4Fun/randomfakehtml/archive/refs/heads/master.zip}"
    archive_name="${ARCHIVE_NAME:-master.zip}"
    extracted_dir="${EXTRACTED_DIR:-randomfakehtml-master}"
    extracted_path="$temp_extract/$extracted_dir"

    unzip_cmd="${UNZIP_CMD:-unzip -q}"
    wget_cmd="${WGET_CMD:-wget}"
    rm_cmd="${RM_CMD:-rm -rf}"
    cp_cmd="${CP_CMD:-cp -a}"

    # === ПОДГОТОВКА ВРЕМЕННОЙ ДИРЕКТОРИИ ===
    $rm_cmd "$temp_extract" >/dev/null 2>&1 || true
    mkdir -p "$temp_extract" || {
        log ERROR "Не удалось создать временную директорию: $temp_extract"
        return 0
    }

    archive_path="$temp_extract/$archive_name"

    # === ЗАГРУЗКА И РАСПАКОВКА ===
    log INFO "Загрузка $repo_url в $archive_path"
    $wget_cmd "$repo_url" -O "$archive_path"
    log INFO "Распаковка $archive_path в $temp_extract"
    $unzip_cmd "$archive_path" -d "$temp_extract"
    log INFO "Удаляем $archive_path"
    $rm_cmd "$archive_path"

    if [ ! -d "$extracted_path" ]; then
        log ERROR "Извлечённая директория не найдена: $extracted_path"
        return 0
    fi

    # === ПОИСК ШАБЛОНОВ ===
    template_dirs=""
    for d in "$extracted_path"/*; do
        [ -d "$d" ] && [ "$(basename "$d")" != "assets" ] && template_dirs="$template_dirs $d"
    done

    if [ -z "$template_dirs" ]; then
        log ERROR "Шаблоны не найдены в $extracted_path"
        return 0
    fi

    # === ВЫБОР СЛУЧАЙНОГО ШАБЛОНА ===
    set -- $template_dirs
    count=$#
    rand_index=$(awk -v max="$count" 'BEGIN { srand(); print int(rand() * max) + 1 }')
    i=1
    for path in "$@"; do
        [ "$i" -eq "$rand_index" ] && selected_template="$path" && break
        i=$((i + 1))
    done

    log INFO "Выбран шаблон: $(basename "$selected_template")"

    # === ПОДГОТОВКА КАТАЛОГА НАЗНАЧЕНИЯ ===
    if [ -d "$sitedir" ]; then
        $rm_cmd "$sitedir"/* "$sitedir"/.[!.]* "$sitedir"/..?* 2>/dev/null || true
    else
        mkdir -p "$sitedir" || {
            log "ERROR" "Не удалось создать каталог назначения: $sitedir"
            return 0
        }
    fi

    # === КОПИРОВАНИЕ ШАБЛОНА ===
    log INFO "Копируем шаблон $selected_template в $sitedir"
    $cp_cmd "$selected_template/." "$sitedir"
}
