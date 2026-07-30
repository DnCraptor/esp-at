# copy from esp-idf/tools/ci/utils.sh

function add_ssh_keys() {
  local key_string="${1}"
  mkdir -p ~/.ssh
  chmod 700 ~/.ssh
  echo -n "${key_string}" >~/.ssh/id_rsa_base64
  base64 --decode --ignore-garbage ~/.ssh/id_rsa_base64 >~/.ssh/id_rsa
  chmod 600 ~/.ssh/id_rsa
}

function add_gitlab_ssh_keys() {
  add_ssh_keys "${GITLAB_KEY}"
  echo -e "Host gitlab.espressif.cn\n\tStrictHostKeyChecking no\n" >>~/.ssh/config

  # For gitlab geo nodes
  if [ "${LOCAL_GITLAB_SSH_SERVER:-}" ]; then
    SRV=${LOCAL_GITLAB_SSH_SERVER##*@} # remove the chars before @, which is the account
    SRV=${SRV%%:*}                     # remove the chars after :, which is the port
    printf "Host %s\n\tStrictHostKeyChecking no\n" "${SRV}" >>~/.ssh/config
  fi
}

function add_github_ssh_keys() {
  add_ssh_keys "${GH_PUSH_KEY}"
  echo -e "Host github.com\n\tStrictHostKeyChecking no\n" >>~/.ssh/config
}

function add_doc_server_ssh_keys() {
  local key_string="${1}"
  local server_url="${2}"
  local server_user="${3}"
  add_ssh_keys "${key_string}"
  echo -e "Host ${server_url}\n\tStrictHostKeyChecking no\n\tUser ${server_user}\n" >>~/.ssh/config
}

function get_module_configs() {
  module_name_lower=$(echo "${MODULE_NAME}" | tr '[:upper:]' '[:lower:]')
  module_cfg_dir="${CI_PROJECT_DIR}/module_config/module_${module_name_lower}"

  # module config directory
  if [ ! -d "${module_cfg_dir}" ]; then
      platform_name_str=$(echo "${PLATFORM}" | sed 's/PLATFORM_//')
      module_name_lower=$(echo "${platform_name_str}" | tr '[:upper:]' '[:lower:]')
      module_cfg_dir="${CI_PROJECT_DIR}/module_config/module_${module_name_lower}_default"
  else
      module_cfg_dir="${CI_PROJECT_DIR}/module_config/module_${module_name_lower}"
  fi
  echo "current configuration dir: ${module_cfg_dir}"

  # sdkconfig file
  if [ "$SILENCE" = "0" ]; then
      at_sdkconfig_file="${module_cfg_dir}/sdkconfig.defaults"
  elif [ "$SILENCE" = "1" ]; then
      at_sdkconfig_file="${module_cfg_dir}/sdkconfig_silence.defaults"
  else
      at_sdkconfig_file="na"
  fi
  echo "current sdkconfig file: ${at_sdkconfig_file}"
}

function enlarge_app_partition() {
  local app0_size app1_size to_set_size to_set_hex_size
  # Already enlarged, or partition table has no ota_1 (e.g. 2MB no-OTA modules).
  if ! grep -q 'ota_1' "${module_cfg_dir}/partitions_at.csv"; then
    echo "CI: skip enlarge_app_partition (no ota_1 in ${module_cfg_dir}/partitions_at.csv)"
    return 0
  fi
  app0_size=$(cat "${module_cfg_dir}/partitions_at.csv" | grep ota_0 | awk -F, '{print $5}')
  app1_size=$(cat "${module_cfg_dir}/partitions_at.csv" | grep ota_1 | awk -F, '{print $5}')
  to_set_size=$((app0_size + app1_size))
  sed -i '/ota_1/d' "${module_cfg_dir}/partitions_at.csv"
  to_set_hex_size=$(printf "0x%x" "${to_set_size}")
  sed -i '/ota_0/s,'"${app0_size}"','"${to_set_hex_size}"',g' "${module_cfg_dir}/partitions_at.csv"
}

function enable_mem_debug_if_config() {
  local level="${AT_CI_MEM_DEBUG_LEVEL:-0}"
  case "${level}" in
    0)
      return 0
      ;;
    1)
      echo "CI: AT_CI_MEM_DEBUG_LEVEL=1 (monitor)"
      echo -e "CONFIG_AT_MEM_DEBUG_MONITOR=y" >> "${at_sdkconfig_file}"
      ;;
    2)
      echo "CI: AT_CI_MEM_DEBUG_LEVEL=2 (monitor + heap light)"
      echo -e "CONFIG_AT_MEM_DEBUG_HEAP_LIGHT=y" >> "${at_sdkconfig_file}"
      echo -e "CONFIG_HEAP_POISONING_LIGHT=y" >> "${at_sdkconfig_file}"
      ;;
    3)
      echo "CI: AT_CI_MEM_DEBUG_LEVEL=3 (monitor + heap comprehensive)"
      echo -e "CONFIG_AT_MEM_DEBUG_HEAP_COMPREHENSIVE=y" >> "${at_sdkconfig_file}"
      echo -e "CONFIG_HEAP_POISONING_COMPREHENSIVE=y" >> "${at_sdkconfig_file}"
      ;;
    *)
      echo "ERROR: AT_CI_MEM_DEBUG_LEVEL must be 0..3, got '${level}'"
      return 1
      ;;
  esac
  enlarge_app_partition
}
