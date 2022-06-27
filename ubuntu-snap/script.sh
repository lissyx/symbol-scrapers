#!/bin/sh

unalias -a

cpu_count=$(grep -c ^processor /proc/cpuinfo)

SNAP_NAME="firefox"

DOWNLOAD_DIR="$(pwd)/downloads"
SYMBOLS_DIR="$(pwd)/symbols"
SNAP_ROOT="$(pwd)/snap"
EXTRACTED_SNAPS="${SNAP_ROOT}/extracted-snaps.txt"
PROCESSED_SNAP="${SNAP_ROOT}/processed-snap"
ARTIFACTS_DIR="/builds/worker/artifacts/public/build"
SYMBOLS_API_URL="${SYMBOLS_API_URL:-https://symbols.mozilla.org/upload/}"

function ensure_env()
{
  if [ -z "${DUMP_SYMS}" ]; then
    printf "You must set the \`DUMP_SYMS\` enviornment variable before running the script\n"
    exit 1
  fi

  if [ -z "${SYMBOLS_API_TOKEN}" ]; then
    printf "You must set the \`SYMBOLS_API_TOKEN\` enviornment variable before running the script\n"
    exit 1
  fi

  if [ -z "${CRASHSTATS_API_TOKEN}" ]; then
    printf "You must set the \`CRASHSTATS_API_TOKEN\` enviornment variable before running the script\n"
    exit 1
  fi

  mkdir -p "${DOWNLOAD_DIR}/"
  mkdir -p "${SYMBOLS_DIR}/"
  mkdir -p "${SNAP_ROOT}/"
  mkdir -p "${ARTIFACTS_DIR}/"

  > "${EXTRACTED_SNAPS}"
  > "${PROCESSED_SNAP}"

  if test "$PROCESSED_PACKAGES_INDEX" && test "$PROCESSED_PACKAGES_PATH" && test "$TASKCLUSTER_ROOT_URL"; then
    PROCESSED_PACKAGES="$TASKCLUSTER_ROOT_URL/api/index/v1/task/$PROCESSED_PACKAGES_INDEX/artifacts/$PROCESSED_PACKAGES_PATH"
  fi

  echo "PROCESSED_PACKAGES=${PROCESSED_PACKAGES}"

  if test "$PROCESSED_PACKAGES"; then
    rm -f processed-packages
    if test `curl --output /dev/null --silent --head --location "$PROCESSED_PACKAGES" -w "%{http_code}"` = 200; then
      curl -L "$PROCESSED_PACKAGES" | gzip -dc > "${PROCESSED_SNAP}"
    elif test -f "$PROCESSED_PACKAGES"; then
      gzip -dc "$PROCESSED_PACKAGES" > "${PROCESSED_SNAP}"
    fi
  fi
}

function iterate_snap_revisions()
{
  local snap_name=$1

  for snap_metadata in $(curl --header "Snap-Device-Series: 16" "https://api.snapcraft.io/v2/snaps/info/${snap_name}" | jq -r -c ' ."channel-map" | .[]');
  do
    download_snap_revision "${snap_metadata}" _snap_file && \
      extract_debugsyms "${_snap_file}" "${SNAP_ROOT}"
  done;
}

function download_snap_revision()
{
  local snap_metadata=$1

  set +x
  snap_sha="$(echo "$snap_metadata" | jq '.download."sha3-384"' -r)"
  snap_url="$(echo "$snap_metadata" | jq '.download.url' -r)"

  snap_released="$(echo "$snap_metadata" | jq '.channel."released-at"' -r)"
  snap_arch="$(echo "$snap_metadata" | jq '.channel.architecture' -r)"
  snap_channel="$(echo "$snap_metadata" | jq '.channel.name' -r | tr '/' '_')"
  snap_track="$(echo "$snap_metadata" | jq '.channel.track' -r | tr '/' '_')"

  snap_revision="$(echo "$snap_metadata" | jq '.revision' -r)"
  snap_version="$(echo "$snap_metadata" | jq '.version' -r)"
  set -x

  local snap_already_processed=$(grep -qc "${snap_sha}" "${PROCESSED_SNAP}")
  if [ $? -eq 0 ]; then
    echo "Skipping ${snap_name} ${snap_version} (${snap_sha} found)"
    return 1
  fi

  local target_snap="${snap_name}_${snap_version}_${snap_revision}_${snap_arch}_${snap_track}-${snap_channel}.snap"
  local shasum_match=1

  if [ -f "${DOWNLOAD_DIR}/${target_snap}" ]; then
    shasum_output=$(sha3sum -a 384  -c <(echo -e "$snap_sha\u00a0*${DOWNLOAD_DIR}/$target_snap"))
    shasum_match=$?
  fi

  if [ "${shasum_match}" -ne "0" ]; then
    echo "Downloading ${snap_name}, (${snap_version} / ${snap_revision}) arch ${snap_arch} (released: ${snap_released})"
    curl --location "${snap_url}" --output "${DOWNLOAD_DIR}/$target_snap"
  fi

  eval "$2=${DOWNLOAD_DIR}/$target_snap"
  return 1
}

function local_snap()
{
  local_snap="$(basename "$1")"

  cp "$1" "${DOWNLOAD_DIR}/"

  extract_debugsyms "${DOWNLOAD_DIR}/${local_snap}" "${SNAP_ROOT}"
}

function extract_debugsyms()
{
  local snap_file=$1
  local snap_dir=$2
  local snap_name=$SNAP_NAME

  unsquashfs -d "$snap_dir/$snap_name" "$snap_file"

  local expected_symbols="$snap_dir/$snap_name/usr/lib/firefox/distribution/$snap_name-*.crashreporter-symbols.zip"
  local found_symbols=$(ls ${expected_symbols})

  local target_snap=$(basename "${snap_file}")
  local snap_sha=$(sha3sum -a 384 -b "${snap_file}" | sed -e $'s/\xC2\xA0/ /' | awk '{ print $1 }')
  local symbols_file=$(basename "${found_symbols}")

  if [ -f "${found_symbols}" ]; then
    cp "${found_symbols}" ${SYMBOLS_DIR}/
  else
    echo "Could not find symbols file for ${snap_file}"
    echo "${snap_sha} ${target_snap} ${symbols_file}" >> "${PROCESSED_SNAP}"
  fi

  echo "${snap_sha} ${target_snap} ${symbols_file}" >> "${EXTRACTED_SNAPS}"
  rm -fr "${snap_dir}/${snap_name}"
}

function upload_symbols()
{
  local symbols_dir=$1
  echo curl -s -o /dev/null -w "%{http_code}" -X POST -H "Auth-Token: ${SYMBOLS_API_TOKEN}" ${SYMBOLS_API_URL}
  pushd "${symbols_dir}"
    find . -name "*.zip" | while read myfile; do
      local fname=$(basename "${myfile}")
      local line=$(grep "${fname}" "${EXTRACTED_SNAPS}")
      echo "Uploading ${myfile} => ${line}"
      while : ; do
        res=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Auth-Token: ${SYMBOLS_API_TOKEN}" --form ${myfile}=@${myfile} ${SYMBOLS_API_URL})
        echo "${res}"
        if [ "${res}" -eq "201" ]; then
          echo "${line}" >> "${PROCESSED_SNAP}"
        fi
        break
      done
    done
  popd
}

function cleanup()
{
  rm "${EXTRACTED_SNAPS}"
}

ensure_env

# Passing a snap for debug purpose
if [ -f "$1" ]; then
  local_snap "$1"
else
  iterate_snap_revisions "${SNAP_NAME}"
fi

upload_symbols "${SYMBOLS_DIR}"

cleanup
