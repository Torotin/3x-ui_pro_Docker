#!/bin/bash

ROOT="${1:-/opt/script}"

echo "Проверяю директорию: $ROOT"
echo

fix_file() {
    local f="$1"
    local ext="${f##*.}"

    echo "[Файл] $f"

    # Проверка, что текстовый
    if ! file "$f" | grep -q "text"; then
        echo "  └─ Пропуск: бинарный или нетекстовый файл"
        echo
        return
    fi

    # Исправление CRLF
    if file "$f" | grep -q "CRLF"; then
        echo "  └─ Конвертирование CRLF → LF"
        sed -i 's/\r$//' "$f"
    else
        echo "  └─ Формат строк OK"
    fi

    # Добавляем шебанг только если нужное расширение
    if [[ "$ext" == "sh" || "$ext" == "mod" ]]; then
        FIRST_LINE=$(head -n 1 "$f" 2>/dev/null)

        if [[ "$FIRST_LINE" != "#!"* ]]; then
            echo "  └─ Шебанг отсутствует. Добавляю #!/bin/bash"
            sed -i '1i #!/bin/bash' "$f"
        else
            INTERPRETER=$(echo "$FIRST_LINE" | cut -c3-)
            if [ ! -x "$INTERPRETER" ]; then
                echo "  └─ Интерпретатор недоступен: $INTERPRETER → заменяю на /bin/bash"
                sed -i '1c #!/bin/bash' "$f"
            else
                echo "  └─ Шебанг OK"
            fi
        fi

        chmod +x "$f"
        echo "  └─ Права +x выставлены"
        echo
        return
    fi

    # Для всех остальных текстовых файлов — просто фиксим формат
    echo "  └─ Файл не .sh и не .mod — шебанг не добавляю"
    echo
}

export -f fix_file

find "$ROOT" -type f -print0 | while IFS= read -r -d '' file; do
    fix_file "$file"
done

echo "Готово."
