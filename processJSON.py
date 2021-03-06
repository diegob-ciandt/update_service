#!/usr/bin/python

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

import requests
import sys
import json
import time
import os

api_res = os.environ.get('TC_API_RES')

api_res_json = json.loads(api_res)

service_id = 0
ad_broker_url = 0
pipeline_name = 0

for i in range(len(api_res_json['items'][0]['services'])):
  if "activedeploy" in api_res_json['items'][0]['services'][i]['service_id']:
    service_id = api_res_json['items'][0]['services'][i]['instance_id']
    ad_broker_url = api_res_json['items'][0]['services'][i]['url']

if sys.argv[1] == 'sid':
  print service_id

if sys.argv[1] == "ad-url":
  print ad_broker_url

if len(sys.argv[1]) == 36:
  for i in range(len(api_res_json['items'][0]['services'])):
  	if sys.argv[1] in api_res_json['items'][0]['services'][i]['instance_id']:
  		print api_res_json['items'][0]['services'][i]['parameters']['name']
