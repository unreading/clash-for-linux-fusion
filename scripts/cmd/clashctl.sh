#!/usr/bin/env bash

THIS_SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE:-${(%):-%N}}")")
. "$THIS_SCRIPT_DIR/common.sh"

_set_system_proxy() {
    local mixed_port=$("$BIN_YQ" '.mixed-port // ""' "$CLASH_CONFIG_RUNTIME")
    local http_port=$("$BIN_YQ" '.port // ""' "$CLASH_CONFIG_RUNTIME")
    local socks_port=$("$BIN_YQ" '.socks-port // ""' "$CLASH_CONFIG_RUNTIME")

    local auth=$("$BIN_YQ" '.authentication[0] // ""' "$CLASH_CONFIG_RUNTIME")
    [ -n "$auth" ] && auth=$auth@

    local bind_addr=$(_get_bind_addr)
    local http_proxy_addr="http://${auth}${bind_addr}:${http_port:-${mixed_port}}"
    local socks_proxy_addr="socks5h://${auth}${bind_addr}:${socks_port:-${mixed_port}}"
    local no_proxy_addr="localhost,127.0.0.1,::1"

    export http_proxy=$http_proxy_addr
    export HTTP_PROXY=$http_proxy

    export https_proxy=$http_proxy
    export HTTPS_PROXY=$https_proxy

    export all_proxy=$socks_proxy_addr
    export ALL_PROXY=$all_proxy

    export no_proxy=$no_proxy_addr
    export NO_PROXY=$no_proxy
}
_unset_system_proxy() {
    unset http_proxy
    unset https_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset all_proxy
    unset ALL_PROXY
    unset no_proxy
    unset NO_PROXY
}
_detect_proxy_port() {
    local mixed_port=$("$BIN_YQ" '.mixed-port // ""' "$CLASH_CONFIG_RUNTIME")
    local http_port=$("$BIN_YQ" '.port // ""' "$CLASH_CONFIG_RUNTIME")
    local socks_port=$("$BIN_YQ" '.socks-port // ""' "$CLASH_CONFIG_RUNTIME")
    [ -z "$mixed_port" ] && [ -z "$http_port" ] && [ -z "$socks_port" ] && mixed_port=7890

    local newPort count=0
    local port_list=(
        "mixed_port|mixed-port"
        "http_port|port"
        "socks_port|socks-port"
    )
    clashstatus >&/dev/null && local isActive='true'
    for entry in "${port_list[@]}"; do
        local var_name="${entry%|*}"
        local yaml_key="${entry#*|}"

        eval "local var_val=\${$var_name}"

        [ -n "$var_val" ] && _is_port_used "$var_val" && [ "$isActive" != "true" ] && {
            newPort=$(_get_random_port)
            ((count++))
            _failcat '🎯' "端口冲突：[$yaml_key] $var_val 🎲 随机分配 $newPort"
            "$BIN_YQ" -i ".${yaml_key} = $newPort" "$CLASH_CONFIG_MIXIN"
        }
    done
    ((count)) && _merge_config
}

function clashon() {
    _detect_proxy_port
    clashstatus >&/dev/null || placeholder_start
    clashstatus >&/dev/null || {
        _failcat '启动失败: 执行 clashlog 查看日志'
        return 1
    }
    clashproxy >/dev/null && _set_system_proxy
    _okcat '已开启代理环境'
}

watch_proxy() {
    [ -z "$http_proxy" ] && {
        # [[ "$0" == -* ]] && { # 登录式shell
        [[ $- == *i* ]] && { # 交互式shell
            placeholder_watch_proxy
        }
    }
}

function clashoff() {
    clashstatus >&/dev/null && {
        placeholder_stop >/dev/null
        clashstatus >&/dev/null && _tunstatus >&/dev/null && {
            _tunoff || _error_quit "请先关闭 Tun 模式"
        }
        placeholder_stop >/dev/null
        clashstatus >&/dev/null && {
            _failcat '代理环境关闭失败'
            return 1
        }
    }
    _unset_system_proxy
    _okcat '已关闭代理环境'
}

clashrestart() {
    clashoff >/dev/null
    clashon
}

function clashproxy() {
    case "$1" in
    -h | --help)
        cat <<EOF

- 查看系统代理状态
  clashproxy

- 开启系统代理
  clashproxy on

- 关闭系统代理
  clashproxy off

EOF
        return 0
        ;;
    on)
        clashstatus >&/dev/null || {
            _failcat "$KERNEL_NAME 未运行，请先执行 clashon"
            return 1
        }
        "$BIN_YQ" -i '._custom.system-proxy.enable = true' "$CLASH_CONFIG_MIXIN"
        _set_system_proxy
        _okcat '已开启系统代理'
        ;;
    off)
        "$BIN_YQ" -i '._custom.system-proxy.enable = false' "$CLASH_CONFIG_MIXIN"
        _unset_system_proxy
        _okcat '已关闭系统代理'
        ;;
    *)
        local system_proxy_enable=$("$BIN_YQ" '._custom.system-proxy.enable' "$CLASH_CONFIG_MIXIN" 2>/dev/null)
        case $system_proxy_enable in
        true)
            _okcat "系统代理：开启
$(env | grep -i 'proxy=')"
            ;;
        *)
            _failcat "系统代理：关闭"
            ;;
        esac
        ;;
    esac
}

function clashstatus() {
    placeholder_status "$@"
    placeholder_is_active >&/dev/null
}

function clashlog() {
    placeholder_log "$@"
}

function clashui() {
    case "$1" in
    update)
        _clashui_update
        return $?
        ;;
    -h|--help)
        cat <<EOF

- 查看 Web 控制台地址和当前节点状态
  clashui

- 更新 Web UI 文件
  clashui update

EOF
        return 0
        ;;
    esac

    _detect_ext_addr
    clashstatus >&/dev/null || clashon >/dev/null
    local query_url='api64.ipify.org'
    local public_ip=$(curl -s --noproxy "*" --location --max-time 2 $query_url)
    local public_address="http://${public_ip:-公网}:${EXT_PORT}/ui"

    local local_ip=$EXT_IP
    local local_address="http://${local_ip}:${EXT_PORT}/ui"

    local mode=$(curl_api "/configs" | jq -r .mode)
    local group_display="" node_display="" delay_display="N/A"

    if [ "$mode" = "global" ]; then
        group_display="GLOBAL (全局路由)"
        local global_info=$(curl_api "/proxies/GLOBAL")
        local global_node=$(echo "$global_info" | jq -r .now)
        if [ -n "$global_node" ] && [ "$global_node" != "null" ]; then
            node_display="$global_node"
            local node_enc=$(urlencode "$node_display")
            local d=$(curl_api "/proxies/$node_enc/delay?timeout=2000&url=http://www.gstatic.com/generate_204" | jq -r '.delay // "N/A"')
            [ "$d" != "N/A" ] && delay_display="${d}ms"
        else
            node_display="未知"
        fi
    else
        local group=""
        if [ -f "$CLASH_CONFIG_RUNTIME" ]; then
            group=$("$BIN_YQ" '.proxy-groups[] | select(.type == "select") | .name' "$CLASH_CONFIG_RUNTIME" 2>/dev/null | head -n 1)
        fi
        if [ -z "$group" ]; then
            local resp=$(curl_api "/proxies")
            group=$(echo "$resp" | jq -r '.proxies | to_entries[] | select(.value.type=="Selector" and .key!="GLOBAL" and .key!="Global") | .key' | head -n 1)
        fi
        [ -z "$group" ] && group="Proxy"
        group_display="$group"
        local group_enc=$(urlencode "$group")
        local node_name=$(curl_api "/proxies/$group_enc" | jq -r .now)
        if [[ -n "$node_name" && "$node_name" != "null" ]]; then
            node_display="$node_name"
            local node_enc=$(urlencode "$node_name")
            local d=$(curl_api "/proxies/$node_enc/delay?timeout=2000&url=http://www.gstatic.com/generate_204" | jq -r '.delay // "N/A"')
            [ "$d" != "N/A" ] && delay_display="${d}ms"
        else
            node_display="无法获取"
        fi
    fi

    local max_len=0
    for text in "$public_address" "$local_address" "$URL_CLASH_UI" "$node_display" "$group_display"; do
        [ ${#text} -gt $max_len ] && max_len=${#text}
    done
    local TOTAL_WIDTH=$(( max_len + 16 ))
    [ $TOTAL_WIDTH -lt 48 ] && TOTAL_WIDTH=48

    local line_inner=""
    for ((i=0; i<TOTAL_WIDTH-2; i++)); do line_inner+="═"; done

    _print_ui_line() {
        local label="$1"
        local value="$2"
        printf "║ %s%s" "$label" "$value"
        printf "\033[${TOTAL_WIDTH}G║\n"
    }

    printf "\n"
    printf "╔%s╗\n" "$line_inner"
    _print_ui_line "$(_okcat 'Web 控制台')" ""
    printf "║%s║\n" "$line_inner"
    _print_ui_line "🔓 注意放行端口：" "$EXT_PORT"
    _print_ui_line "🏠 内网：" "$local_address"
    _print_ui_line "🌏 公网：" "$public_address"
    _print_ui_line "☁️  公共：" "$URL_CLASH_UI"
    printf "║"
    printf "\033[${TOTAL_WIDTH}G║\n"
    _print_ui_line "🎯 当前分组：" "$group_display"
    _print_ui_line "🚀 当前节点：" "$node_display"
    _print_ui_line "⏱️  延迟：" "$delay_display"
    printf "╚%s╝\n\n" "$line_inner"
}

_clashui_update() {
    if ! command -v curl >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
        _failcat "需要 curl 和 unzip 工具"
        return 1
    fi

    local ui_dir_name=$("$BIN_YQ" '.external-ui // "dist"' "$CLASH_CONFIG_RUNTIME" 2>/dev/null)
    local target_dir="${CLASH_RESOURCES_DIR}/${ui_dir_name}"

    _okcat "🔍 检测到 Web UI 目录: $target_dir"

    local tmp_dir=$(mktemp -d)
    local download_url="https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip"

    _okcat "⏳ 正在从 GitHub 下载最新版 Zashboard..."
    if curl -L -o "$tmp_dir/dist.zip" --connect-timeout 10 --retry 3 "$download_url"; then
        _okcat "✅ 下载成功，正在解压..."
    else
        _failcat "❌ 下载失败，请检查网络连接"
        rm -rf "$tmp_dir"
        return 1
    fi

    if unzip -q "$tmp_dir/dist.zip" -d "$tmp_dir"; then
        [ -d "$target_dir" ] && mv "$target_dir" "${target_dir}.bak"

        if [ -d "$tmp_dir/dist" ]; then
            mv "$tmp_dir/dist" "$target_dir"
        else
            mkdir -p "$target_dir"
            cp -r "$tmp_dir/"* "$target_dir/" 2>/dev/null
        fi

        rm -rf "$tmp_dir" "${target_dir}.bak"
        _okcat "🎉 Web UI 更新完成！请按 Ctrl+F5 强制刷新页面。"
    else
        _failcat "❌ 解压失败"
        rm -rf "$tmp_dir"
        return 1
    fi
}

_merge_config() {
    cat "$CLASH_CONFIG_RUNTIME" >|"$CLASH_CONFIG_TEMP" 2>/dev/null
    # shellcheck disable=SC2016
    "$BIN_YQ" eval-all '
      ########################################
      #              Load Files              #
      ########################################
      select(fileIndex==0) as $config |
      select(fileIndex==1) as $mixin |
      
      ########################################
      #              Deep Merge              #
      ########################################
      $mixin |= del(._custom) |
      (($config // {}) * $mixin) as $runtime |
      $runtime |
      
      ########################################
      #               Rules                  #
      ########################################
      .rules = (
        ($mixin.rules.prefix // []) +
        ($config.rules // []) +
        ($mixin.rules.suffix // [])
      ) |
      
      ########################################
      #                Proxies               #
      ########################################
      .proxies = (
        ($mixin.proxies.prefix // []) +
        (
          ($config.proxies // []) as $configList |
          ($mixin.proxies.override // []) as $overrideList |
          $configList | map(
            . as $configItem |
            (
              $overrideList[] | select(.name == $configItem.name)
            ) // $configItem
          )
        ) +
        ($mixin.proxies.suffix // [])
      ) |
      
      ########################################
      #             ProxyGroups              #
      ########################################
      .proxy-groups = (
        ($mixin.proxy-groups.prefix // []) +
        (
          ($config.proxy-groups // []) as $configList |
          ($mixin.proxy-groups.override // []) as $overrideList |
          $configList | map(
            . as $configItem |
            (
              $overrideList[] | select(.name == $configItem.name)
            ) // $configItem
          )
        ) +
        ($mixin.proxy-groups.suffix // [])
      ) |

      ########################################
      #         ProxyGroups Inject           #
      # 把 inject 表里的 proxy 名追加到对应   #
      # 已有 group 的 .proxies 列表（自动去重）#
      # 用途：把自定义 / 链式代理无侵入地     #
      # 插入到订阅自带的节点组里，避免        #
      # override 整组的麻烦                  #
      ########################################
      ($mixin.proxy-groups.inject // {}) as $inj |
      .proxy-groups[] |= (
        . as $g |
        ($inj | .[$g.name] // []) as $extra |
        .proxies = (.proxies + $extra | unique)
      )
    ' "$CLASH_CONFIG_BASE" "$CLASH_CONFIG_MIXIN" >"$CLASH_CONFIG_RUNTIME"
    _valid_config "$CLASH_CONFIG_RUNTIME" || {
        cat "$CLASH_CONFIG_TEMP" >|"$CLASH_CONFIG_RUNTIME"
        _error_quit "验证失败：请检查 Mixin 配置"
    }
}

_merge_config_restart() {
    _merge_config
    placeholder_stop >/dev/null
    clashstatus >&/dev/null && _tunstatus >&/dev/null && {
        _tunoff || _error_quit "请先关闭 Tun 模式"
    }
    placeholder_stop >/dev/null
    sleep 0.1
    placeholder_start >/dev/null
    sleep 0.1
}
_get_secret() {
    "$BIN_YQ" '.secret // ""' "$CLASH_CONFIG_RUNTIME"
}
function clashsecret() {
    case "$1" in
    -h | --help)
        cat <<EOF

- 查看 Web 密钥
  clashsecret

- 修改 Web 密钥
  clashsecret <new_secret>

EOF
        return 0
        ;;
    esac

    case $# in
    0)
        _okcat "当前密钥：$(_get_secret)"
        ;;
    1)
        "$BIN_YQ" -i ".secret = \"$1\"" "$CLASH_CONFIG_MIXIN" || {
            _failcat "密钥更新失败，请重新输入"
            return 1
        }
        _merge_config_restart
        _okcat "密钥更新成功，已重启生效"
        ;;
    *)
        _failcat "密钥不要包含空格或使用引号包围"
        ;;
    esac
}

_tunstatus() {
    local tun_status=$("$BIN_YQ" '.tun.enable' "${CLASH_CONFIG_RUNTIME}")
    case $tun_status in
    true)
        _okcat 'Tun 状态：启用'
        ;;
    *)
        _failcat 'Tun 状态：关闭'
        ;;
    esac
}
_tunoff() {
    _tunstatus >/dev/null || return 0
    sudo placeholder_stop
    # 强制恢复终端输出处理
    stty opost 2>/dev/null
    clashstatus >&/dev/null || {
        "$BIN_YQ" -i '.tun.enable = false' "$CLASH_CONFIG_MIXIN"
        _merge_config
        clashon >/dev/null
        _okcat "Tun 模式已关闭"
        return 0
    }
    _tunstatus >&/dev/null && _failcat "Tun 模式关闭失败"
}
_sudo_restart() {
    sudo placeholder_stop
    placeholder_sudo_start
    sleep 0.5
    # 强制恢复终端输出处理
    stty opost 2>/dev/null
}
_tunon() {
    _tunstatus 2>/dev/null && return 0
    sudo placeholder_stop
    "$BIN_YQ" -i '.tun.enable = true' "$CLASH_CONFIG_MIXIN"
    _merge_config
    placeholder_sudo_start
    sleep 0.5
    # 强制恢复终端输出处理
    stty opost 2>/dev/null

    clashstatus >&/dev/null || _error_quit "Tun 模式开启失败"
    local fail_msg="Start TUN listening error|unsupported kernel version"
    local ok_msg="Tun adapter listening at|TUN listening iface"
    clashlog | grep -E -m1 -qs "$fail_msg" && {
        [ "$KERNEL_NAME" = 'mihomo' ] && {
            "$BIN_YQ" -i '.tun.auto-redirect = false' "$CLASH_CONFIG_MIXIN"
            _merge_config
            _sudo_restart
        }
        clashlog | grep -E -m1 -qs "$ok_msg" || {
            clashlog | grep -E -m1 "$fail_msg"
            _tunoff >&/dev/null
            _error_quit '系统内核版本不支持 Tun 模式'
        }
    }
    _okcat "Tun 模式已开启"
}

function clashtun() {
    case "$1" in
    -h | --help)
        cat <<EOF

- 查看 Tun 状态
  clashtun

- 开启 Tun 模式
  clashtun on

- 关闭 Tun 模式
  clashtun off
  
EOF
        return 0
        ;;
    on)
        _tunon
        ;;
    off)
        _tunoff
        ;;
    *)
        _tunstatus
        ;;
    esac
}

function clashmixin() {
    case "$1" in
    -h | --help)
        cat <<EOF

- 查看 Mixin 配置：$CLASH_CONFIG_MIXIN
  clashmixin

- 编辑 Mixin 配置
  clashmixin -e

- 查看原始订阅配置：$CLASH_CONFIG_BASE
  clashmixin -c

- 查看运行时配置：$CLASH_CONFIG_RUNTIME
  clashmixin -r

EOF
        return 0
        ;;
    -e)
        vim "$CLASH_CONFIG_MIXIN" && {
            _merge_config_restart && _okcat "配置更新成功，已重启生效"
        }
        ;;
    -r)
        less "$CLASH_CONFIG_RUNTIME"
        ;;
    -c)
        less "$CLASH_CONFIG_BASE"
        ;;
    *)
        echo "📋 Mixin 配置管理"
        echo "----------------------------------------"
        echo " [1] 📝 编辑配置文件"
        echo " [2] 📖 查看原始订阅配置"
        echo " [3] 🏃 查看运行时配置"
        echo " [4] 🌐 修改监听地址 (127.0.0.1 / 0.0.0.0)"
        echo "----------------------------------------"
        printf "👉 请输入选项 [1-4]: "
        read -r choice

        case "$choice" in
        1)
            vim "$CLASH_CONFIG_MIXIN" && {
                _merge_config_restart && _okcat "配置更新成功，已重启生效"
            }
            ;;
        2)
            less "$CLASH_CONFIG_BASE"
            ;;
        3)
            less "$CLASH_CONFIG_RUNTIME"
            ;;
        4)
            local current_full=$("$BIN_YQ" '.external-controller // "127.0.0.1:9090"' "$CLASH_CONFIG_MIXIN")
            local current_port="9090"
            if [[ "$current_full" == *":"* ]]; then
                current_port="${current_full##*:}"
            fi

            echo ""
            _okcat "当前监听地址: $current_full"
            echo "👇 请选择新的监听模式 (端口 $current_port 将保持不变):"
            echo " [1] 🏠 127.0.0.1 (仅限本机访问 - 安全)"
            echo " [2] 🌏 0.0.0.0   (允许公网访问 - 需配置密码)"
            printf "👉 请输入 [1/2]: "
            read -r ip_choice

            local new_ip=""
            local pass_action="none"
            local new_pass=""

            case "$ip_choice" in
                1)
                    new_ip="127.0.0.1"
                    echo -n "❓ 是否清除 API 访问密码? [y/N]: "
                    read -r clear_pass
                    [[ "$clear_pass" =~ ^[yY] ]] && pass_action="clear"
                    ;;
                2)
                    new_ip="0.0.0.0"
                    echo -n "❓ 是否立即设置访问密码? (推荐) [Y/n]: "
                    read -r set_pass
                    if [[ ! "$set_pass" =~ ^[nN] ]]; then
                        pass_action="set"
                        while [ -z "$new_pass" ]; do
                            printf "⌨️  请输入新密码: "
                            read -r new_pass
                            [ -z "$new_pass" ] && _failcat "❌ 密码不能为空，请重新输入"
                        done
                    else
                        _okcat "⚠️  警告：公网访问未设密码！请后续使用 clashsecret 设置。"
                    fi
                    ;;
                *) _failcat "❌ 无效选择"; return 1 ;;
            esac

            local new_val="${new_ip}:${current_port}"
            _okcat "🔄 正在应用配置..."

            "$BIN_YQ" -i ".external-controller = \"$new_val\"" "$CLASH_CONFIG_MIXIN" 2>/dev/null

            if [ "$pass_action" == "set" ]; then
                "$BIN_YQ" -i ".secret = \"$new_pass\"" "$CLASH_CONFIG_MIXIN" 2>/dev/null
                _okcat "🔐 密码已更新"
            elif [ "$pass_action" == "clear" ]; then
                "$BIN_YQ" -i '.secret = ""' "$CLASH_CONFIG_MIXIN" 2>/dev/null
                _okcat "🔓 密码已清除"
            fi

            _merge_config_restart && _okcat "✅ 监听地址修改成功 ($new_val)"
            ;;
        esac
        ;;
    esac
}

function clashupgrade() {
    for arg in "$@"; do
        case $arg in
        -h | --help)
            cat <<EOF
Usage:
  clashupgrade [OPTIONS]

Options:
  -v, --verbose       输出内核升级日志
  -r, --release       升级至稳定版
  -a, --alpha         升级至测试版
  -h, --help          显示帮助信息

EOF
            return 0
            ;;
        -v | --verbose)
            local log_flag=true
            ;;
        -r | --release)
            channel="release"
            ;;
        -a | --alpha)
            channel="alpha"
            ;;
        *)
            channel=""
            ;;
        esac
    done

    _detect_ext_addr
    clashstatus >&/dev/null || clashon >/dev/null
    _okcat '⏳' "请求内核升级..."
    [ "$log_flag" = true ] && {
        log_cmd=(placeholder_follow_log)
        ("${log_cmd[@]}" &)

    }
    local res=$(
        curl -X POST \
            --silent \
            --noproxy "*" \
            --location \
            -H "Authorization: Bearer $(_get_secret)" \
            "http://${EXT_IP}:${EXT_PORT}/upgrade?channel=$channel"
    )
    [ "$log_flag" = true ] && pkill -9 -f "${log_cmd[*]}"

    grep '"status":"ok"' <<<"$res" && {
        _okcat "内核升级成功"
        return 0
    }
    grep 'already using latest version' <<<"$res" && {
        _okcat "已是最新版本"
        return 0
    }
    _failcat "内核升级失败，请检查网络或稍后重试"
}

function clashsub() {
    local sub_cmd="$1"
    [ $# -gt 0 ] && shift
    case "$sub_cmd" in
    add)
        _sub_add "$@"
        ;;
    del)
        _sub_del "$@"
        ;;
    list | ls | '')
        _sub_list "$@"
        ;;
    use | ch)
        _sub_use "$@"
        ;;
    update)
        _sub_update "$@"
        ;;
    log)
        _sub_log "$@"
        ;;
    -h | --help | *)
        cat <<EOF
clashsub - Clash 订阅管理工具

Usage: 
  clashsub COMMAND [OPTIONS]

Commands:
  add <url> [name] 添加订阅
  ls              查看订阅
  del <id>        删除订阅
  use <id>        使用订阅 (别名: ch)
  update [id]     更新订阅
  log             订阅日志

Options:
  update:
    --auto        配置自动更新
    --convert     使用订阅转换
EOF
        ;;
    esac
}
_sub_add() {
    local url="$1"
    local name="$2"
    [ -z "$url" ] && {
        echo -n "$(_okcat '✈️ ' '请输入要添加的订阅链接：')"
        read -r url
        [ -z "$url" ] && _error_quit "订阅链接不能为空"
    }
    [ -z "$name" ] && {
        echo -n "$(_okcat '🏷️ ' '请输入订阅名称 [默认: default]：')"
        read -r name
        [ -z "$name" ] && name="default"
    }
    _get_url_by_id "$id" >/dev/null && _error_quit "该订阅链接已存在"

    _download_config "$CLASH_CONFIG_TEMP" "$url"
    _valid_config "$CLASH_CONFIG_TEMP" || _error_quit "订阅无效，请检查：
    原始订阅：${CLASH_CONFIG_TEMP}.raw
    转换订阅：$CLASH_CONFIG_TEMP
    转换日志：$BIN_SUBCONVERTER_LOG"

    local id=$("$BIN_YQ" '.profiles // [] | (map(.id) | max) // 0 | . + 1' "$CLASH_PROFILES_META")
    local profile_path="${CLASH_PROFILES_DIR}/${id}.yaml"
    mv "$CLASH_CONFIG_TEMP" "$profile_path"

    "$BIN_YQ" -i "
         .profiles = (.profiles // []) + 
         [{
           \"id\": $id,
           \"name\": \"$name\",
           \"path\": \"$profile_path\",
           \"url\": \"$url\"
         }]
    " "$CLASH_PROFILES_META"
    _logging_sub "➕ 已添加订阅：[$id] $name ($url)"
    _okcat '🎉' "订阅已添加：[$id] $name"
}
_sub_del() {
    local id=$1
    [ -z "$id" ] && {
        echo -n "$(_okcat '✈️ ' '请输入要删除的订阅 id：')"
        read -r id
        [ -z "$id" ] && _error_quit "订阅 id 不能为空"
    }
    local profile_path url
    profile_path=$(_get_path_by_id "$id") || _error_quit "订阅 id 不存在，请检查"
    url=$(_get_url_by_id "$id")
    use=$("$BIN_YQ" '.use // ""' "$CLASH_PROFILES_META")
    [ "$use" = "$id" ] && _error_quit "删除失败：订阅 $id 正在使用中，请先切换订阅"
    /usr/bin/rm -f "$profile_path"
    "$BIN_YQ" -i "del(.profiles[] | select(.id == \"$id\"))" "$CLASH_PROFILES_META"
    _logging_sub "➖ 已删除订阅：[$id] $url"
    _okcat '🎉' "订阅已删除：[$id] $url"
}
_sub_list() {
    local current_use=$("$BIN_YQ" '.use // ""' "$CLASH_PROFILES_META")
    local current_name=""
    [ -n "$current_use" ] && current_name=$("$BIN_YQ" ".profiles[] | select(.id == $current_use) | .name // \"\"" "$CLASH_PROFILES_META" 2>/dev/null)
    _okcat "当前订阅: [${current_use}] ${current_name:-未知}"
    echo ""
    printf " %-2s  %-12s %-4s %s\n" "St" "Name" "ID" "URL"
    echo "----------------------------------------"
    "$BIN_YQ" '.profiles // [] | .[]' "$CLASH_PROFILES_META" | while read -r entry; do
        :
    done
    local entries=$("$BIN_YQ" -o=json '.profiles // []' "$CLASH_PROFILES_META" 2>/dev/null)
    echo "$entries" | jq -r '.[] | "\(.id)|\(.name // "unnamed")|\(.url // "")"' | while IFS='|' read -r id name url; do
        local mark=" "
        [ "$id" = "$current_use" ] && mark="*"
        local display_url="$url"
        [ ${#display_url} -gt 60 ] && display_url="${display_url:0:57}..."
        printf " %s  %-12s [%s] %s\n" "$mark" "$name" "$id" "$display_url"
    done
}
_sub_use() {
    "$BIN_YQ" -e '.profiles // [] | length == 0' "$CLASH_PROFILES_META" >&/dev/null &&
        _error_quit "当前无可用订阅，请先添加订阅"
    local id=$1
    [ -z "$id" ] && {
        clashsub ls
        echo -n "$(_okcat '✈️ ' '请输入要使用的订阅 id：')"
        read -r id
        [ -z "$id" ] && _error_quit "订阅 id 不能为空"
    }
    local profile_path url
    profile_path=$(_get_path_by_id "$id") || _error_quit "订阅 id 不存在，请检查"
    url=$(_get_url_by_id "$id")
    cat "$profile_path" >|"$CLASH_CONFIG_BASE"
    _merge_config_restart
    "$BIN_YQ" -i ".use = $id" "$CLASH_PROFILES_META"
    _logging_sub "🔥 订阅已切换为：[$id] $url"
    _okcat '🔥' '订阅已生效'
}
_get_path_by_id() {
    "$BIN_YQ" -e ".profiles[] | select(.id == \"$1\") | .path" "$CLASH_PROFILES_META" 2>/dev/null
}
_get_url_by_id() {
    "$BIN_YQ" -e ".profiles[] | select(.id == \"$1\") | .url" "$CLASH_PROFILES_META" 2>/dev/null
}
_sub_update() {
    local arg is_convert
    for arg in "$@"; do
        case $arg in
        --auto)
            command -v crontab >/dev/null || _error_quit "未检测到 crontab 命令，请先安装 cron 服务"
            crontab -l | grep -qs 'clashsub update' || {
                (
                    crontab -l 2>/dev/null
                    echo "0 0 */2 * * $SHELL -i -c 'clashsub update'"
                ) | crontab -
            }
            _okcat "已设置定时更新订阅"
            return 0
            ;;
        --convert)
            is_convert=true
            shift
            ;;
        esac
    done
    local id=$1
    [ -z "$id" ] && id=$("$BIN_YQ" '.use // 1' "$CLASH_PROFILES_META")
    local url profile_path
    url=$(_get_url_by_id "$id") || _error_quit "订阅 id 不存在，请检查"
    profile_path=$(_get_path_by_id "$id")
    _okcat "✈️ " "更新订阅：[$id] $url"

    [ "$is_convert" = true ] && {
        _download_convert_config "$CLASH_CONFIG_TEMP" "$url"
    }
    [ "$is_convert" != true ] && {
        _download_config "$CLASH_CONFIG_TEMP" "$url"
    }
    _valid_config "$CLASH_CONFIG_TEMP" || {
        _logging_sub "❌ 订阅更新失败：[$id] $url"
        _error_quit "订阅无效：请检查：
    原始订阅：${CLASH_CONFIG_TEMP}.raw
    转换订阅：$CLASH_CONFIG_TEMP
    转换日志：$BIN_SUBCONVERTER_LOG"
    }
    _logging_sub "✅ 订阅更新成功：[$id] $url"
    cat "$CLASH_CONFIG_TEMP" >|"$profile_path"
    use=$("$BIN_YQ" '.use // ""' "$CLASH_PROFILES_META")
    [ "$use" = "$id" ] && clashsub use "$use" && return
    _okcat '订阅已更新'
}
_logging_sub() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") $1" >>"${CLASH_PROFILES_LOG}"
}
_sub_log() {
    tail <"${CLASH_PROFILES_LOG}" "$@"
}

# ==============================================================================
# Fusion: Node Info & Switching
# ==============================================================================

_interactive_node_select() {
    _delay_color() {
        local d=$1
        if [ "$d" -lt 200 ] 2>/dev/null; then
            printf "\033[32m"
        elif [ "$d" -lt 500 ] 2>/dev/null; then
            printf "\033[33m"
        else
            printf "\033[31m"
        fi
    }

    local group_name="$1"
    local direct_target="$2"
    local group_enc=$(urlencode "$group_name")
    local group_resp=$(curl_api "/proxies/$group_enc")

    if [[ "$group_resp" != \{* ]]; then echo "❌ 无法获取节点列表 (API 异常)"; return 1; fi

    local nodes=()
    while IFS= read -r node; do nodes+=("$node"); done < <(echo "$group_resp" | jq -r '.all[]')

    if [ -n "$direct_target" ]; then
        local target_node=""
        if [[ "$direct_target" =~ ^[0-9]+$ ]]; then
            if [ "$direct_target" -ge 1 ] && [ "$direct_target" -le "${#nodes[@]}" ]; then
                if [ -n "$ZSH_VERSION" ]; then target_node="${nodes[$direct_target]}"; else target_node="${nodes[$((direct_target - 1))]}"; fi
            else
                echo "❌ 无效编号: $direct_target"
                return 1
            fi
        else
            target_node="$direct_target"
        fi

        echo "🔍 主分组: $group_name"
        echo "🔄 正在切换到: $target_node"

        local payload=$(jq -n --arg name "$target_node" '{name: $name}')
        curl_api "/proxies/$group_enc" -X PUT -H "Content-Type: application/json" -d "$payload" >/dev/null
        local now=$(curl_api "/proxies/$group_enc" | jq -r .now)
        if [ "$now" = "$target_node" ]; then echo "✅ 切换成功！当前: $now"; else
            echo "❌ 切换失败，当前: $now"
        fi
        return 0
    fi

     echo "📋 [$group_name] 可选节点:"
    local current_node=$(echo "$group_resp" | jq -r '.now')

    local all_proxies=$(curl_api "/proxies")

    echo "⚡ 正在测速..."
    (
        for node in "${nodes[@]}"; do
            local node_type=$(echo "$all_proxies" | jq -r --arg n "$node" '.proxies[$n].type // ""')
            [ "$node_type" = "URLTest" ] || [ "$node_type" = "Selector" ] || [ "$node_type" = "Fallback" ] || [ "$node_type" = "LoadBalance" ] && continue
            local nenc=$(urlencode "$node")
            curl_api "/proxies/$nenc/delay?timeout=3000&url=http://www.gstatic.com/generate_204" >/dev/null 2>&1
        done
    ) &
    local test_pid=$!
    wait "$test_pid" 2>/dev/null
    echo -e "\r✅ 测速完成              "

    all_proxies=$(curl_api "/proxies")

    local j=1
    for node in "${nodes[@]}"; do
        local mark=" "
        [ "$node" = "$current_node" ] && mark="*"

        local delay=""
        local delay_color=""
        local extra=""
        local node_type=$(echo "$all_proxies" | jq -r --arg n "$node" '.proxies[$n].type // ""')

        if [ "$node_type" = "URLTest" ] || [ "$node_type" = "Selector" ] || [ "$node_type" = "Fallback" ] || [ "$node_type" = "LoadBalance" ]; then
            local sub_now=$(echo "$all_proxies" | jq -r --arg n "$node" '.proxies[$n].now // ""')
            local best=$(echo "$all_proxies" | jq -r --arg n "$node" '
                [.proxies[$n].all[] | . as $name | $root.proxies[$name].history[-1].delay // 99999] | map(select(. > 0 and . < 99999)) | min
            ' --argjson root "$all_proxies")
            if [ -n "$best" ] && [ "$best" != "null" ] && [ "$best" -lt 99999 ] 2>/dev/null; then
                delay="Best:${best}ms"
                delay_color=$(_delay_color "$best")
            fi
            if [ -n "$sub_now" ] && [ "$sub_now" != "null" ] && [ "$sub_now" != "" ]; then
                extra=" → $sub_now"
            fi
        else
            local d=$(echo "$all_proxies" | jq -r --arg n "$node" '.proxies[$n].history[-1].delay // 0')
            if [ -n "$d" ] && [ "$d" != "null" ] && [ "$d" -gt 0 ] 2>/dev/null; then
                if [ "$d" -ge 5000 ]; then
                    delay="超时"
                    delay_color="\033[31m"
                else
                    delay="${d}ms"
                    delay_color=$(_delay_color "$d")
                fi
            else
                delay="不可用"
                delay_color="\033[31m"
            fi
        fi

        [ -z "$delay" ] && { delay="N/A"; delay_color=""; }
        printf "  %s %2d) %-32s ${delay_color}%-10s\033[0m%s\n" "$mark" "$j" "$node" "$delay" "$extra"
        ((j++))
    done

    printf "\n👉 请输入节点编号: "
    read -r n_idx

    if ! [[ "$n_idx" =~ ^[0-9]+$ ]] || [ "$n_idx" -lt 1 ] || [ "$n_idx" -gt "${#nodes[@]}" ]; then echo "❌ 无效编号"; return 1; fi

    local selected_node=""
    if [ -n "$ZSH_VERSION" ]; then selected_node="${nodes[$n_idx]}"; else selected_node="${nodes[$((n_idx - 1))]}"; fi

    echo "🔄 正在切换到: $selected_node"
    local payload=$(jq -n --arg name "$selected_node" '{name: $name}')
    curl_api "/proxies/$group_enc" -X PUT -H "Content-Type: application/json" -d "$payload" >/dev/null
    local new_now=$(curl_api "/proxies/$group_enc" | jq -r .now)
    [ "$new_now" = "$selected_node" ] && echo "✅ 切换成功" || echo "❌ 切换可能失败"
}

function clashnow() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<EOF

- 查看当前节点信息（分组、节点、延迟、模式）
  clashnow

EOF
        return 0
    fi

    clashstatus >&/dev/null || { _failcat "$KERNEL_NAME 未运行"; return 1; }

    local mode=$(curl_api "/configs" | jq -r .mode)
    local group_display="" node_display="" delay_display="N/A"

    if [ "$mode" = "global" ]; then
        group_display="GLOBAL (全局路由)"
        local global_info=$(curl_api "/proxies/GLOBAL")
        local global_node=$(echo "$global_info" | jq -r .now)
        if [ -n "$global_node" ] && [ "$global_node" != "null" ]; then
            node_display="$global_node"
            local node_enc=$(urlencode "$node_display")
            local d=$(curl_api "/proxies/$node_enc/delay?timeout=2000&url=http://www.gstatic.com/generate_204" | jq -r '.delay // "N/A"')
            [ "$d" != "N/A" ] && delay_display="${d}ms"
        else
            node_display="未知"
        fi
    else
        if [ -f "$CLASH_CONFIG_RUNTIME" ]; then
            group_display=$("$BIN_YQ" '.proxy-groups[] | select(.type == "select") | .name' "$CLASH_CONFIG_RUNTIME" 2>/dev/null | head -n 1)
        fi
        if [ -z "$group_display" ]; then
            local resp=$(curl_api "/proxies")
            group_display=$(echo "$resp" | jq -r '.proxies | to_entries[] | select(.value.type=="Selector" and .key!="GLOBAL" and .key!="Global") | .key' | head -n 1)
        fi
        [ -z "$group_display" ] && group_display="无法识别"

        local group_enc=$(urlencode "$group_display")
        local node_name=$(curl_api "/proxies/$group_enc" | jq -r .now)
        node_display="$node_name"

        if [ -n "$node_name" ] && [ "$node_name" != "null" ]; then
            local node_enc=$(urlencode "$node_name")
            local d=$(curl_api "/proxies/$node_enc/delay?timeout=2000&url=http://www.gstatic.com/generate_204" | jq -r '.delay // "N/A"')
            [ "$d" != "N/A" ] && delay_display="${d}ms"
        fi
    fi

    printf "🎯 主分组: %s\n🚀 节点:  %s\n📶 延迟:  %s\n🛡️  模式:  %s\n" "$group_display" "$node_display" "$delay_display" "$mode"
}

function clashgroup() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<EOF

- 查看所有策略分组
  clashgroup

- 查看指定分组的节点状态（交互式）
  clashgroup -n [<group>]

- 对指定分组所有节点测速
  clashgroup -t [<group>]

EOF
        return 0
    fi

    local target_input="" show_nodes=false do_test=false
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--node) show_nodes=true; shift ;;
            -t|--test) do_test=true; shift ;;
            *) [ -z "$target_input" ] && target_input="$1"; shift ;;
        esac
    done

    local mode=$(curl_api "/configs" | jq -r .mode)

    if [ "$show_nodes" = true ]; then
        if [ -z "$target_input" ]; then
            local all_groups=()
            while IFS= read -r g; do all_groups+=("$g"); done < <("$BIN_YQ" '.proxy-groups[] | select(.type == "select" or .type == "url-test" or .type == "fallback" or .type == "load-balance") | .name' "$CLASH_CONFIG_RUNTIME")
            if [ ${#all_groups[@]} -eq 0 ]; then echo "❌ 未找到策略组"; return 1; fi

            echo "📋 请选择要查看的策略组:"
            local k=1
            for g in "${all_groups[@]}"; do
                printf " [%2d] %s\n" "$k" "$g"
                ((k++))
            done
            printf "👉 输入编号: "; read -r input_idx

            if [[ "$input_idx" =~ ^[0-9]+$ ]] && [ "$input_idx" -ge 1 ] && [ "$input_idx" -le "${#all_groups[@]}" ]; then
                target_input="$input_idx"
            else
                echo "❌ 无效编号"; return 1
            fi
        fi

        if [[ "$target_input" =~ ^[0-9]+$ ]]; then
            local groups=()
            if [ "$mode" = "global" ]; then
                groups=("GLOBAL")
            else
                while IFS= read -r group_name; do groups+=("$group_name"); done < <("$BIN_YQ" '.proxy-groups[] | select(.type == "select" or .type == "url-test" or .type == "fallback" or .type == "load-balance") | .name' "$CLASH_CONFIG_RUNTIME")
            fi
            if [ "$target_input" -ge 1 ] && [ "$target_input" -le "${#groups[@]}" ]; then
                if [ -n "$ZSH_VERSION" ]; then target_input="${groups[$target_input]}"; else target_input="${groups[$((target_input-1))]}"; fi
            else
                echo "❌ 无效序号"; return 1
            fi
        fi

        local target_group="$target_input"
        local resp=$(curl_api "/proxies"); [ -z "$resp" ] && { echo "❌ API 异常"; return 1; }

        local chk=$(echo "$resp" | jq -r --arg g "$target_group" '.proxies[$g].all')
        if [ "$chk" = "null" ] || [ "$chk" = "" ]; then echo "❌ 策略组 '$target_group' 不存在"; return 1; fi

        if [ "$do_test" = true ]; then
            echo "⚡️ 测速中..."
            local n_list=()
            while IFS= read -r n; do n_list+=("$n"); done < <(echo "$resp" | jq -r --arg g "$target_group" '.proxies[$g].all[]')
            set +m
            for n in "${n_list[@]}"; do
                local nenc=$(urlencode "$n")
                curl_api "/proxies/$nenc/delay?timeout=2000&url=http://www.gstatic.com/generate_204" >/dev/null 2>&1 &
            done
            local spin='-\|/'; local i=0; while kill -0 $! 2>/dev/null; do i=$(( (i+1) %4 )); printf "\r⏳ %s" "${spin:$i:1}"; sleep 0.1; done; wait; set -m
            echo -e "\r✅ 完成        "
            resp=$(curl_api "/proxies")
        fi

        echo "📂 策略组: $target_group"
        echo "🏆 延迟最低 Top 5:"
        echo "$resp" | jq -r --arg g "$target_group" '.proxies as $root | [ $root[$g].all[] | {name: ., delay: ($root[.].history[-1].delay // 99999)} ] | map(select(.name | test("自动|直连|流量|到期|剩余|重置|官网|故障|群组|DIRECT|REJECT"; "i") | not)) | map(select(.delay > 0 and .delay < 99999)) | sort_by(.delay) | unique_by(if .name | test("[\\x{1F1E6}-\\x{1F1FF}]{2}") then (.name | match("[\\x{1F1E6}-\\x{1F1FF}]{2}").string) else (.name | gsub("\\d+|\\s+|-|_"; "") | ascii_upcase) end) | sort_by(.delay) | .[:5] | .[] | "   🚀 \(.name) (\(.delay)ms)"'
        echo "----------------------------------------"
        echo "📋 节点列表:"
        _interactive_node_select "$target_group" ""
    else
        local resp=$(curl_api "/proxies"); [ -z "$resp" ] && return 1
        echo "📋 策略分组列表："
        (
            echo "🆔 编号|📂 分组名称|👉 当前选中|⚡ 延迟"
            echo "---|---|---|---"

            local i=1
            "$BIN_YQ" '.proxy-groups[] | select(.type == "select" or .type == "url-test" or .type == "fallback" or .type == "load-balance") | .name' "$CLASH_CONFIG_RUNTIME" | while read -r n; do
                local info=$(echo "$resp" | jq -r --arg g "$n" '
                    .proxies[$g].now as $cur |
                    (.proxies[$cur].history[-1].delay // 0) as $d |
                    $cur + "|" + (if $d == 0 then "N/A" else ($d | tostring) + "ms" end)
                ')
                local now="${info%|*}"; local delay="${info#*|}"
                if [ "$now" != "null" ] && [ -n "$now" ]; then echo "$i|$n|$now|$delay"; ((i++)); fi
            done
        ) | column -t -s '|'
    fi
}

function clashch() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<EOF

- 交互式切换主策略组的节点
  clashch -n [<node>]

- 交互式选择策略组并切换节点
  clashch -g [<group>]

- 切换到订阅管理
  clashch -s

- 切换代理模式 [rule|global|direct]
  clashch -m [<mode>]

- 直接指定节点名切换
  clashch <node_name>

EOF
        return 0
    fi

    local cmd="$1"
    [ $# -gt 0 ] && shift

    case "$cmd" in
    -m|--mode)
        local target_mode="$1"
        if [ -z "$target_mode" ]; then
            clashstatus >&/dev/null || { _failcat "服务未运行"; return 1; }
            local current_mode=$(curl_api "/configs" | jq -r .mode 2>/dev/null)
            echo "🛡️  当前模式: ${current_mode:-未知}"
            echo "📋 请选择要切换的模式:"
            echo "   [1] Rule   (规则模式 - 推荐)"
            echo "   [2] Global (全局模式)"
            echo "   [3] Direct (直连模式)"
            echo
            printf "👉 请输入编号 [1-3]: "
            read -r choice
            case "$choice" in
                1|[rR]*) target_mode="rule" ;;
                2|[gG]*) target_mode="global" ;;
                3|[dD]*) target_mode="direct" ;;
                *) echo "❌ 取消操作"; return 1 ;;
            esac
        fi
        target_mode=$(echo "$target_mode" | tr '[:upper:]' '[:lower:]')
        if [[ "$target_mode" == "global" || "$target_mode" == "rule" || "$target_mode" == "direct" ]]; then
            local payload=$(jq -n --arg mode "$target_mode" '{mode: $mode}')
            if curl_api "/configs" -X PATCH -d "$payload" >/dev/null; then
                _okcat "✅ 核心模式已切换为: $target_mode"
            else
                _failcat "❌ 切换失败"; return 1
            fi
        else
            _failcat "❌ 无效模式: $target_mode"; return 1
        fi
        ;;

    -g|-group)
        local target_idx="$1"
        local groups=()
        while IFS= read -r group_name; do groups+=("$group_name"); done < <("$BIN_YQ" '.proxy-groups[] | select(.type == "select" or .type == "url-test" or .type == "fallback" or .type == "load-balance") | .name' "$CLASH_CONFIG_RUNTIME")
        [ ${#groups[@]} -eq 0 ] && { echo "❌ 无分组"; return 1; }
        local selected_group=""
        if [[ "$target_idx" =~ ^[0-9]+$ ]]; then
            if [ "$target_idx" -ge 1 ] && [ "$target_idx" -le "${#groups[@]}" ]; then
                if [ -n "$ZSH_VERSION" ]; then selected_group="${groups[$target_idx]}"; else selected_group="${groups[$((target_idx-1))]}"; fi
                echo "✅ 选中: $selected_group"
            else echo "❌ 无效编号"; return 1; fi
        else
            echo "📋 可用策略组:"
            echo "----------------------------------------"
            local k=1; for g in "${groups[@]}"; do printf " [%2d] %s\n" "$k" "$g"; ((k++)); done
            echo "----------------------------------------"
            printf "👉 分组编号: "; read -r input_idx
            if [[ "$input_idx" =~ ^[0-9]+$ ]] && [ "$input_idx" -ge 1 ] && [ "$input_idx" -le "${#groups[@]}" ]; then
                if [ -n "$ZSH_VERSION" ]; then selected_group="${groups[$input_idx]}"; else selected_group="${groups[$((input_idx-1))]}"; fi
            else echo "❌ 无效"; return 1; fi
        fi
        _interactive_node_select "$selected_group" ""
        ;;

    -s|-subscribe)
        clashsub "$@"
        ;;

    -n|-node)
        local target="$1"
        local resp=$(curl_api "/proxies"); [ -z "$resp" ] && return 1
        local grp=$("$BIN_YQ" '.proxy-groups[] | select(.type == "select") | .name' "$CLASH_CONFIG_RUNTIME" 2>/dev/null | head -n 1)
        [ -z "$grp" ] && grp=$(echo "$resp" | jq -r '.proxies | to_entries[] | select(.value.type=="Selector" and .key!="GLOBAL" and .key!="Global") | .key' | head -n 1)
        [ -z "$grp" ] && { echo "❌ 无法识别主分组"; return 1; }
        [ -z "$target" ] && { _interactive_node_select "$grp" ""; return 0; }
        echo "🔍 主分组: $grp"; _interactive_node_select "$grp" "$target"
        ;;

    '')
        echo "📋 快速切换菜单"
        echo "----------------------------------------"
        echo " -n [<node>]   切换节点"
        echo " -g [<group>]  切换策略组"
        echo " -s            切换订阅"
        echo " -m [<mode>]   切换模式 [rule|global|direct]"
        echo " <node_name>   直接切换到指定节点"
        echo "----------------------------------------"
        return 0
        ;;

    *)
        local direct_target="$cmd"
        local mode=$(curl_api "/configs" | jq -r .mode 2>/dev/null)
        local grp=""

        if [ "$mode" = "global" ]; then
            grp="GLOBAL"
        else
            local resp=$(curl_api "/proxies"); [ -z "$resp" ] && return 1
            grp=$("$BIN_YQ" '.proxy-groups[] | select(.type == "select") | .name' "$CLASH_CONFIG_RUNTIME" 2>/dev/null | head -n 1)
            [ -z "$grp" ] && grp=$(echo "$resp" | jq -r '.proxies | to_entries[] | select(.value.type=="Selector" and .key!="GLOBAL" and .key!="Global") | .key' | head -n 1)
        fi

        [ -z "$grp" ] && { echo "❌ 无法识别操作分组"; return 1; }
        _interactive_node_select "$grp" "$direct_target"
        ;;
    esac
}

# ==============================================================================
# Fusion: Port Management
# ==============================================================================

CLASH_PORT_PREF="${CLASH_RESOURCES_DIR}/port.pref"

_load_port_preferences() {
    PORT_PREF_MODE=auto
    PORT_PREF_VALUE=""
    [ -f "$CLASH_PORT_PREF" ] || return 0
    while IFS='=' read -r key value; do
        case "$key" in
        PROXY_MODE) [ -n "$value" ] && PORT_PREF_MODE=$value ;;
        PROXY_PORT) PORT_PREF_VALUE=$value ;;
        esac
    done < "$CLASH_PORT_PREF"
    [ "$PORT_PREF_MODE" = "manual" ] || PORT_PREF_MODE=auto
}

_save_port_preferences() {
    local mode=$1
    local value=$2
    mkdir -p "$(dirname "$CLASH_PORT_PREF")"
    cat > "$CLASH_PORT_PREF" <<EOF
PROXY_MODE=$mode
PROXY_PORT=$value
EOF
}

function clashport() {
    case "$1" in
    -h|--help)
        cat <<EOF

- 查看当前端口模式与端口
  clashport

- 切换为自动分配端口
  clashport auto

- 固定代理端口
  clashport set <port>

EOF
        return 0
        ;;
    esac
    local action=$1; [ $# -gt 0 ] && shift
    case "$action" in
    ""|status)
        _load_port_preferences
        local mixed_port=$("$BIN_YQ" '.mixed-port // ""' "$CLASH_CONFIG_RUNTIME")
        local mode_msg="自动"; [ "$PORT_PREF_MODE" = "manual" ] && [ -n "$PORT_PREF_VALUE" ] && mode_msg="固定(${PORT_PREF_VALUE})"
        _okcat "端口模式：$mode_msg"; _okcat "当前代理端口：${mixed_port:-7890}"
        ;;
    auto)
        _save_port_preferences auto ""
        _okcat "已切换为自动分配代理端口"
        clashstatus >&/dev/null && { _okcat "正在重新应用配置..."; clashrestart; }
        ;;
    set|manual)
        local manual_port=$1
        while true; do
            [ -z "$manual_port" ] && { printf "请输入想要固定的代理端口 [1024-65535]: "; read -r manual_port; }
            [ -z "$manual_port" ] && { _failcat "未输入端口"; continue; }
            if ! [[ $manual_port =~ ^[0-9]+$ ]] || [ "$manual_port" -lt 1024 ] || [ "$manual_port" -gt 65535 ]; then
                _failcat "端口号无效，请输入 1024-65535 之间的数字"; manual_port=""; continue
            fi
            if _is_port_used "$manual_port" && ! curl -s --noproxy "*" "127.0.0.1:${manual_port}" 2>/dev/null | grep -qs "$KERNEL_NAME"; then
                _failcat '🎯' "端口 $manual_port 已被占用"
                printf "选择操作 [r]重新输入/[a]自动分配: "; read -r choice
                case "$choice" in
                    [aA]) _save_port_preferences auto ""; _okcat "已切换为自动分配代理端口"; break ;;
                    *) manual_port=""; continue ;;
                esac
            else
                _save_port_preferences manual "$manual_port"
                "$BIN_YQ" -i ".mixed-port = $manual_port" "$CLASH_CONFIG_MIXIN"
                _merge_config
                _okcat "已固定代理端口：$manual_port"
                break
            fi
        done
        clashstatus >&/dev/null && { _okcat "正在重新应用配置..."; clashrestart; }
        ;;
    *) clashport -h ;;
    esac
}

function clashctl() {
    case "$1" in
    on)
        shift
        clashon
        ;;
    off)
        shift
        clashoff
        ;;
    ui)
        shift
        clashui "$@"
        ;;
    status)
        shift
        clashstatus "$@"
        ;;
    log)
        shift
        clashlog "$@"
        ;;
    proxy)
        shift
        clashproxy "$@"
        ;;
    tun)
        shift
        clashtun "$@"
        ;;
    mixin)
        shift
        clashmixin "$@"
        ;;
    secret)
        shift
        clashsecret "$@"
        ;;
    sub)
        shift
        clashsub "$@"
        ;;
    upgrade)
        shift
        clashupgrade "$@"
        ;;
    now|node)
        shift
        clashnow "$@"
        ;;
    group)
        shift
        clashgroup "$@"
        ;;
    ch)
        shift
        clashch "$@"
        ;;
    port)
        shift
        clashport "$@"
        ;;
    *)
        (($#)) && shift
        clashhelp "$@"
        ;;
    esac
}

clashhelp() {
    cat <<EOF

Usage: 
  clashctl COMMAND [OPTIONS]

Aliases: clash, mihomo, mi

Commands:
  on                    开启代理
  off                   关闭代理
  proxy                 系统代理
  status                内核状态
  now                   当前节点信息（分组/节点/延迟/模式）
  group                 策略分组（-n 查看节点，-t 测速）
  ch                    快速切换（-n 节点，-g 分组，-m 模式，-s 订阅）
  ui                    面板地址（update 更新 UI）
  port                  端口管理（auto 自动，set <port> 固定）
  sub                   订阅管理（add/ls/del/use/update）
  log                   内核日志
  tun                   Tun 模式
  mixin                 Mixin 配置
  secret                Web 密钥
  upgrade               升级内核

Global Options:
  -h, --help            显示帮助信息

For more help on how to use clashctl, head to https://github.com/nelvko/clash-for-linux-install
EOF
}
