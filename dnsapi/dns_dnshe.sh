#!/usr/bin/env sh
# shellcheck disable=SC2034,SC2086,SC2116,SC2001,SC1004
dns_dnshe_info='DNSHE
Site: DNSHE.com
Docs: https://docs.dnshe.com/api/
Options:
 DNSHE_API_KEY API Key
 DNSHE_API_SECRET API Secret
'

# DNSHE API 基础地址
DNSHE_Api="https://api005.dnshe.com/index.php?m=domain_hub"

########  Public functions #####################

# 添加TXT记录（ACME调用入口）
dns_dnshe_add() {
  fulldomain="$1"
  txtvalue="$2"

  # 读取配置（兼容acme.sh账户系统）
  DNSHE_API_KEY="${DNSHE_API_KEY:-$(_readaccountconf_mutable DNSHE_API_KEY)}"
  DNSHE_API_SECRET="${DNSHE_API_SECRET:-$(_readaccountconf_mutable DNSHE_API_SECRET)}"

  # 配置校验
  if [ -z "$DNSHE_API_KEY" ] || [ -z "$DNSHE_API_SECRET" ]; then
    _err "未配置 DNSHE_API_KEY 或 DNSHE_API_SECRET"
    _err "请先执行: export DNSHE_API_KEY='你的API密钥' && export DNSHE_API_SECRET='你的API密钥秘钥'"
    return 1
  fi

  # 核心新增：保存凭证到acme.sh账户配置文件（自动续证关键）
  _saveaccountconf_mutable DNSHE_API_KEY "$DNSHE_API_KEY"
  _saveaccountconf_mutable DNSHE_API_SECRET "$DNSHE_API_SECRET"
  _info "已保存DNSHE API凭证到账户配置文件（自动续证将复用）"

  _info "开始处理TXT记录: $fulldomain → $txtvalue"

  # 域名解析（拆分前缀+子域）
  if ! _dnshe_split_domain "$fulldomain"; then
    _err "域名解析失败: $fulldomain"
    return 1
  fi
  _debug "_root_domain: $_root_domain"
  _debug "_target_subdomain: $_target_subdomain"
  _debug "_txt_prefix: $_txt_prefix"       # TXT记录前缀（如 _acme-challenge）
  _debug "_full_txt_domain: $_full_txt_domain"

  # 获取一级子域ID
  if ! _dnshe_get_subdomain_id; then
    return 1
  fi
  _debug "_subdomain_id: $_subdomain_id"

  # 查询现有记录（精准匹配域名+内容）
  _dnshe_get_txt_record_id "$txtvalue"
  
  # 存在则检查内容，不存在则创建
  if [ -n "$_record_id" ]; then
    # 验证记录内容是否一致
    if _dnshe_check_record_content "$txtvalue"; then
      _info "TXT记录已存在且内容一致（ID: $_record_id），无需更新"
    else
      _info "TXT记录内容不一致，执行更新操作（ID: $_record_id）"
      if ! _dnshe_update_txt_record "$txtvalue"; then
        # 更新失败（冲突），尝试删除后重建
        _err "更新TXT记录失败，尝试删除冲突记录后重建"
        if _dnshe_delete_txt_record && _dnshe_create_txt_record "$txtvalue"; then
          _info "冲突记录已删除并重建成功"
        else
          _err "删除并重建TXT记录失败"
          return 1
        fi
      fi
    fi
  else
    # 检查是否存在同名不同内容的记录（冲突检测）
    _dnshe_check_same_name_record
    if [ -n "$_conflict_record_id" ]; then
      _warn "发现同名不同内容的TXT记录（ID: $_conflict_record_id），先删除冲突记录"
      if ! _dnshe_delete_specific_record "$_conflict_record_id"; then
        _err "删除冲突记录失败"
        return 1
      fi
    fi
    
    _info "TXT记录不存在，执行创建操作"
    if [ -z "$_subdomain_id" ]; then
      _err "子域ID为空，无法创建记录"
      return 1
    fi
    if ! _dnshe_create_txt_record "$txtvalue"; then
      _err "创建TXT记录失败"
      return 1
    fi
  fi

  # 强制等待DNS生效
  _sleep 10
  return 0
}

# 删除TXT记录（ACME调用入口）
dns_dnshe_rm() {
  fulldomain="$1"
  txtvalue="$2"

  # 读取配置
  DNSHE_API_KEY="${DNSHE_API_KEY:-$(_readaccountconf_mutable DNSHE_API_KEY)}"
  DNSHE_API_SECRET="${DNSHE_API_SECRET:-$(_readaccountconf_mutable DNSHE_API_SECRET)}"

  if [ -z "$DNSHE_API_KEY" ] || [ -z "$DNSHE_API_SECRET" ]; then
    _err "未配置 DNSHE_API_KEY 或 DNSHE_API_SECRET"
    return 1
  fi

  _info "开始删除TXT记录: $fulldomain → $txtvalue"

  # 解析域名
  if ! _dnshe_split_domain "$fulldomain"; then
    _err "域名解析失败: $fulldomain"
    return 1
  fi

  # 获取子域ID
  if ! _dnshe_get_subdomain_id; then
    _err "获取子域ID失败，跳过删除"
    return 0
  fi

  # 查询记录ID（精准匹配域名+内容）
  _dnshe_get_txt_record_id "$txtvalue"

  # 删除记录
  if [ -n "$_record_id" ]; then
    if ! _dnshe_delete_txt_record; then
      _err "删除TXT记录失败"
      return 1
    fi
    _info "TXT记录删除成功（ID: $_record_id）"
  else
    # 检查是否存在同名不同内容的记录
    _dnshe_check_same_name_record
    if [ -n "$_conflict_record_id" ]; then
      _warn "未找到指定内容的TXT记录，但发现同名记录（ID: $_conflict_record_id），尝试删除"
      if _dnshe_delete_specific_record "$_conflict_record_id"; then
        _info "同名冲突记录已删除（ID: $_conflict_record_id）"
      else
        _err "删除同名冲突记录失败"
        return 1
      fi
    else
      _info "未找到需要删除的TXT记录"
    fi
  fi

  return 0
}

####################  Private functions ##################################

# 域名拆分（核心修改：拆分TXT前缀 + 子域）
_dnshe_split_domain() {
  local domain="$1"
  # 清除首尾多余的点
  domain=$(echo "$domain" | sed -e 's/\.\+$//' -e 's/^\.\+//')
  IFS='.' read -ra parts <<< "$domain"
  local part_count=${#parts[@]}

  if [ "$part_count" -lt 2 ]; then
    _err "域名格式非法: $domain（至少需要二级域名）"
    return 1
  fi

  # 根域 = 最后两段
  _root_domain="${parts[$((part_count-2))]}.${parts[$((part_count-1))]}"
  
  # 目标子域 = 完整的一级子域（如 lrx.cc.cd）
  if [ "$part_count" -eq 2 ]; then
    # 二级域名（如 de5.net）
    _target_subdomain="$_root_domain"
    _txt_prefix="@"  # 根域前缀用@表示
  elif [ "$part_count" -eq 3 ]; then
    # 三级域名（如 lrx.de5.net）
    _target_subdomain="$domain"
    _txt_prefix="${parts[0]}"  # 前缀=第一段（如 lrx）
  else
    # 四级及以上域名（如 _acme-challenge.lrx.de5.net）
    # 目标子域 = 倒数3段（lrx.de5.net）
    _target_subdomain="${parts[$((part_count-3))]}.${parts[$((part_count-2))]}.${parts[$((part_count-1))]}"
    # TXT前缀 = 除了目标子域外的部分（如 _acme-challenge）
    _txt_prefix=""
    for ((i=0; i <= part_count-4; i++)); do
      _txt_prefix="${_txt_prefix}${parts[$i]}."
    done
    # 去除末尾的点
    _txt_prefix=$(echo "$_txt_prefix" | sed 's/\.\+$//')
  fi

  # 保存完整的TXT记录域名（用于匹配查询）
  _full_txt_domain="$domain"

  # 调试输出关键变量
  _debug "拆分结果：前缀=$_txt_prefix，子域=$_target_subdomain，完整域名=$_full_txt_domain"
  return 0
}

# 获取子域ID
_dnshe_get_subdomain_id() {
  local subdomain_list_url="${DNSHE_Api}&endpoint=subdomains&action=list"
  local subdomain_list_resp
  subdomain_list_resp=$(_dnshe_rest GET "$subdomain_list_url")
  
  if ! _dnshe_is_success "$subdomain_list_resp"; then
    local err
    err=$(_dnshe_extract_error "$subdomain_list_resp")
    _err "查询子域列表失败: $err"
    return 1
  fi

  _debug "待匹配的目标子域: $_target_subdomain"

  _subdomain_id=""
  local current_id=""
  local current_subdomain=""
  
  # 拆分JSON为单行
  local json_lines
  json_lines=$(echo "$subdomain_list_resp" | tr '}' '\n' | tr ',' '\n' | tr '{' '\n')
  
  # 逐行解析
  while IFS= read -r line; do
    if echo "$line" | grep -q '"id":'; then
      current_id=$(echo "$line" | sed 's/[^0-9]//g')
    fi
    if echo "$line" | grep -q '"subdomain":"'; then
      current_subdomain=$(echo "$line" | sed 's/.*"subdomain":"//;s/".*//' | tr -d ' ')
      if [ "$current_subdomain" = "$_target_subdomain" ] && [ -n "$current_id" ]; then
        _subdomain_id="$current_id"
        break
      fi
    fi
  done <<< "$json_lines"

  if [ -z "$_subdomain_id" ]; then
    _err "未找到子域: $_target_subdomain（请先在DNSHE后台注册该子域）"
    local available_subdomains
    available_subdomains=$(echo "$subdomain_list_resp" | tr '}' '\n' | tr ',' '\n' | grep '"subdomain":"' | sed 's/.*"subdomain":"//;s/".*//' | tr -d ' ' | sort | uniq)
    _err "当前可用子域列表: $available_subdomains"
    return 1
  fi

  _info "找到子域: $_target_subdomain (ID: $_subdomain_id)"
  return 0
}

# 精准查询TXT记录ID（域名+内容）
_dnshe_get_txt_record_id() {
  local txt_value="$1"
  local list_url="${DNSHE_Api}&endpoint=dns_records&action=list&subdomain_id=$_subdomain_id"
  local list_resp
  list_resp=$(_dnshe_rest GET "$list_url")

  if ! _dnshe_is_success "$list_resp"; then
    local err
    err=$(_dnshe_extract_error "$list_resp")
    _err "查询DNS记录列表失败: $err"
    _record_id=""
    return 1
  fi

  # 初始化变量
  _record_id=""
  local current_id=""
  local current_type=""
  local current_name=""
  local current_content=""
  
  # 拆分JSON为单行
  local json_lines
  json_lines=$(echo "$list_resp" | tr '}' '\n' | tr ',' '\n' | tr '{' '\n')
  
  # 逐行解析（精准匹配）
  while IFS= read -r line; do
    # 提取ID
    if echo "$line" | grep -q '"id":'; then
      current_id=$(echo "$line" | sed 's/[^0-9]//g')
    fi
    # 提取类型
    if echo "$line" | grep -q '"type":"'; then
      current_type=$(echo "$line" | sed 's/.*"type":"//;s/".*//' | tr -d ' ')
    fi
    # 提取完整域名（用于匹配）
    if echo "$line" | grep -q '"name":"'; then
      current_name=$(echo "$line" | sed 's/.*"name":"//;s/".*//' | tr -d ' ')
    fi
    # 提取内容（核心：精准匹配）
    if echo "$line" | grep -q '"content":"'; then
      current_content=$(echo "$line" | sed 's/.*"content":"//;s/".*//' | tr -d ' ')
      
      # 严格匹配：类型=TXT + 完整域名 + 内容完全一致
      if [ "$current_type" = "TXT" ] && [ "$current_name" = "$_full_txt_domain" ] && [ "$current_content" = "$txt_value" ] && [ -n "$current_id" ]; then
        _record_id="$current_id"
        break
      fi
    fi
  done <<< "$json_lines"

  _debug "精准匹配到的TXT记录ID: $_record_id"
  return 0
}

# 检查记录内容是否一致
_dnshe_check_record_content() {
  local txt_value="$1"
  local list_url="${DNSHE_Api}&endpoint=dns_records&action=list&subdomain_id=$_subdomain_id"
  local list_resp
  list_resp=$(_dnshe_rest GET "$list_url")

  local current_content=""
  local json_lines
  json_lines=$(echo "$list_resp" | tr '}' '\n' | tr ',' '\n' | tr '{' '\n')
  
  while IFS= read -r line; do
    if echo "$line" | grep -q "\"id\":\"$_record_id\""; then
      # 定位到目标记录后提取内容
      if echo "$line" | grep -q '"content":"'; then
        current_content=$(echo "$line" | sed 's/.*"content":"//;s/".*//' | tr -d ' ')
        break
      fi
    fi
  done <<< "$json_lines"

  if [ "$current_content" = "$txt_value" ]; then
    return 0
  else
    _debug "记录内容不一致：当前=$current_content，目标=$txt_value"
    return 1
  fi
}

# 检查同名不同内容的冲突记录
_dnshe_check_same_name_record() {
  _conflict_record_id=""
  local list_url="${DNSHE_Api}&endpoint=dns_records&action=list&subdomain_id=$_subdomain_id"
  local list_resp
  list_resp=$(_dnshe_rest GET "$list_url")

  local current_id=""
  local current_type=""
  local current_name=""
  
  local json_lines
  json_lines=$(echo "$list_resp" | tr '}' '\n' | tr ',' '\n' | tr '{' '\n')
  
  while IFS= read -r line; do
    if echo "$line" | grep -q '"id":'; then
      current_id=$(echo "$line" | sed 's/[^0-9]//g')
    fi
    if echo "$line" | grep -q '"type":"'; then
      current_type=$(echo "$line" | sed 's/.*"type":"//;s/".*//' | tr -d ' ')
    fi
    if echo "$line" | grep -q '"name":"'; then
      current_name=$(echo "$line" | sed 's/.*"name":"//;s/".*//' | tr -d ' ')
      
      # 匹配同名TXT记录（内容不同）
      if [ "$current_type" = "TXT" ] && [ "$current_name" = "$_full_txt_domain" ] && [ "$current_id" != "$_record_id" ] && [ -n "$current_id" ]; then
        _conflict_record_id="$current_id"
        break
      fi
    fi
  done <<< "$json_lines"

  _debug "检测到同名冲突记录ID: $_conflict_record_id"
}

# 删除指定ID的记录（核心适配：仅传record_id字段）
_dnshe_delete_specific_record() {
  local record_id="$1"
  local delete_url="${DNSHE_Api}&endpoint=dns_records&action=delete"
  # 严格匹配API格式：仅包含record_id字段
  local delete_data
  delete_data=$(printf '{"record_id": %d}' "$record_id")
  
  _debug "删除指定记录请求数据: $delete_data"
  local delete_resp
  delete_resp=$(_dnshe_rest POST "$delete_url" "$delete_data")

  if ! _dnshe_is_success "$delete_resp"; then
    local err
    err=$(_dnshe_extract_error "$delete_resp")
    _err "删除指定记录失败（ID: $record_id）: $err"
    return 1
  fi

  _info "指定记录删除成功（ID: $record_id）"
  return 0
}

# 创建TXT记录（核心修改：name字段仅传前缀）
_dnshe_create_txt_record() {
  local txt_value="$1"
  local create_url="${DNSHE_Api}&endpoint=dns_records&action=create"
  # 关键修复：name字段传入前缀（如 _acme-challenge），而非完整域名
  local create_data
  create_data=$(printf '{"subdomain_id": %d, "type": "TXT", "content": "%s", "name": "%s", "ttl": 600}' \
    "$_subdomain_id" "$txt_value" "$_txt_prefix")

  _debug "创建TXT记录请求数据: $create_data"
  local create_resp
  create_resp=$(_dnshe_rest POST "$create_url" "$create_data")

  if ! _dnshe_is_success "$create_resp"; then
    local err
    err=$(_dnshe_extract_error "$create_resp")
    _err "创建TXT记录失败: $err"
    return 1
  fi

  _info "TXT记录创建成功（前缀: $_txt_prefix，子域: $_target_subdomain）"
  return 0
}

# 更新TXT记录
_dnshe_update_txt_record() {
  local txt_value="$1"
  local update_url="${DNSHE_Api}&endpoint=dns_records&action=update"
  local update_data
  update_data=$(printf '{"record_id": %d, "content": "%s", "ttl": 600}' \
    "$_record_id" "$txt_value")

  _debug "更新TXT记录请求数据: $update_data"
  local update_resp
  update_resp=$(_dnshe_rest POST "$update_url" "$update_data")

  if ! _dnshe_is_success "$update_resp"; then
    local err
    err=$(_dnshe_extract_error "$update_resp")
    _err "更新TXT记录失败: $err"
    return 1
  fi

  _info "TXT记录更新成功"
  return 0
}

# 删除TXT记录（复用指定删除逻辑，确保格式一致）
_dnshe_delete_txt_record() {
  # 直接调用通用删除函数，确保参数格式统一
  _dnshe_delete_specific_record "$_record_id"
  return $?
}

# API请求封装
_dnshe_rest() {
  local method="$1"
  local url="$2"
  local data="$3"

  # 设置请求头
  export _H1="Content-Type: application/json"
  export _H2="X-API-Key: $DNSHE_API_KEY"
  export _H3="X-API-Secret: $DNSHE_API_SECRET"

  _debug "DNSHE API 请求: $method $url"
  _debug "请求数据: $data"

  local response
  local ret=0
  if [ "$method" = "POST" ]; then
    response="$(_post "$data" "$url" "" "POST")"
    ret=$?
  else
    response="$(_get "$url")"
    ret=$?
  fi

  # 网络层错误处理
  if [ $ret -ne 0 ]; then
    _err "API请求网络失败（状态码: $ret）"
    echo "$response"
    return $ret
  fi

  _debug2 "DNSHE API 响应: $response"
  echo "$response"
  return 0
}

# 检查响应是否成功
_dnshe_is_success() {
  local response="$1"
  echo "$response" | grep -q '"success":true'
  return $?
}

# 提取错误信息
_dnshe_extract_error() {
  local response="$1"
  local error
  error=$(echo "$response" | grep -o '"error":"[^"]\+"' | cut -d: -f2- | tr -d '"')
  if [ -z "$error" ]; then
    error=$(echo "$response" | cut -c 1-100)
  fi
  echo "$error"
}
