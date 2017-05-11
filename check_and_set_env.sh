#!/bin/bash

#********************************************************************************
#   (c) Copyright 2016 IBM Corp.
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#********************************************************************************

###################
################### Common to both step_1 and step_2
###################

export LANG=en_US  # Hard-coded because there is a defect w/ en_US.UTF-8

UNDEFINED="undefined"

# Pull in common methods
source ${SCRIPTDIR}/activedeploy_common.sh

logDebug "EXT_DIR=$EXT_DIR"
if [[ -f $EXT_DIR/common/cf ]]; then
  PATH=$EXT_DIR/common:$PATH
fi
logDebug "PATH=$(echo $PATH)"

if [[ -z "${NAME}" ]]; then
  logError "Environment variable NAME must be set to the name of the successor application or container group"
  exit 1
fi
if [[ "${NAME}" == "${UNDEFINED}" ]]; then
  logError "Environment variable NAME must be defined in the environment properties"
  exit 1
fi

# Identify TARGET_PLATFORM (CloudFoundry or Containers) and pull in specific implementations

PATTERN=$(echo $NAME | rev | cut -d_ -f2- | rev)

TARGET_PLATFORM_SOURCED=0
if [[ -z "${TARGET_PLATFORM}" ]]; then
  if cf apps | grep -q "^${NAME}"; then
    export TARGET_PLATFORM='CloudFoundry'
  else
    export TARGET_PLATFORM='Container'
    source "${SCRIPTDIR}/${TARGET_PLATFORM}.sh"
    TARGET_PLATFORM_SOURCED=1
    pushd  ${SCRIPTDIR} &>/dev/null
    ctrGroups=($(groupList))
    popd &>/dev/null
    if [[ ! " ${ctrGroups[@]} " =~ " ${NAME} " ]]; then
      logError "Neither CloudFoundry application nor Container group ${NAME} found in current org and space"
      exit 1
    fi
  fi
else
  TARGET_PLATFORM_ARGS=( CloudFoundry Container )
  if [[ " ${TARGET_PLATFORM_ARGS[@]} " =~ " ${TARGET_PLATFORM} " ]]; then
    export TARGET_PLATFORM
  else
    logError "Invalid target platform '${TARGET_PLATFORM}' detected. Vaild target platforms are 'CloudFoundry' or 'Container'"
    exit 1
  fi
fi
logDebug "Using target platform ${TARGET_PLATFORM}"
(( ! ${TARGET_PLATFORM_SOURCED} )) && source "${SCRIPTDIR}/${TARGET_PLATFORM}.sh"

# Verify that AD_ENDPOINT is available (otherwise set MUSTFAIL_ACTIVEDEPLOY)
# If it is available, further validate that $AD_ENDPOINT supports $CF_TARGET as a backend
if [[ -n "${AD_ENDPOINT}" ]]; then
  up=$(timeout 10 curl -s ${AD_ENDPOINT}/health_check/ | grep status | grep up)
  if [[ -z "${up}" ]]; then
    logError "Unable to validate availability of Active Deploy service ${AD_ENDPOINT}; failing active deploy"
    export MUSTFAIL_ACTIVEDEPLOY=true
  else
    supports_target "${AD_ENDPOINT}" "${CF_TARGET_URL}"
    if (( $? )); then
      logError "Selected Active Deploy service (${AD_ENDPOINT}) does not support target environment (${CF_TARGET_URL}); failing active deploy"
      export MUSTFAIL_ACTIVEDEPLOY=true
    fi
  fi
fi

# Set default (1) for CONCURRENT_VERSIONS
if [[ -z ${CONCURRENT_VERSIONS} ]]; then
  export CONCURRENT_VERSIONS=2;
else
  if ! isInteger "${CONCURRENT_VERSIONS}"; then
    logError "Invalid concurrent version '${CONCURRENT_VERSIONS}' detected"
    exit 1
  fi
fi

###################
################### Needed only for step_1
###################

if [[ -n $AD_STEP_1 ]]; then

  # Set default for GROUP_SIZE
  if [[ -z ${GROUP_SIZE} ]]; then
    export GROUP_SIZE=1
    logWarning "Group size not specified by environment variable GROUP_SIZE; using ${GROUP_SIZE}"
  else
    if ! isInteger "${GROUP_SIZE}"; then
      logError "Invalid groupsize '${GROUP_SIZE}' detected"
      exit 1
    fi
  fi

  # Set default for RAMPUP_DURATION
  if [[ -z ${RAMPUP_DURATION} ]]; then
    export RAMPUP_DURATION="5m"
    logWarning "Rampup duration not specified by environment variable RAMPUP_DURATION; using ${RAMPUP_DURATION}"
  else
    if ! isValidTime "${RAMPUP_DURATION}"; then
      logError "Invalid rampup duration '${RAMPUP_DURATION}' detected"
      exit 1
    fi
  fi

  # Set default for RAMPDOWN_DURATION
  if [[ -z ${RAMPDOWN_DURATION} ]]; then
    export RAMPDOWN_DURATION="5m"
    logWarning "Rampdown duration not specified by environment variable RAMPDOWN_DURATION; using ${RAMPDOWN_DURATION}"
  else
      if ! isValidTime "${RAMPDOWN_DURATION}"; then
        logError "Invalid rampdown duration '${RAMPDOWN_DURATION}' detected"
        exit 1
      fi
  fi

  # Set default for ROUTE_HOSTNAME
  if [[ -z ${ROUTE_HOSTNAME} ]]; then
    export ROUTE_HOSTNAME=$(echo $NAME | rev | cut -d_ -f2- | rev | sed -e 's#_#-##g')
    logWarning "Route hostname not specified by environment variable ROUTE_HOSTNAME; using '${ROUTE_HOSTNAME}'"
  fi

  # Set default for ROUTE_DOMAIN
  defaulted_domain=0
  # Strategy #1: Use the domain for the app with the same ROUTE_HOSTNAME as we are using
  if [[ -z ${ROUTE_DOMAIN} ]]; then
    export ROUTE_DOMAIN=$(cf routes | awk -v hostname="${ROUTE_HOSTNAME}" '$2 == hostname {print $3}')
    defaulted_domain=1
  fi
  # Strategy #2: Use most commonly used domain
  if [[ -z ${ROUTE_DOMAIN} ]]; then
    export ROUTE_DOMAIN=$(cf routes | tail -n +2 | grep -E '[a-z0-9]\.' | awk '{print $3}' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
    defaulted_domain=1
  fi
  # Strategy #3: Use a domain available to the user
  if [[ -z ${ROUTE_DOMAIN} ]]; then
    export ROUTE_DOMAIN=$(cf domains | grep -e 'shared' -e 'owned' | head -1 | awk '{print $1}')
    defaulted_domain=1
  fi
  if [[ -z ${ROUTE_DOMAIN} ]]; then
    logError "Route domain not specified by environment variable ROUTE_DOMAIN and no suitable alternative could be identified"
    exit 1
  fi

  if (( ${defaulted_domain} )); then
    logInfo "Route domain not specified by environment variable ROUTE_DOMAIN; using '${ROUTE_DOMAIN}'"
  fi

  if [[ -z "${DEPLOYMENT_METHOD}" ]]; then
    DEPLOYMENT_METHOD="Red Black"
    logWarning "Deployment method not specified by environment variable DEPLOYMENT_METHOD; using '${DEPLOYMENT_METHOD}'"
  fi

  declare -A DEPLOYMENT_METHOD_ARG
  DEPLOYMENT_METHOD_ARG=( [Red Black]=rb [Resource Optimized]=rorb )
  if [ ${DEPLOYMENT_METHOD_ARG[${DEPLOYMENT_METHOD}]+_} ]; then
    DEPLOYMENT_METHOD_CREATE_ARG="${DEPLOYMENT_METHOD_ARG[${DEPLOYMENT_METHOD}]}"
    logDebug "Found deployment method \"${DEPLOYMENT_METHOD}\" - DEPLOYMENT_METHOD_CREATE_ARG: \"${DEPLOYMENT_METHOD_CREATE_ARG}\""
  else
    logError "Invalid deployment method '${DEPLOYMENT_METHOD}' detected"
    exit 1
  fi

fi # if [[ -n ${AD_STEP_1} ]]; then

# debug info
if [[ -n ${DEBUG} ]]; then
  which cf
  cf --version
  active_deploy service-info
fi

function show_link() {
  local __label="${1}"
  local __link="${2}"
  local __color="${no_color}"
  if (( $# > 2 )); then __color="${3}"; fi

  echo -e "${__color}**********************************************************************"
  echo "${__label}"
  echo "${__link}"
  echo -e "**********************************************************************${no_color}"
}


# Identify URL for visualization of updates associated with this space. To do this:
#   (a) look up the active deploy api server (cf. service endpoint field of cf active-deplpy-service-info)
#   (b) look up the GUI server associated with the active deploy api server (cf. update_gui_url field of response to info REST call
#   (c) Construct URL
ad_server_url=$(active_deploy service-info | grep "service endpoint: " | sed 's/service endpoint: //')
update_gui_url=$(curl -s ${ad_server_url}/v1/info/ | grep update_gui_url | awk '{print $2}' | sed 's/"//g' | sed 's/,//')

logInfo "Update gui url is: ${update_gui_url}"

# determine and set target_url for AD full GUI
case "${update_gui_url}" in
  https://activedeploy.ng.bluemix.net) # DALLAS Prod
  target_url="https://new-console.ng.bluemix.net"
  ;;
  https://activedeploy.stage1.ng.bluemix.net) # STAGE1
  target_url="https://dev-console.stage1.ng.bluemix.net"
  ;;
  https://activedeploy.eu-gb.bluemix.net) # LONDON Prod
  target_url="https://new-console.eu-gb.bluemix.net"
  ;;
  *) # In case of AD full UI not available
  logInfo "No Active Deploy GUI available on this environment."
  # show_link "check script: Deployments for space ${CF_SPACE_ID}" "${update_gui_url}/deployments?ace_config={%22spaceGuid%22:%22${CF_SPACE_ID}%22}" ${green}
  ;;
esac
