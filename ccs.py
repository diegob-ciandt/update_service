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

import json
import logging
import os
import requests
import sys
import time

__author__ = 'Michael Kalantar'


def sanitize_headers(h):
    ''' Remove sensitive information from headers.

    Parameters
        @param h dict: dictionary of header -> value
    Returns
        @rtype dict: sanitized headers
    '''
    if 'Authorization' not in h and 'X-Auth-Token' not in h:
        return h
    hc = h.copy()
    if 'Authorization' in hc:
        hc['Authorization'] = '[PRIVATE DATA HIDDEN]'
    if 'X-Auth-Token' in hc:
        hc['X-Auth-Token'] = '[PRIVATE DATA HIDDEN]'
    return hc

def sanitize_message(message):
    ''' Remove sensitive information (such as a bearer token) from the message.

    Parameters
        @param message str: the message to sanitize
    Returns
        @rtype string: the sanitized messagte
    '''
    if message.startswith('Invalid token format. Please generate new token'):
        message = 'Invalid token format. Please generate new token'
    return message


class CloudFoundaryService:

    def __init__(self, base_url = 'https://api.ng.bluemix.net'):
        self._config = json.loads(open(os.path.join(os.getenv('HOME', '~'), '.cf', 'config.json')).read())

    def space_guid(self):
        if 'Guid' in self._config['SpaceFields']:
            return self._config['SpaceFields']['Guid']
        else:
            return self._config['SpaceFields']['GUID']

    def auth_token(self):
        return self._config['AccessToken']



class ActiveDeployService:

    def __init__(self, base_url = 'https://activedeployapi.ng.bluemix.net', cf = None, ccs = None):
        self._ccs = ccs if ccs else ContainerCloudService()
        self._cf = cf if cf else self._ccs._cfapi
        self._base_url = '{}/v1'.format(base_url)

    #
    # Methods to do basic (REST) operations on container service. These methods log the request and response (in case of error)
    #
    def _get(self, url, timeout=10):
        ''' Wrapper for GET call to CCS.

        Parameters
            @param url string: relative URL of resource to query
            @param timeout int: number of seconds to wait for call to return
        Returns
            @rtype requests.Response
        '''
        url = '{base_url}/{resource}'.format(base_url=self._base_url, resource=url)
        headers = {
            'Authorization': self.__token(),
            'Accept': 'application/json'
        }
        logging.getLogger(__name__).debug("[{timeout}] curl {headers} -X GET '{url}'".format(headers=' '.join(["-H '{0}: {1}'".format(key, value) for key, value in sanitize_headers(headers).iteritems()]),
                                                                          url=url,
                                                                          timeout=timeout))
        retval = requests.get(url, headers=headers, timeout=timeout)
        if retval.status_code == 400 or retval.status_code >= 500:
            logging.getLogger(__name__).debug("curl {headers} '{url}' returned {code}: {response_headers} {text}".format(headers=' '.join(["-H '{0}: {1}'".format(key, value) for key, value in sanitize_headers(headers).iteritems()]),
                                                                                                       url=url,
                                                                                                       response_headers=retval.headers,
                                                                                                       code=retval.status_code,
                                                                                                       text=sanitize_message(retval.text)))
        return retval

    def _delete(self, url, timeout=10):
        url = '{base_url}/{resource}'.format(base_url=self._base_url, resource=url)
        headers = {
            'Authorization': self.__token(),
            'Accept': 'application/json'
        }
        logging.getLogger(__name__).debug("[{timeout}] curl {headers} -X DELETE '{url}'".format(timeout=timeout,
                                                                                                url=url,
                                                                                                headers=' '.join(["-H '{0}: {1}'".format(key, value) for key, value in sanitize_headers(headers).iteritems()])))
        retval = requests.delete(url, headers=headers, timeout=timeout)
        if retval.status_code == 400 or retval.status_code >= 500:
            logging.getLogger(__name__).debug("curl {headers} '{url}' returned {code}: {response_headers} {text}".format(
                                                headers=' '.join(["-H '{0}: {1}'".format(key, value) for key, value in sanitize_headers(headers).iteritems()]),
                                                url=url,
                                                response_headers=retval.headers,
                                                code=retval.status_code,
                                                text=sanitize_message(retval.text)))
        return retval

    def _with_retries(self, rest, *args, **kwargs):
        ''' Execute a
        Parameters
            @param rest function: REST function to be applied
        Options (kwargs may contain)
            max_attempts - maximum number of attempts to try REST call; defaults to 3
            exit_statuses - list of valid exit statuses on which to terminate; defaults to [200, 201]
        Returns
            tuple: boolean, requests.Response
        '''
        # Set defaults; extract optional config values from kwargs
        max_attempts=3
        if 'max_attempts' in kwargs:
            max_attempts = kwargs.get('max_attempts')
            del kwargs['max_attempts']
        exit_statuses = [200, 201]
        if 'exit_statuses' in kwargs:
            exit_statuses = kwargs.get('exit_statuses')
            del kwargs['exit_statuses']

        # Try up to max_attempts times to successfully call rest()
        # Retry in all failure cases:
        #   (a) unacceptable status (not in exit_statuses)
        #   (b) timeout waiting for response
        #   (c) any other exception (in which case the exception is logged)
        attempts = 0
        while (attempts < max_attempts):
            try:
                r = rest(*args, **kwargs)
                if r.status_code in exit_statuses:
                    return True, r
            except requests.exceptions.Timeout:
                logging.getLogger(__name__).debug('Timeout exception executing {}'.format(rest.__name__))
            except:
                logging.getLogger(__name__).debug('Exception occurred executing {}'.format(rest.__name__), exc_info=True)
            attempts += 1
            time.sleep(5)

        return False, None

    def _delete_update(self, name, **options):
        return self._delete('{space}/update/{name}/?force=true'.format(space=self._cf.space_guid(), name=name), **options)

    def delete_update(self, name):
        # Request deletion of group
        logging.getLogger(__name__).debug('delete_update called')
        success, r = self._with_retries(self._delete_update, name=name, exit_statuses = [200, 201, 404], timeout=120)
        if not success:
            return False, 'Unable to initiate delete update request'

        if 404 == r.status_code:
            logging.getLogger(__name__).debug("Update '{name}' does not exist; exiting".format(name=name))
            return True, ""

    def _show(self, name, **options):
        return self._get('{space}/update/{name}/'.format(space=self._cf.space_guid(), name=name), **options)

    def show(self, name):
        success, r = self._with_retries(self._show, name=name, exit_statuses = [200, 403, 404], timeout=30)
        if not success:
            return None, 'Unable to read request'

        if 403 == r.status_code:
            return None, 'Unauthorized'

        if 404 == r.status_code:
            return None, 'No such update'

        try:
            return json.loads(r.text), ""
        except:
            return None, "Invalid JSON response: {}".format(r.text)

    def __token(self):
        t = self._cf.auth_token()
        return 'bearer {}' if not t.lower().startswith('bearer ') else t



class ContainerCloudService:

    def __init__(self, cfapi = None, base_url = 'https://containers-api.ng.bluemix.net/v3/containers'):
        ''' Class initializer

        Parameters
            @param cfapi CloudFoundaryService: object providing access to CF REST API
            @param base_url string: URL of container service; should be in same Bluemix environment as cfapi
        '''
        self._cfapi = cfapi if cfapi else CloudFoundaryService()
        self._base_url = base_url

        logger = logging.getLogger()
        logger.setLevel(logging.DEBUG)
        formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')

        handler1 = logging.StreamHandler(sys.stderr)
        handler1.setLevel(logging.DEBUG)
        handler1.setFormatter(formatter)
        logger.addHandler(handler1)



    #
    # Methods to do basic (REST) operations on container service. These methods log the request and response (in case of error)
    #
    def get(self, url, timeout=10):
        ''' Wrapper for GET call to CCS.

        Parameters
            @param url string: relative URL of resource to query
            @param timeout int: number of seconds to wait for call to return
        Returns
            @rtype requests.Response
        '''
        url = '{base_url}/{resource}'.format(base_url=self._base_url, resource=url)
        headers = {
            'Accept': 'application/json;charset=utf-8',
            'X-Auth-Token': self.__token(),
            'X-Auth-Project-Id': self._cfapi.space_guid()
        }
        logging.getLogger(__name__).debug("[{timeout}] curl {headers} -X GET '{url}'".format(headers=' '.join(["-H '{0}: {1}'".format(key, value) for key, value in sanitize_headers(headers).iteritems()]),
                                                                          url=url,
                                                                          timeout=timeout))
        retval = requests.get(url, headers=headers, timeout=timeout)
        if retval.status_code == 400 or retval.status_code >= 500:
            logging.getLogger(__name__).debug("curl {headers} '{url}' returned {code}: {response_headers} {text}".format(headers=' '.join(["-H '{0}: {1}'".format(key, value) for key, value in sanitize_headers(headers).iteritems()]),
                                                                                                       url=url,
                                                                                                       response_headers=retval.headers,
                                                                                                       code=retval.status_code,
                                                                                                       text=sanitize_message(retval.text)))
        return retval


    def post(self, url, body, timeout=10):
        ''' Wrapper for POST call to CCS.

        Parameters
            @param url string: relative URL of resource to create
            @param body string: body to POST - serialized JSON
            @param timeout int: number of seconds to wait for call to return
        Returns
            @rtype requests.Response
        '''
        url = '{base_url}/{resource}'.format(base_url=self._base_url, resource=url)
        headers = {
            'Accept': 'application/json;charset=utf-8',
            'content-type': 'application/json',
            'X-Auth-Token': self.__token(),
            'X-Auth-Project-Id': self._cfapi.space_guid()
        }
        body_arg = " --data \'{0}\'".format(body.replace('\'', '\\\'')) if body else ''
        logging.getLogger(__name__).debug("[{timeout}] curl {headers} -X POST '{url}' {body}".format(headers=' '.join(["-H '{0}: {1}'".format(key, value) for key, value in sanitize_headers(headers).iteritems()]),
                                                                                     url=url,
                                                                                     body=body_arg,
                                                                                     timeout=timeout))
        retval = requests.post(url, body, headers=headers, timeout=timeout)
        if retval.status_code == 400 or retval.status_code >= 500:
            logging.getLogger(__name__).debug("curl {headers} '{url}' returned {code}: {response_headers} {text}".format(headers=' '.join(["-H '{0}: {1}'".format(key, value) for key, value in sanitize_headers(headers).iteritems()]),
                                                                                                       url=url,
                                                                                                       response_headers=retval.headers,
                                                                                                       code=retval.status_code,
                                                                                                       text=sanitize_message(retval.text)))
        return retval


    def patch(self, url, body, timeout=10):
        ''' Wrapper for PATCH call to CCS.

        Parameters
            @param url string: relative URL of resource to update
            @param body string: body to send - serialized JSON
            @param timeout int: number of seconds to wait for call to return
        Returns
            @rtype requests.Response
        '''
        url = '{base_url}/{resource}'.format(base_url=self._base_url, resource=url)
        headers = {
            'Accept': 'application/json;charset=utf-8',
            'content-type': 'application/json',
            'X-Auth-Token': self.__token(),
            'X-Auth-Project-Id': self._cfapi.space_guid()
        }
        body_arg = " --data \'{0}\'".format(body.replace('\'', '\\\'')) if body else ''
        logging.getLogger(__name__).debug("[{timeout}] curl {headers} -X PATCH '{url}' {body}".format(headers=' '.join(["-H '{0}: {1}'".format(key, value) for key, value in sanitize_headers(headers).iteritems()]),
                                                                                      url=url,
                                                                                      body=body_arg,
                                                                                      timeout=timeout))
        retval = requests.patch(url, body, headers=headers, timeout=timeout)
        return retval


    def delete(self, url, timeout=10):
        ''' Wrapper for DELETE call to CCS.

        Parameters
            @param url string: relative URL of resource to update
            @param timeout int: number of seconds to wait for call to return
        Returns
            @rtype requests.Response
        '''
        url = '{base_url}/{resource}'.format(base_url=self._base_url, resource=url)
        headers = {
            'X-Auth-Token': self.__token(),
            'X-Auth-Project-Id': self._cfapi.space_guid()
        }
        logging.getLogger(__name__).debug("[{timeout}] curl {headers} -X DELETE '{url}'".format(timeout=timeout,
                                                                                                url=url,
                                                                                                headers=' '.join(["-H '{0}: {1}'".format(key, value) for key, value in sanitize_headers(headers).iteritems()])))
        retval = requests.delete(url, headers=headers, timeout=timeout)
        return retval

    def __token(self):
        ''' Method to retrieve ensure that the passed in the X-Auth-Token header field is in the correct format.
        That is, removes "bearer " from the start of the token if present.

        Returns
            @rtype string: the Bluemix token without the string "bearer " at the front
        '''
        t = self._cfapi.auth_token()
        return t[7:] if t.lower().startswith('bearer ') else t

    #
    # Methods that do basic ccs actions
    #
    def _list_groups(self, **options):
        ''' Retrieve list of container groups.

        Returns
            @rtype requests.Response in which r.text is list of groups formatted as serialized JSON
        '''
        r = self.get('groups', **options)
        return r

    def _create_group(self, name, image, desired=2, max=4, min=0, memory=64, env={}, port=None, **options):
        ''' Create a container group.

        Parameters
            @param name string: name of group to create
            @param image string: name of image to be used to create the group
            @param desired int: desired size of group, must be between min and max (inclusive)
            @param max int: max size of group
            @param min int: min size of group
            @param memory int: memory footprint of an instance in group
            @param env dict: environment varibles to set for each instance
            @param port int: port to which traffic should be routed
        Returns
            @rtype requests.Response: result of create operation
        '''
        body = {'Name': name,
                'Autorecovery': 'false',
                'Cmd': [],
                'WorkingDir': '',
                'NumberInstances': {'Desired': desired, 'Max': max, 'Min': min},
                'Volumes': [],
                'Memory': memory,
                'Image': image,
                'Env': ["{}={}".format(key,value) for key, value in env.iteritems()]
                }
        if port:
            body['Port'] = port
        r = self.post('groups', json.dumps(body), **options)
        return r

    def _resize_group(self, name, desired, **options):
        ''' Resize a container group

        Parameters
            @param name string: name of group
            @param desired int: (new) desired size of group
        Returns
            @rtype requests.Response: result of request to resize group
        '''
        body = {'NumberInstances': {'Desired': desired}}
        r = self.patch('groups/{name}'.format(name=name), json.dumps(body), **options)
        return r

    def _delete_group(self, name, **options):
        ''' Delete a container group

        Parameters
            @param name int: name of group to delete
        Returns
            @rtype requests.Response: result of request to delete group
        '''
        r = self.delete('groups/{name}?force=true'.format(name=name), **options)
        return r

    def _inspect_group(self, name, **options):
        ''' Inspect a container group

        Parameters
            @param name string: name of group
        Returns
            @rtype requests.Response: result of requet to query group
        '''
        r = self.get('groups/{name}'.format(name=name), **options)
        return r

    def _map(self, hostname, domain, name, **options):
        ''' Map a route to a container group

        Parameters
            @param hostname string: hostname of route to map
            @param domain string: domain of route to map
            @param name string: name of group to map
        Returns
            @rtype requests.Response: reuslt of request to map group
        '''
        r = self.post('groups/{name}/maproute'.format(name=name),
                      json.dumps({'domain': domain, 'host':hostname}), **options)
        return r

    def _unmap(self, hostname, domain, name, **options):
        ''' Unmap a route from a container group

        Parameters
            @param hostname string: hostname of route to unmap
            @param domain string: domain of route to unmap
            @param name string: name of group to unmap
        Returns
            @rtype requests.Response: reuslt of request to unmap group
        '''
        r = self.post('groups/{name}/unmaproute'.format(name=name),
                      json.dumps({'domain': domain, 'host':hostname}), **options)
        return r


    #
    # Utility methods that repeat actions and wait for successes
    #
    def _with_retries(self, rest, *args, **kwargs):
        ''' Execute a REST call multiple times or until the call is successful (response code is acceptable).
        Sleeps between attempts.
        Doubles timeout if failure due to timeout exception.

        Parameters
            @param rest function: REST function to be applied
        Options (kwargs may contain)
            max_attempts - maximum number of attempts to try REST call; defaults to 3
            exit_statuses - list of valid exit statuses on which to terminate; defaults to [200, 201]
            timeout - length of timeout for REST request
        Returns
            @rtype (boolean, requests.Response): (final success, response to REST call)
        '''
        # Set defaults; extract optional config values from kwargs
        max_attempts=3
        if 'max_attempts' in kwargs:
            max_attempts = kwargs.get('max_attempts')
            del kwargs['max_attempts']
        exit_statuses = [200, 201]
        if 'exit_statuses' in kwargs:
            exit_statuses = kwargs.get('exit_statuses')
            del kwargs['exit_statuses']
        timeout = 10
        if 'timeout' in kwargs:
            timeout = kwargs.get('timeout')
            del kwargs['timeout']

        # Try up to max_attempts times to successfully call rest()
        # Retry in all failure cases:
        #   (a) unacceptable status (not in exit_statuses)
        #   (b) timeout waiting for response
        #   (c) any other exception (in which case the exception is logged)
        attempts = 0
        while (attempts < max_attempts):
            try:
                kwargs['timeout'] = timeout
                r = rest(*args, **kwargs)
                if r.status_code in exit_statuses:
                    return True, r
            except requests.exceptions.Timeout:
                logging.getLogger(__name__).debug('Timeout exception executing {}'.format(rest.__name__))
            except:
                logging.getLogger(__name__).debug('Exception occurred executing {}'.format(rest.__name__), exc_info=True)
            attempts += 1
            timeout = 2 * timeout
            time.sleep(5)

        logging.getLogger(__name__).debug('Too many tries, returning')
        return False, None

    def _wait_for(self, name, activity, evaluate, *args, **kwargs):
        ''' Repeatedly call a method to evaluate status of a group until some condition holds.

        Parameters
          @param name string - name of group whose status is to be evaluated
          @param activity string - label for activity being executed
          @param evaluate - method that should be used to evaluate group status
            Consumes:
              group - group
              reason - explanation of (lack of) group
            Returns a tuple (string, string) defined as:
              action string - one of 'COMPLETE_SUCCESS', 'COMPLATE_FAIL' or 'CONTINUE'
              reason string - explanation of action

        Returns
            @rtype (boolean, JSON group, string) where the elements have the following interpretation:
          boolean - indicating eventual success or failure of activity
          group - group in its final state
          reason - explanation (typically of negative results)
        '''
        max_wait=900
        if 'max_wait' in kwargs:
            max_wait = kwargs.get('max_wait')
            del kwargs['max_wait']

        logging.getLogger(__name__).debug("Waiting for group '{name}' {activity}".format(name=name, activity=activity))
        start_time = time.time()
        elapsed_time = 0
        while elapsed_time < max_wait:
            try:
                # get state of group (use wrapper that calls multiple times if needed)
                group, reason = self.inspect_group(name, timeout=30)
                # evaluate status (should take into account possibility that no group was returned)
                logging.getLogger(__name__).debug('_wait_for discovered group {}'.format(group))
                action, action_reason = evaluate(group, reason, *args, **kwargs)
                if action == 'COMPLETE_SUCCESS':
                    logging.getLogger(__name__).info("Group '{name}' {activity} completed successfully in {time}".format(name=name, activity=activity, time=elapsed_time))
                    return True, group, ""
                elif action == 'COMPLETE_FAIL':
                    logging.getLogger(__name__).info("Group '{name}' {activity} failed in {time} ({reason})".format(name=name, activity=activity, time=elapsed_time, reason=action_reason))
                    logging.getLogger(__name__).debug("Group: {group}".format(group=group))
                    return False, group, action_reason
                else: # action == CONTINUE
                    pass

            except:
                logging.getLogger(__name__).debug('Exception', exc_info=True)
            logging.getLogger(__name__).debug("Waiting for group '{name}' {activity}: sleeping 5s".format(name=name, activity=activity))
            time.sleep(5)
            elapsed_time = time.time() - start_time

        too_long_msg = "Group '{name}' {activity} took too long ( > {time_allowed} s)".format(name=name, activity=activity, time_allowed=max_wait)
        logging.getLogger(__name__).debug(too_long_msg)
        logging.getLogger(__name__).debug("Current group: {group}".format(group=group))
        return False, group, too_long_msg


    #
    # Wrappers to CCS REST calls that retry on failure and wait until the requested operation completes.
    # Many CCS calls are asyncrhonous; this provides a synchronous interface.
    #
    def inspect_group(self, name, *args, **kwargs):
        ''' Inspect a container group with retries.

        Parameters
            @param name string: name of group
        Returns
            @rtype (JSON group, explanation string) where the elements have the following interpretation:
                JSON representation of group
                explanation (when fails)
        '''
        logging.getLogger(__name__).debug('inspect_group called')
        success, r = self._with_retries(self._inspect_group, name, max_attempts = 5, exit_statuses = [200, 201, 404], *args, **kwargs)
        if not success:
            return None, "Unable to inspect group '{name}'".format(name=name)

        if 404 == r.status_code:
            return None, "No such group as '{name}'".format(name=name)

        try:
            return json.loads(r.text), ""
        except:
            return None, "Invalid JSON response: {}".format(r.text)


    def _deleted(self, group, reason):
        ''' Evaluation method for delete_group() call to _wait_for() '''

        if not group:
            if 'No such group as' in reason:
                return 'COMPLETE_SUCCESS', ""
            else:
                return 'CONTINUE', ""

        status = group.get('Status')

        if not status:
            return 'CONTINUE', ""

        if status.endswith('_COMPLETE'):
            return 'COMPLETE_SUCCESS', ""

        if status.endswith('IN_PROGRESS'):
            return 'CONTINUE', ""

        # status.endswith('_FAILED')
        logging.getLogger(__name__).debug("_deleted _FAILED")
        return 'COMPLETE_FAIL', "delete failed"

    def delete_group(self, name, *args, **kwargs):
        ''' Delete a container group with retries.
        Waits until container group is successfully deleted or the deletion fails.

        Parameters
            @param name string: name of group
        Returns
            @rtype (boolean, JSON group, explanation string) where the elements have the following interpretation:
                indicator of success
                JSON group
                explanation (when fails)
        '''
        logging.getLogger(__name__).debug('delete_group called')
        success, r = self._with_retries(self._delete_group, name=name, exit_statuses = [200, 201, 204, 404], *args, **kwargs)
        if not success:
            return False, None, 'Unable to initiate delete request'

        if 404 == r.status_code:
            logging.getLogger(__name__).debug("Group '{name}' does not exist; exiting".format(name=name))
            return True, None, ''

        return self._wait_for(name, 'deletion', self._deleted)


    def forced_delete_group(self, name, *args, **kwargs):
        ''' Delete a container group with retries.
        Retries when previous attempts to delete (via delete_group() fail.

        Parameters
            @param name string: name of group
        Returns
            @rtype (boolean, JSON group, explanation string) where the elements have the following interpretation:
                indicator of success
                JSON group
                explanation (when fails)
        '''
        max_attempts = 3

        attempts = 0
        while (attempts < max_attempts):
            try:
                success, group, reason = self.delete_group(name, *args, **kwargs)
                if success:
                    return True, None, ""
            except:
                logging.getLogger(__name__).debug('Exception', exc_info=True)
            attempts += 1
            time.sleep(5)

        return False, None, "Unable to delete group '{name}' after {attempts} attempts".format(name=name, attempts=max_attempts)


    def _created(self, group, reason):
        ''' Evaluation method for create_group() call to _wait_for() '''
        if not group:
            return 'COMPLETE_FAILURE', "no such group" if 'No such group as' in reason else 'CONTINUE', ""

        status = group.get('Status')

        if not status:
            return 'CONTINUE', ""

        if status.endswith('_COMPLETE'):
            return 'COMPLETE_SUCCESS', ""

        if status.endswith('IN_PROGRESS'):
            return 'CONTINUE', ""

        # status.endswith('_FAILED')
        return 'COMPLETE_FAIL', "creation failed"

    def create_group(self, name, image, max_wait = 600, *args, **kwargs):
        ''' Create a container group with retries.
        Waits until container group is successfully created or the creation fails.
        In either case, terminates after waiting max_wait seconds.
        Note that in this case, the group might still get created.

        Parameters
            @param name string: name of group
            @param image string: name of image to use to create the group
            @param max_wait int: maximum time to wait for successful group creation
        Returns
            @rtype (boolean, JSON group, explanation string) where the elements have the following interpretation:
                indicator of success
                JSON group
                explanation (when fails)
        '''
        logging.getLogger(__name__).debug("Checking if group '{name}' already exists".format(name=name))
        group, reason = self.inspect_group(name, timeout=30)
        if group:
            # group exists
            logging.getLogger(__name__).debug("Group '{name}' already exists; exiting".format(name=name))
            return False, None, "Cannot create group, one with name '{name}' already exists.".format(name=name)


        # make initial call
        logging.getLogger(__name__).debug("Attempting to create group '{name}' to be created".format(name=name))
        created, create_response = self._with_retries(self._create_group, name=name, image=image, *args, **kwargs)

        if not created:
            logging.getLogger(__name__).debug("Unable create group '{name}'; exiting".format(name=name))
            return False, None, "Unable to create group '{name}'".format(name=name)

        # wait for group to be created
        created, group, reason = self._wait_for(name, 'creation', self._created)
        if created:
            return created, group, reason

        # if creation failed, delete the group if partially created
        if not created:
            deleted, dgroup, reason = self.forced_delete_group(name)

        # if the deletion failed, we have a major issue
        if not deleted:
            logging.getLogger(__name__).debug("Deletion of group '{name}' failed; exiting".format(name=name))
            return False, None, "{delete_reason} (took too long to provision)".format(delete_reason=reason)

        logging.getLogger(__name__).debug("Deletion of group '{name}' complete; exiting".format(name=name))
        return False, None, "Unable to create group '{name}'".format(name=name)

    def list_groups(self, *args, **kwargs):
        ''' List container groups with retries.

        Returns
            @rtype list: list of JSON objects
        '''
        listed, response = self._with_retries(self._list_groups, *args, **kwargs)
        try:
            if listed:
                return json.loads(response.text)
        except:
            logging.getLogger(__name__).debug("Invalid JSON response returned: {}".format(response.text))
            pass
        return []


    def _mapped(self, group, reason, route):
        ''' Evaluation method for map() call to _wait_for() '''
        if not group:
            return 'COMPLETE_FAIL', "no such group; can't map route" if 'No such group as' in reason else 'CONTINUE', ""

        routes = group.get('Routes')

        if not routes:
            return 'CONTINUE', ""

        if route in routes:
            return 'COMPLETE_SUCCESS', ""

    def map(self, hostname, domain, name, *args, **kwargs):
        ''' Map a route to a container group with retries.
        Waits until route appears in the container group (the map is asynchronous).

        Parameters
            @param hostname: hostname of route
            @param domain string: domain of route
            @param name string: name of group
        Returns
            @rtype (boolean, JSON group, explanation string) where the elements have the following interpretation:
                indicator of success
                JSON group
                explanation (when fails)
        '''
        logging.getLogger(__name__).debug('map called')
        accepted, response = self._with_retries(self._map, hostname, domain, name, *args, **kwargs)
        if not accepted:
            return False, None, "Unable to request routing change: {}".format(response.text if response else '')

        # wait until route appears in group inspect results
        route = '{host}.{domain}'.format(host=hostname, domain=domain)
        return self._wait_for(name, 'map ({r})'.format(r=route), self._mapped, route)


    def _unmapped(self, group, reason, route):
        ''' Evaluation method for unmap() call to _wait_for()'''
        if not group:
            return 'COMPLETE_FAIL', "no such group; can't unmap route" if 'No such group as' in reason else 'CONTINUE', ""

        routes = group.get('Routes')

        if not routes:
            return 'COMPLETE_SUCCESS', ""

        if route in routes:
            return 'CONTINUE', ""

    def unmap(self, hostname, domain, name, *args, **kwargs):
        ''' Unmap a route from a container group with retries.
        Waits until route disappears from the container group.

        Parameters
            @param hostname: hostname of route
            @param domain string: domain of route
            @param name string: name of group
        Returns
            @rtype (boolean, JSON group, explanation string) where the elements have the following interpretation:
                indicator of success
                JSON group
                explanation (when fails)
        '''
        # issue API call
        logging.getLogger(__name__).debug('unmap called')
        accepted, response = self._with_retries(self._unmap, hostname, domain, name, *args, **kwargs)
        if not accepted:
            return False, response, "Unable to request routing change: {}".format(response.text if response else '')

        # wait until route no longer in inspect results
        route = '{host}.{domain}'.format(host=hostname, domain=domain)
        return self._wait_for(name, 'unmap({r})'.format(r=route), self._unmapped, route)


    def _resized(self, group, reason):
        ''' Evaluation method for resize() call to _wait_for()'''
        if not group:
            return 'COMPLETE_FAIL', "no such group; can't resize" if 'No such group as' in reason else 'CONTINUE', ""

        status = group.get('Status')

        if not status:
            return 'CONTINUE', ""

        if status.endswith('_COMPLETE'):
            return 'COMPLETE_SUCCESS', ""

        if status.endswith('IN_PROGRESS'):
            return 'CONTINUE', ""

        # status.endswith('_FAILED')
        return 'COMPLETE_FAIL', "resize failed"

    def resize(self, name, desired, *args, **kwargs):
        ''' Resize a container group with retries.
        Waits until container group is successfully resized or the resize fails.

        Parameters
            @param name string: name of group
            @param desired int: desired size of the group
        Returns
            @rtype (boolean, JSON group, explanation string) where the elements have the following interpretation:
                indicator of success
                JSON group
                explanation (when fails)
        '''
        logging.getLogger(__name__).debug('resize called with target size {size}'.format(size=desired))

        # group should already exist, check first
        logging.getLogger(__name__).debug("Checking if group '{name}' already exists".format(name=name))
        group, reason = self.inspect_group(name, timeout=30)
        if not group:
            # group does not exist
            logging.getLogger(__name__).debug("Group '{name}' does not exist; exiting".format(name=name))
            return False, None, "Cannot resize group, no group named {name} exists. ({reason})".format(name=name, reason=reason)

        # make initial call
        logging.getLogger(__name__).debug("Attempting to resize group '{name}' to size {size}".format(name=name, size=desired))
        resized, resize_response = self._with_retries(self._resize_group, name=name, desired=desired, exit_statuses = [200, 201, 204, 404], *args, **kwargs)

        if not resized:
            msg = "Unable resize group '{name}'; exiting".format(name=name)
            logging.getLogger(__name__).debug(msg)
            return False, None, msg

        # wait for group to be resized
        resized, group, reason = self._wait_for(name, 'resize', self._resized)
        logging.getLogger(__name__).info('After resize, {name} has {size} instances. Goal: {desired}'.format(name=name, size=group['NumberInstances']['CurrentSize'], desired=desired))
        if not resized:
            reason = "{reason}: {name} has {size} instances; wanted {desired}".format(reason=reason, name=name, size=group['NumberInstances']['CurrentSize'], desired=desired)
        return resized, group, reason


if __name__ == '__main__':
    def timed_run(label, f, name, *args, **kwargs):
        start_time = time.time()
        success, group, reason = f(name, *args, **kwargs)
        end_time = time.time()
        execution_time = end_time - start_time
        actual_size = group['NumberInstances']['CurrentSize'] if group else '-'

        print('Timed {operation} {name} {size} ({actual}) {success} in {time}'.format(operation = label,
                                              name=name,
                                              size=5,
                                              actual=actual_size,
                                              success = success,
                                              time=execution_time))
        sys.stdout.flush()

        return success, group, reason

    logger = logging.getLogger('')
    logger.setLevel(logging.DEBUG)
    formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')

    handler1 = logging.StreamHandler(sys.stderr)
    handler1.setLevel(logging.DEBUG)
    handler1.setFormatter(formatter)
    logger.addHandler(handler1)
