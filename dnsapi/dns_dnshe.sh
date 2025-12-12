#!/usr/bin/env sh
# shellcheck disable=SC2034,SC2116
dns_dnshe_info='DNSHE
Site: DNSHE.com
Docs: https://docs.dnshe.com/api/
Options:
 DNSHE_API_KEY API Key
 DNSHE_API_SECRET API Secret
'

# DNSHE API 基础地址
DNSHE_API_BASE="https://api005.dnshe.com/index.php?m=domain_hub"

########  Public functions #####################

# 添加TXT记录（ACME标准入口）
# Usage: dns_dnshe_add _acme-challenge.www.domain.com "txt_value"
dns_dnshe_add() {
  fulldomain=$1
  txtvalue=$2

  # 读取配置（兼容acme.sh账户系统）
  DNSHE_API_KEY="${DNSHE_API_KEY:-$(_readaccountconf_mutable DNSHE_API_KEY)}"
  DNSHE_API_SECRET="${DNSHE_API_SECRET:-$(_readaccountconf_mutable DNSHE_API_SECRET)}"

  # 配置校验
  if [ -z "$DNSHE_API_KEY" ] || [ -z "$DNSHE_API_SECRET" ]; then
    _err "未配置DNSHE_API_KEY或DNSHE_API_SECRET"
    _err "请执行: export DNSHE_API_KEY='你的密钥' && export DNSHE_API_SECRET='你的秘钥'"
    return 1
  fi

  # 保存配置到账户文件
  _saveaccountconf_mutable DNSHE_API_KEY "$DNSHE_API_KEY"
  _saveaccountconf_mutable DNSHE_API_SECRET "$DNSHE_API_SECRET"

  _debug "开始添加TXT记录: $fulldomain -> $txtvalue"

  # 解析根域名和子域名
  if ! _dnshe_get_root "$fulldomain"; then
    _err "解析域名失败: $fulldomain"
    return 1
  fi
  _debug "_sub_domain: $_sub_domain"
  _debug "_domain: $_domain"

  # 检查记录是否已存在
  if _dnshe_txt_exists "$_domain" "$fulldomain" "$txtvalue"; then
    _info "记录已存在，跳过添加: $fulldomain = $txtvalue"
    return 0
  fi

  # 获取子域ID
  if ! _dnshe_get_subdomain_id "$_domain" "$_sub_domain"; then
    _err "获取子域ID失败: $_sub_domain.$_domain"
    return 1
  fi

  # 构建创建记录的请求数据
  create_data=$(printf '{"subdomain_id": "%s", "type": "TXT", "name": "%s", "content": "%s", "ttl": 600}' \
    "$_subdomain_id" "$fulldomain" "$txtvalue")
  
  # 调用API创建记录
  if ! _dnshe_rest POST "endpoint=dns_records&action=create" "$create_data"; then
    _err "创建TXT记录失败: $fulldomain"
    return 1
  fi

  # 验证记录是否创建成功
  if ! _dnshe_txt_exists "$_domain" "$fulldomain" "$txtvalue"; then
    _err "验证记录创建失败: $fulldomain"
    return 1
  fi

  _sleep 10
  _info "TXT记录添加成功: $fulldomain = $txtvalue"
  return 0
}

# 删除TXT记录（ACME标准入口）
# Usage: dns_dnshe_rm _acme-challenge.www.domain.com "txt_value"
dns_dnshe_rm() {
  fulldomain=$1
  txtvalue=$2

  # 读取配置
  DNSHE_API_KEY="${DNSHE_API_KEY:-$(_readaccountconf_mutable DNSHE_API_KEY)}"
  DNSHE_API_SECRET="${DNSHE_API_SECRET:-$(_readaccountconf_mutable DNSHE_API_SECRET)}"

  if [ -z "$DNSHE_API_KEY" ] || [ -z "$DNSHE_API_SECRET" ]; then
    _err "未配置DNSHE_API_KEY或DNSHE_API_SECRET"
    return 1
  fi

  _debug "开始删除TXT记录: $fulldomain -> $txtvalue"

  # 解析根域名和子域名
  if ! _dnshe_get_root "$fulldomain"; then
    _err "解析域名失败: $fulldomain"
    return 1
  fi

  # 检查记录是否存在
  if ! _dnshe_txt_exists "$_domain" "$fulldomain" "$txtvalue"; then
    _info "记录不存在，跳过删除: $fulldomain"
    return 0
  fi

  # 获取记录ID
  record_id=$(_dnshe_get_record_id "$_domain" "$fulldomain" "$txtvalue")
  if [ -z "$record_id" ]; then
    _err "获取记录ID失败: $fulldomain"
    return 1
  fi

  # 调用API删除记录
  delete_data=$(printf '{"record_id": "%s"}' "$record_id")
  if ! _dnshe_rest POST "endpoint=dns_records&action=delete" "$delete_data"; then
    _err "删除TXT记录失败: $fulldomain"
    return 1
  fi

  _info "TXT记录删除成功: $fulldomain = $txtvalue"
  return 0
}

####################  Private functions below ##################################

# 解析根域名和子域名
# 输入: _acme-challenge.www.domain.com
# 输出: _sub_domain=_acme-challenge.www, _domain=domain.com
_dnshe_get_root() {
  local domain=$1
  local i=3
  local a="init"
  local h=""
  local n=0
  local s=0

  # 循环截取域名后缀，查找有效的根域名
  while [ -n "$a" ]; do
    a=$(echo "$domain" | cut -d . -f $i-)
    i=$((i + 1))
  done

  n=$((i - 3))
  h=$(echo "$domain" | cut -d . -f $n-)
  
  if [ -z "$h" ]; then
    _err "域名格式无效: $domain"
    return 1
  fi

  # 验证根域名是否存在
  if ! _dnshe_rest GET "endpoint=subdomains&action=list&subdomain=$h"; then
    _err "根域名不存在: $h"
    return 1
  fi

  if _contains "$response" "\"success\":false"; then
    _err "根域名验证失败: $h"
    return 1
  fi

  s=$((n - 1))
  _sub_domain=$(echo "$domain" | cut -d . -f -$s)
  _domain="$h"
  
  return 0
}

# 检查TXT记录是否存在
_dnshe_txt_exists() {
  local zone=$1
  local domain=$2
  local content=$3
  local record_list=""

  # 获取域名的TXT记录列表
  if ! _dnshe_rest GET "endpoint=dns_records&action=list&subdomain=$zone&type=TXT"; then
    return 1
  fi

  # 检查响应中是否包含目标记录内容
  if echo "$response" | grep -q "\"content\":\"$content\""; then
    return 0
  else
    return 1
  fi
}

# 获取子域ID
_dnshe_get_subdomain_id() {
  local zone=$1
  local subdomain=$2
  
  if ! _dnshe_rest GET "endpoint=subdomains&action=list&subdomain=$subdomain.$zone"; then
    return 1
  fi

  # 从响应中提取子域ID
  _subdomain_id=$(echo "$response" | tr '}' '\n' | grep '"id":' | head -1 | sed 's/.*"id":"\([0-9]*\)".*/\1/')
  
  if [ -z "$_subdomain_id" ]; then
    return 1
  fi

  return 0
}

# 获取TXT记录ID
_dnshe_get_record_id() {
  local zone=$1
  local domain=$2
  local content=$3
  local record_id=""

  if ! _dnshe_rest GET "endpoint=dns_records&action=list&subdomain=$zone&type=TXT"; then
    return 1
  fi

  # 从响应中提取匹配的记录ID
  record_id=$(echo "$response" | tr '}' '\n' | grep "\"content\":\"$content\"" | grep "\"name\":\"$domain\"" | sed 's/.*"id":"\([0-9]*\)".*/\1/')
  
  echo "$record_id"
}

# 统一API请求封装
_dnshe_rest() {
  local method=$1
  local path_params=$2
  local content_data=${3:-""}
  local url="${DNSHE_API_BASE}&${path_params}"
  local response_code=""

  # 设置请求头
  export _H1="Content-Type: application/json"
  export _H2="X-API-Key: ${DNSHE_API_KEY}"
  export _H3="X-API-Secret: ${DNSHE_API_SECRET}"

  _debug "API请求: $method $url"
  _debug2 "请求数据: $content_data"

  # 执行请求
  if [ "$method" = "POST" ] && [ -n "$content_data" ]; then
    response="$(_post "$content_data" "$url" "" "POST")"
  else
    response="$(_get "$url")"
  fi

  # 获取响应状态码
  response_code=$(grep "^HTTP" "$HTTP_HEADER" | tail -1 | cut -d " " -f 2 | tr -d "\r\n")
  _debug "响应状态码: $response_code"
  _debug2 "响应内容: $response"

  # 状态码校验
  if [ "$response_code" != "200" ]; then
    _err "API请求失败，状态码: $response_code"
    return 1
  fi

  # 业务状态校验
  if echo "$response" | grep -q "\"success\":false"; then
    local err_msg=$(echo "$response" | sed 's/.*"error":"\([^"]*\)".*/\1/')
    _err "API业务错误: $err_msg"
    return 1
  fi

  return 0
}
