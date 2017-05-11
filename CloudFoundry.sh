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

MIN_MAX_WAIT=90

# Return list of names of existing versions
# Usage: groupList
function groupList() {
  PATTERN=$(echo $NAME | rev | cut -d_ -f2- | rev)
  cf apps | grep "^${PATTERN}_[0-9]*[[:space:]]" | cut -d' ' -f1
  ## TODO error checking on result of cf apps call
}


# Delete a group
# Usage groupDelete name
function groupDelete() {
  cf delete ${1} -f
  ## TODO error checking on result of cf delete call
}


# Map a route to a group
# Usage: mapRoute name domain host
function mapRoute() {
  local __name="${1}"
  local __domain="${2}"
  local __host="${3}"

  cf map-route ${__name} ${__domain} -n ${__host} && rc=$? || rc=$?
  return ${rc}
}


# Change number of instances in a group
# Usage: scaleGroup name size
function scaleGroup() {
  local __name="${1}"
  local __size=${2}

  cf scale ${__name} -i ${__size} && rc=$? || rc=$?
  return ${rc}
}

# Get the routes mapped to a group
# Usage: getRoutes name
function getRoutes() {
  local __name="${1}"

  IFS=',' read -a routes <<< $(cf app ${__name} | grep "^urls: " | sed 's/urls: //' | sed 's/ //g')
  echo "${routes[@]}"
}


# Stop a group
# Usage: stopGroup name
function stopGroup() {
  local __name="${1}"

  echo "Stopping group ${__name}"
  cf stop "${__name}"
}

# Determine if a group is in the stopped state
# Ussage: isStopped name
function isStopped() {
  local __name="${1}"

  local __state=$(cf app "${__name}" | grep "requested state: " | sed -e 's/requested state: //')
  >&2 echo "${__name} is ${__state}"
  if [[ "stopped" == "${__state}" ]]; then
    echo "true"
  else
    echo "false"
  fi
}
