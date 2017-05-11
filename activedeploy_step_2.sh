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
source ${SCRIPTDIR}/check_and_set_env.sh

logDebug "TARGET_PLATFORM = $TARGET_PLATFORM"
logDebug "NAME = $NAME"
logDebug "AD_ENDPOINT = $AD_ENDPOINT"
logDebug "CONCURRENT_VERSIONS = $CONCURRENT_VERSIONS"
logDebug "TEST_RESULT_FOR_AD = $TEST_RESULT_FOR_AD"

# cd to target so can read ccs.py when needed (for group deletion)
cd ${SCRIPTDIR}

# Initial deploy case
originals=($(groupList))

# Nothing to do in initial deploy scenario
if [[ 1 = ${#originals[@]} ]]; then
  logInfo "Initial version (single version deployed); exiting"
  exit 0
fi

# If a problem was found with $AD_ENDPOINT, fail now
if [[ -n ${MUSTFAIL_ACTIVEDEPLOY} ]]; then
  logError "Active deploy service unavailable; failing."
  exit 128
fi

# Identify the active deploy in progress. We do so by looking for a deploy
# involving the add / container named "${NAME}"
in_prog=$(with_retry active_deploy list | grep "${NAME}" | grep "in_progress")
read -a array <<< "$in_prog"
update_id=${array[1]}
if [[ -z "${update_id}" ]]; then
  logInfo "Initial version (no update containing ${NAME}); exiting"
  with_retry active_deploy list
  exit 0
fi

# Identify URL for visualization of update. To do this:
# The target_url is computed in check
# get Active Deploy service GUID for AD GUI URL
ad_service=`cf services | grep "activedeploy" | awk '{print $1}'`
logInfo "AD service name is: ${ad_service}"
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
    show_link "Deployments for space ${CF_SPACE_ID}" ${full_GUI_URL} ${green}
else
    logInfo "No Active Deploy GUI available on this environment."
    #show_link "Deployment URL" "${update_gui_url}/deployments/${update_id}?ace_config={%22spaceGuid%22:%22${CF_SPACE_ID}%22}" ${green}
fi

logInfo "Not initial version (part of update ${update_id})"
with_retry active_deploy show ${update_id}

IFS=$'\n' properties=($(with_retry active_deploy show ${update_id} | grep ':'))
update_status=$(get_property 'status' ${properties[@]})

# TODO handle other statuses better: could be rolled back, rolling back, paused, failed, ...
# Insufficient to leave it and let the wait_phase_completion deal with it; the call to advance/rollback could fail
if [[ "${update_status}" != 'in_progress' ]]; then
  logError "Deployment in unexpected status: ${update_status}"
  rollback ${update_id}
  delete ${update_id}
  exit 1
fi

# If TEST_RESULT_FOR_AD not set, assume the test succeeded. If the value wasn't set, then the user
# didn't modify the test job. However, we got to this job, so the test job must have
# completed successfully. Note that we are assuming that a test failure would terminate
# the pipeline.
if [[ -z ${TEST_RESULT_FOR_AD} ]]; then
  TEST_RESULT_FOR_AD=0;
fi

# Either rampdown and complete (on test success) or rollback (on test failure)
if [[ ${TEST_RESULT_FOR_AD} -eq 0 ]]; then
  echo "Test success -- completing update ${update_id}"
  # First advance to rampdown phase
  advance ${update_id}  && rc=$? || rc=$?
  # If failure doing advance, then rollback
  if (( $rc )); then
    logError "Advance to rampdown failed; rolling back update ${update_id}"
    rollback ${update_id} || true
    if (( $rollback_rc )); then
      logError "Unable to rollback update"
      logError $(wait_comment $rollback_rc)
    fi
  fi
  # Second advance to final phase
  advance ${update_id} && rc=$? || rc=$?
  if (( $rc )); then
    logError "Unable to advance to final phase"
  fi
else
  logInfo "TEST_RESULT_FOR_AD is: ${TEST_RESULT_FOR_AD}"
  logInfo "Test failure -- rolling back update ${update_id}"
  logInfo "After rollback, Active Deploy Complete job will exit with failure."
  rollback ${update_id} && rc=$? || rc=$?
  if (( $rc )); then
    logInfo "$(wait_comment $rc)"
  fi
  # rc will be the exit code; we want a failure code in pipeline if there was an AD rollback
  rc=2
fi

# Cleanup - delete older updates
clean && clean_rc=$? || clean_rc=$?
if (( $clean_rc )); then
  logWarning "Unable to delete old versions."
  logWarning $(wait_comment $clean_rc)
fi

# Cleanup - delete update record
logInfo "Deleting upate record"
delete ${update_id} && delete_rc=$? || delete_rc=$?
if (( $delete_rc )); then
  logWarning "Unable to delete update record ${update_id}"
fi

exit $rc
