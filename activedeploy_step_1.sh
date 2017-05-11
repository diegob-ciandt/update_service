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

#set $DEBUG to 1 for set -x output
if [[ -n ${DEBUG} ]]; then
  set -x # trace steps
fi

SCRIPTDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

AD_STEP_1=true
source ${SCRIPTDIR}/check_and_set_env.sh

logDebug "TARGET_PLATFORM = $TARGET_PLATFORM"
logDebug "NAME = $NAME"
logDebug "AD_ENDPOINT = $AD_ENDPOINT"
logDebug "CONCURRENT_VERSIONS = $CONCURRENT_VERSIONS"
logDebug "PORT = $PORT"
logDebug "GROUP_SIZE = $GROUP_SIZE"
logDebug "RAMPUP_DURATION = $RAMPUP_DURATION"
logDebug "RAMPDOWN_DURATION = $RAMPDOWN_DURATION"
logDebug "RAMPDOWN_DURATION = $RAMPDOWN_DURATION"
logDebug "DEPLOYMENT_METHOD = $DEPLOYMENT_METHOD"
logDebug "ROUTE_HOSTNAME = $ROUTE_HOSTNAME"
logDebug "ROUTE_DOMAIN = $ROUTE_DOMAIN"
logDebug "AD_INSTANCE_NAME = $AD_INSTANCE_NAME"

# set ROUTE_DOMAINS, needed to create AD instance
RD_DALLAS="mybluemix.net"
RD_STAGE1="stage1.ng.mybluemix.net"
RD_LONDON="eu-gb.mybluemix.net"

# if AD_INSTANCE_NAME is not set, use as default "activedeploy-for-pipeline"
if [[ -z "$AD_INSTANCE_NAME" ]]; then
   AD_INSTANCE_NAME="activedeploy-for-pipeline"
fi

# check deployment method parameter and set create parms

function exit_with_link() {
  local __status="${1}"
  local __message="${2}"

  local __color=${green}
  if (( ${__status} )); then __color="${red}"; fi

  echo -e "${__color}${__message}${no_color}"

 if [[ ${ad_service_guid} && ${target_url} ]]; then
      # show full AD GUI, as GUI is supported and AD Instance exists
      full_GUI_URL="${target_url}/services/${ad_service_guid}?ace_config={%22spaceGuid%22:%22${CF_SPACE_ID}%22}"
      show_link "Deployment URL" ${full_GUI_URL} ${green}
  else
      logInfo "No Active Deploy GUI available on this environment."
      #show_link "Deployment URL" ${update_url} ${__color}
  fi

  exit ${__status}
}

function get_detailed_message() {
__ad_endpoint="${1}" __update_id="${2}" python - <<CODE
import ccs
import os
ad_server = os.getenv('__ad_endpoint')
update_id = os.getenv('__update_id')
ads =  ccs.ActiveDeployService(ad_server)
update, reason = ads.show(update_id)
message = update.get('detailedMessage', '') if update is not None else 'Unable to read update record'
print(message)
CODE
}

# Delete update record
function delete_update() {
  local __update="${1}"

  delete ${__update} && delete_rc=$? || delete_rc=$?
  if (( ${delete_rc} )); then
    logWarning "Unable to delete update record ${__update}"
  fi
}

# Delete older updates and update record
function cleanup() {
  local __update="${1}"

  clean && clean_rc=$? || clean_rc=$?
  if (( ${clean_rc} )); then
    logWarning "Unable to delete old versions"
  fi
  delete_update ${__update}
}

# Rollback update and cleanup
function rollback_and_cleanup() {
  local __update="${1}"

  rollback ${__update}
  cleanup
}

# cd to target so can read ccs.py when needed (for route detection)
cd ${SCRIPTDIR}

debugme echo "--- cat ${HOME}/.cf/config.json ---"
debugme cat ${HOME}/.cf/config.json

originals=($(groupList))
#originals=($(cf apps | cut -d' ' -f1))

logDebug "Originals: ${originals[@]}"

successor="${NAME}"

# export version of this build
export UPDATE_ID=${BUILD_NUMBER}

# Determine which original groups has the desired route --> the current original
route="${ROUTE_HOSTNAME}.${ROUTE_DOMAIN}"
ROUTED=($(getRouted "${route}" "${originals[@]}"))
logDebug ${#ROUTED[@]} of original groups routed to ${route}: ${ROUTED[@]}

# If more than one routed app, select only the oldest
if (( 1 < ${#ROUTED[@]} )); then
  logWarning "More than one app routed to ${route}; updating the oldest"
fi

if (( 0 < ${#ROUTED[@]} )); then
  readarray -t srtd < <(for e in "${ROUTED[@]}"; do echo "$e"; done | sort)
  original_grp=${srtd[0]}
  original_grp_id=${original_grp#*_}
  logDebug "Original_grp: $original_grp - Original_grp_id: $original_grp_id"
fi

# At this point if original_grp is not set, we didn't find any routed apps; ie, is initial deploy

# map/scale original deployment if necessary
if [[ 1 = ${#originals[@]} ]] || [[ -z $original_grp ]]; then
  logInfo "Initial version, scaling"
  scaleGroup ${successor} ${GROUP_SIZE} && rc=$? || rc=$?
  if (( ${rc} )); then
    logError "Failed to scale ${successor} to ${GROUP_SIZE} instances"
    exit ${rc}
  fi
  logInfo "Initial version, mapping route"
  # Alteração para incluir mais de uma rota por app, separada por vírgula
  # TODO
  mapRoute ${successor} ${ROUTE_DOMAIN} ${ROUTE_HOSTNAME} && rc=$? || rc=$?
  if (( ${rc} )); then
    logError "Failed to map the route ${ROUTE_DOMAIN}.${ROUTE_HOSTNAME} to ${successor}"
    exit ${rc}
  fi
  exit 0
else
  logInfo "Not initial version"
fi

# If a problem was found with $AD_ENDPOINT, fail now
if [[ -n ${MUSTFAIL_ACTIVEDEPLOY} ]]; then
  logError "Active deploy service unavailable; failing."
  # Cleanup - delete older updates
  clean && clean_rc=$? || clean_rc=$?
  if (( $clean_rc )); then
    logWarning "Unable to delete old versions."
  fi
  exit 128
fi

successor_grp=${NAME}

logDebug "Original group is ${original_grp} (${original_grp_id})"
logDebug "Successor group is ${successor_grp} (${UPDATE_ID})"

# Do update with active deploy if there is an original group
if [[ -n "${original_grp}" ]]; then

  # AD instance creation only on envs: Dallas Prod, Dallas stage and Lond Prod
  if [[ ${ROUTE_DOMAIN} == $RD_DALLAS ]] ||
     [[ ${ROUTE_DOMAIN} == $RD_STAGE1 ]] ||
     [[ ${ROUTE_DOMAIN} == $RD_LONDON ]] ; then

       logInfo "ROUTE_DOMAIN is: ${ROUTE_DOMAIN}"

       # check if there is an active deploy instance, if not create it
       logInfo "check if AD instance exists with cf services, if not create it."
       # run cf services to see for service=activedeploy
       cf services | grep "activedeploy" > mp.output
       foundservice=`cat mp.output`
       if [[ -z "$foundservice" ]]; then
         logInfo "No Active Deploy Instance found. Create it."
         cf create-service activedeploy free ${AD_INSTANCE_NAME}
       else
         logInfo "Found Active Deploy Instance: $AD_INSTANCE_NAME"
       fi
  fi

  logInfo "Beginning update with cf active-deploy-create ..."

  create_args="${original_grp} ${successor_grp} --manual --quiet --timeout 60s"

  if [[ -n "${RAMPUP_DURATION}" ]]; then create_args="${create_args} --rampup ${RAMPUP_DURATION}"; fi
  if [[ -n "${RAMPDOWN_DURATION}" ]]; then create_args="${create_args} --rampdown ${RAMPDOWN_DURATION}"; fi
  create_args="${create_args} --test 1s";

  create_args="${create_args} --algorithm ${DEPLOYMENT_METHOD_CREATE_ARG}"

  active=$(find_active_update ${original_grp})
  if [[ -n ${active} ]]; then
    logWarning "Original group ${original_grp} already engaged in an active update; rolling it back"
    rollback ${active}
    # Check if it worked
    active=$(find_active_update ${original_grp})
    if [[ -n ${active} ]]; then
      logError "Original group ${original_grp} still engaged in an active update; rollback did not work. Exiting."
      with_retry active_deploy show ${active}
      exit 1
    fi
  fi

  # Now attempt to call the update
  update=$(create ${create_args}) && create_rc=$? || create_rc=$?

  # Unable to create update
  if (( ${create_rc} )); then
    logError "Failed to create update; ${update}${no_color}"
    with_retry active_deploy list | grep "[[:space:]]${original_grp}[[:space:]]"
    exit ${create_rc}
  fi

  logInfo "Initiated update: ${update}"
  with_retry active_deploy show $update --timeout 60s

  # Identify URL for visualization of update. To do this:
  # The target_url is computed in check
  # get Active Deploy service GUID for AD GUI URL
  ad_service=`cf services | grep "activedeploy" | awk '{print $1}'`
  if [[ ${ad_service} ]]; then
     logInfo "AD service Instance exists. AD service name is: ${ad_service}"
     ad_service_guid=`cf service ${ad_service} --guid`
     logInfo "AD service GUID is: ${ad_service_guid}"
  else
    logInfo "Active Deploy service does not exist."
  fi

  # show AD GUI
  if [[ ${ad_service_guid} && ${target_url} ]]; then
    # show full AD GUI, as GUI is supported and AD Instance exists
    full_GUI_URL="${target_url}/services/${ad_service_guid}?ace_config={%22spaceGuid%22:%22${CF_SPACE_ID}%22}"
    show_link "Deployment URL" ${full_GUI_URL} ${green}
  else
    logInfo "No Active Deploy GUI available on this environment."
    #update_url="${update_gui_url}/deployments/${update}?ace_config={%22spaceGuid%22:%22${CF_SPACE_ID}%22}"
    #show_link "Deployment URL" "${update_url}" ${green}
  fi

  # Identify toolchain if available and send update details to it
  export PY_UPDATE_ID=$update

  # Wait for completion of rampup phase
  wait_phase_completion $update && rc=$? || rc=$?
  logInfo "Wait result is $rc"
  case "$rc" in
    0) # phase done
    # continue (advance to test)
    logInfo "Phase done, advance to test"
    advance $update && advance_rc=$? || advance_rc=$?
    if (( ${advance_rc} )); then
      case "${advance_rc}" in
        0) # phase done
        logInfo "Test phase complete"
        ;;
        1) # completed
        delete_update ${update}
        ;;
        2) # rolled back
        cleanup ${update}
        rollback_reason=$(get_detailed_message $ad_server_url $update)
        exit_message="${successor_grp} rolled back"
        if [[ -n "${rollback_reason}" ]]; then exit_message="${exit_message}.\nRollback caused by: ${rollback_reason}"; fi
        exit_with_link 2 "${exit_message}"
        ;;
        3) # failed
        exit_with_link 3 "Phase failed, manual intervension may be needed"
        ;;
        4) # paused
        exit_with_link 4 "ERROR: Resume failed, manual intervension may be needed"
        ;;
        5) # unknown
        rollback_and_cleanup ${update}
        exit_with_link 5 "ERROR: Unknown status or phase encountered"
        ;;
        9) # too long
        rollback_and_cleanup ${update}
        exit_with_link 9 "ERROR: Update took too long"
        ;;
        *)
        exit_with_link 1 "ERROR: Unknown problem occurred"
        ;;
      esac
      rollback_and_cleanup ${update}
      exit_with_link 6 "ERROR: advance to test phase failed."
    fi
    ;;

    1) # completed
    # cannot rollback; delete; return OK
    logError "Cannot rollback, phase completed. Deleting update record"
    delete_udpate $update
    ;;

    2) # rolled back
    # delete; return ERROR

    # stop rolled back app
    out=$(stopGroup ${successor_grp})
    logInfo "${successor_grp} stopped after rollback"

    cleanup ${update}

    rollback_reason=$(get_detailed_message $ad_server_url $update)
    exit_message="${successor_grp} rolled back"
    if [[ -n "${rollback_reason}" ]]; then exit_message="${exit_message}.\nRollback caused by: ${rollback_reason}"; fi
    exit_with_link 2 "${exit_message}"
    ;;

    3) # failed
    # FAIL; don't delete; return ERROR -- manual intervension may be needed
    exit_with_link 3 "Phase failed, manual intervension may be needed"
    ;;

    4) # paused; resume failed
    # FAIL; don't delete; return ERROR -- manual intervension may be needed
    exit_with_link 4 "ERROR: Resume failed, manual intervension may be needed"
    ;;

    5) # unknown status or phase
    #rollback; delete; return ERROR
    rollback_and_cleanup $update
    exit_with_link 5 "ERROR: Unknown status or phase encountered"
    ;;

    9) # takes too long
    #rollback; delete; return ERROR
    rollback_and_cleanup $update
    exit_with_link 9 "ERROR: Update took too long"
    ;;

    *)
    exit_with_link 1 "ERROR: Unknown problem occurred"
    ;;
  esac

  # Normal exist; show current update
  with_retry active_deploy show $update
  exit_with_link 0 "${successor_grp} successfully advanced to test phase"
fi
