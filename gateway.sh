#!/bin/bash
# set -e
trap cleanup EXIT         # catch exit signal

# curl -fsSL https://localhost:15535/s | bash -s [dl|dl_secret_xxx|exc_secret_xxx] 7.0/d/download.sh 1 2 3

function hash_str(){
    echo -n "$1" | md5sum | awk '{print $1}'
}

function create_temp_file(){
  mktemp /tmp/tmp.XXXXXXXXXX
}

function remove_temp_file(){
    local i
    for i in "$@"; do
        if [[ -f "$i" ]]; then
            if [[ "$i" =~ ^/tmp/tmp\.[a-zA-Z0-9]{10}$ ]]; then
                rm -f "$i"
            fi
        fi
    done
}

# define cleanup function
function cleanup() {
    # remove temp files
    remove_temp_file  "$c_file" "$h_file" "$a_file"
}

case "$1" in
    dl)
        mode="dl"
        shift
        a_file="$1"
    ;;
    dl_secret_*)
        mode="dl"
        password="${1#dl_secret_}"
        is_verified=1
        shift
        a_file="$1"
        shift
    ;;
    secret_*|exc_secret_*)
        mode="exc"
        password="${1#*secret_}"
        is_verified=1
        shift
        a_file="$1"
        shift
        a_args=("$@")
    ;;
    debug)
        mode="debug"
        shift
        a_args=("$@")
    ;;
    *)
        mode="exc"
        a_file="$1"
        shift
        a_args=("$@")   # (1 2 3)
    ;;
esac


c_file="$(create_temp_file)"
h_file="$(create_temp_file)"

max_retry=3
retry_count=0
while ((retry_count++ <= max_retry));do
    # requires a valid file path
    while [ -z "$a_file" ] || [ "$is_file" == "0" ];do
        [ -n "$(command -v tput)" ] && tput sc || printf "\033[s"

        read -r -p "Require a file: " a_file < /dev/tty
        [ -n "$a_file" ] && read -r -p "Args[Optional]: " -a a_args < /dev/tty

        [ -n "$(command -v tput)" ] && tput rc; tput el || printf "\033[u\033[K"
        [ -n "$a_file" ] && break
    done

    # requires a valid password
    while [ -z "$password" ] || [ "$is_verified" == "0" ];do
        [ -n "$(command -v tput)" ] && tput sc || printf "\033[s"

        read -rsp "Enter your password: " password < /dev/tty

        [ -n "$(command -v tput)" ] && tput rc; tput el || printf "\033[u\033[K"
        [ -n "$password" ] && break
    done

    # POST to server
    http_code=$(curl -sSL \
            -k \
            -o "$c_file" \
            -D "$h_file" \
            -X POST \
            -H "Content-Type: application/json" \
            -H "Cache-Control: no-cache, no-store, must-revalidate" \
            -H "Pragma: no-cache" \
            -H "Expires: 0" \
            -d "{\"password\": \"$(hash_str "$password")\", \"hash\": \"$(hash_str "$a_file")\", \"mode\": \"$mode\"}" \
            -w "%{http_code}" \
            https://localhost:2096/verify)
            # https://ct.cili.fun:2096/verify)

    x_cgtw_args=$(awk '
        /^x-cgtw-args/ {
            gsub(/[[:space:]]/, "", $0);
            split($0, arr, ":|\\|");
            # ensure at least 5 elements in the array, missing ones are filled with "_"
            for (i = 1; i <= 5; i++) {
                if (!(i in arr)) arr[i] = "_";
            }
            print arr[2], arr[3], arr[4], arr[5]
        }' "$h_file")

    read -r is_verified is_file file_ext file_stem <<< "$x_cgtw_args"

    case "${http_code}" in
        "200") ;;
        "230") is_verified=1;; # 230: verified
        "231") is_verified=1; a_file="";; # 231: file not found and verified
        "232") is_verified=0; is_file=1;; # 232: not verified
        "500"|"522") echo "Error: Server internal error."; break;;
        *) echo "Error: HTTP request failed with code ${http_code}";; # 400, 404, etc.
    esac

    is_verified=${is_verified:-0}
    is_file=${is_file:-0}
    file_ext=${file_ext:-""}
    file_stem=${file_stem:-""}

    if [ "$mode" = "exc" ]; then
        case "$file_ext" in
            sh)
                bash "$c_file" "${a_args[@]}"
                _exc_stat=$?
            ;;
            php)
                php "$c_file" "${a_args[@]}"
                _exc_stat=$?
            ;;
            *)
                if [ "$is_file" == "1" ] && [ "$is_verified" == "1" ]; then
                    echo "Unknow type: [$file_ext]."
                    _exc_stat=1
                fi
            ;;
        esac
    elif [ "$mode" = "dl" ];then
        if [ ! -s "$c_file" ] || [ "$is_file" == "0" ] || [ "$file_stem" == "" ];then
            continue
        fi
        mv "$c_file" "$file_stem.$file_ext"
        _exc_stat=$?
    elif [ "$mode" = "debug" ];then
        echo "Debug mode: [${a_args[*]}]"
        echo "is_verified: [$is_verified], is_file: [$is_file], file_ext: [$file_ext], file_stem: [$file_stem], status_code: [$http_code]"
        _exc_stat=0
    else
        echo "Unknown mode: [$mode]"
        _exc_stat=1
    fi

    if [ -n "$_exc_stat" ];then
        exit "$_exc_stat"
    fi
done