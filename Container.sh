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

MIN_MAX_WAIT=300
BMX_URL_SUFFIX="${CF_TARGET_URL#*.}"
CCS_BASE_URL="https://containers-api.${BMX_URL_SUFFIX}/v3/containers"

# Return list of names of existing versions
# Usage: groupList
function groupList() {
PATTERN=$(echo $NAME | rev | cut -d_ -f2- | rev)
__baseUrl="$CCS_BASE_URL" __pattern="$PATTERN" python - <<CODE
import ccs
import os
import sys
import re
baseUrl = os.getenv('__baseUrl')
pattern = os.getenv('__pattern')
s = ccs.ContainerCloudService(base_url = baseUrl)
groups = s.list_groups(timeout=30)
#sys.stderr.write('groupList: {}\n'.format(groups))
names = [g.get('Name', '') for g in groups]
result=[]
for name in names:
   m=re.match(r"%s_\d*" % (pattern),name)
   if m:
      result.append(name)
print('{}'.format(' '.join(result)))
CODE
}


# Delete a group
# Usage groupDelete name
function groupDelete() {
__name="${1}" __baseUrl="$CCS_BASE_URL" python - <<CODE
import ccs
import os
import sys
baseUrl = os.getenv('__baseUrl')
s = ccs.ContainerCloudService(base_url = baseUrl)
name = os.getenv('__name')
deleted, group, reason = s.forced_delete_group(name, timeout=90)
if not deleted:
  sys.stderr.write('Delete failed: {}\n'.format(reason))
sys.exit(0 if deleted else 1)
CODE
}


# Map a route to a group
# Usage: mapRoute name domain host
function mapRoute() {
__name="${1}" __domain="${2}" __host="${3}" __baseUrl="$CCS_BASE_URL" python - <<CODE
import ccs
import os
import sys
baseUrl = os.getenv('__baseUrl')
s = ccs.ContainerCloudService(base_url = baseUrl)
name = os.getenv('__name')
domain = os.getenv('__domain')
hostname = os.getenv('__host')
mapped, group, reason = s.map(hostname, domain, name, timeout=90)
if not mapped:
  sys.stderr.write('Map of route to group failed: {}\n'.format(reason))
sys.exit(0 if mapped else 1)
CODE
}


# Change number of instances in a group
# Usage: scaleGroup name size
function scaleGroup() {
__name="${1}" __size="${2}" __baseUrl="$CCS_BASE_URL" python - <<CODE
import ccs
import os
import sys
baseUrl = os.getenv('__baseUrl')
s = ccs.ContainerCloudService(base_url = baseUrl)
name = os.getenv('__name')
size = os.getenv('__size')
scaled, group, reason = s.resize(name, size, timeout=90)
if not scaled:
  sys.stderr.write('Group resize failed: {}\n'.format(reason))
sys.exit(0 if scaled else 1)
CODE
}


# Get the routes mapped to a group
# Usage: getRoutes name
function getRoutes() {
__name="${1}" __baseUrl="$CCS_BASE_URL" python - <<CODE
import ccs
import os
import sys
baseUrl = os.getenv('__baseUrl')
s = ccs.ContainerCloudService(base_url = baseUrl)
name = os.getenv('__name')
group, reason = s.inspect_group(name, timeout=30)
if group is None:
  sys.stderr.write("Can't read group: {}\n".format(reason))
  sys.exit(1)
else:
  routes = group.get('Routes', [])
  print('{}'.format(' '.join(routes)))
CODE
}


# TODO: implement
# Stop a group
# Usage: stopGroup name
function stopGroup() {
  local __name="${1}"

  echo "Stopping group ${__name} (UNIMPLEMENTED)"
}


# TODO: implement
# Determine if a group is in the stopped state
# Ussage: isStopped name
function isStopped() {
  local __name="${1}"

  echo "false"
}
