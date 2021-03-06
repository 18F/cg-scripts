#!/bin/bash

CG_SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source ${CG_SCRIPTS_DIR}/handy-functions.sh

function usage {
    echo
    echo "Usage:"
    echo "  $0 [-e] -o <org>"
    echo
    echo "  Options:"
    echo "      -e     :     Use existing credentials for AWS, rather than service binding credentials"
    echo "      -p     :     Bucket prefix. Allows getting sizes for all buckets even if they're not bound, by using the same logic as the broker to create a bucket name from a service id. (requires -e)"
    echo

    exit
}

function summarize_bucket {
    service_instance=$1
    service_instance_name=$2
    if [[ -n "$bucket_prefix" ]]; then
        summary=$(aws s3 ls --summarize --human-readable --recursive s3://${bucket_prefix}-${service_instance} | grep Total)
    else
        service_bindings=$(cf curl /v3/service_bindings/?service_instance_guids=${service_instance})
        service_keys_guid=$(cf curl "/v3/service_credential_bindings?type=key&service_instance_guids=${service_instance}" | jq -r '.resources[].guid' )
        service_keys=$(cf curl /v3/service_credential_bindings/${service_keys_guid}/details)
        if [[ $(echo "${service_bindings}" | jq -r '.resources | length') == "0" && $(echo ${service_keys} | jq -r '.credentials | length') == 0 ]]; then
            >&2 echo "    ${service_instance_name} is not bound - can't get credentials"
            continue
        fi
        if [[ $(echo ${service_keys} | jq -r '.credentials | length') != 0 ]]; then
            bucket=$(echo "${service_keys}" | jq -r '.credentials.bucket')
            key_id=$(echo "${service_keys}" | jq -r '.credentials.access_key_id')
            secret_key=$(echo "${service_keys}" | jq -r '.credentials.secret_access_key')
            region=$(echo "${service_keys}" | jq -r '.credentials.region')
            bucket=$(echo "${service_keys}" | jq -r '.credentials.bucket')
        else
            # get one binding to get the creds. They're redacted if you get a list of bindings
            binding_guid=$(echo "${service_bindings}" | jq -r .resources[0].guid)
            binding=$(cf curl /v3/service_bindings/${binding_guid})

            bucket=$(echo "${binding}" | jq -r '.data.credentials.bucket')
            key_id=$(echo "${binding}" | jq -r '.data.credentials.access_key_id')
            secret_key=$(echo "${binding}" | jq -r '.data.credentials.secret_access_key')
            region=$(echo "${binding}" | jq -r '.data.credentials.region')
            bucket=$(echo "${binding}" | jq -r '.data.credentials.bucket')
        fi

        if [[ -z "${USE_ENV_CREDENTIALS}" ]]; then
            summary=$(AWS_DEFAULT_REGION=$region AWS_ACCESS_KEY_ID=$key_id AWS_SECRET_ACCESS_KEY=$secret_key aws s3 ls --summarize --human-readable --recursive s3://${bucket} | grep Total)
        else
            summary=$(aws s3 ls --summarize --human-readable --recursive s3://${bucket} | grep Total)
        fi
    fi
    objects=$(echo "$summary" | sed -n -e 's/^.*Total Objects: //p')
    size=$(echo "$summary" | sed -n -e 's/^.*Total Size: //p')
    echo "    ${service_instance_name}:" ${summary}
}

while getopts "o:ep:" opt; do
    case ${opt} in
        o)
          org=${OPTARG}
          ;;
        e)
          USE_ENV_CREDENTIALS=true
          ;;
        p)
          bucket_prefix=${OPTARG}
          ;;
        \?)
          usage
    esac
done

if [[ -z "${org}" ]]; then
    echo "Org not set!"
    usage
fi

if [[ -z "${USE_ENV_CREDENTIALS}" && ( -n "${AWS_SESSION_TOKEN}" || -n "${AWS_SECURITY_TOKEN}" ) ]]; then
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!! Warning: AWS_SESSION_TOKEN or AWS_SECURITY_TOKEN is set. This may cause problems !!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
fi

# get the s3 broker plan guids
service_broker_guid=$(cf curl /v3/service_brokers/?names=s3-broker | jq -r '.resources[0].guid')
s3_service_plan_guids=$(cf curl /v3/service_plans?service_broker_guids=$service_broker_guid | jq -r '.resources[].guid')

# get the spaces for this org 
spaces=$(paginate_v3_api_for_parameter /v3/spaces/?organization_guids=$(cf org $org --guid) guid)
for space in ${spaces}; do
    name_printed=

    space_details=$(cf curl /v3/spaces/${space})
    space_name=$(echo $space_details | jq -r .name)
    service_instances=$(paginate_v3_api_for_parameter /v3/service_instances/?space_guids=${space} guid)
    for service_instance in ${service_instances}; do
        service_instance_info=$(cf curl /v3/service_instances/$service_instance)
        service_instance_name=$(echo ${service_instance_info} | jq -r .name)
        service_plan_guid=$(echo ${service_instance_info} | jq -r .relationships.service_plan.data.guid)
        # filter the service instances down to s3 instances
        for s3_service_plan_guid in $s3_service_plan_guids; do
            if [[ $service_plan_guid = $s3_service_plan_guid ]]; then
                if [[ -z $name_printed ]]; then
                    echo "Space: ${space_name}"
                    name_printed=yes
                fi
                summarize_bucket "$service_instance" "${service_instance_name}"
                continue
            fi
        done
    done
done
