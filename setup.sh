#!/bin/bash

#options
optionShowHelp=0

#global variables
profile=""
region=""
awsCliBaseCmd="aws "
accountNumber=""
accountAlias=""
command="all"

tempDir=$(mktemp -d)

#functions
show_overview()
{
    echo "                  Quail Hollow AWS Best Practices Setup Script"
    echo "      Copyright (C) 2020  Kintyre Solutions, Inc.  https://www.kintyre.co"
    echo "   This code comes with ABSOLUTELY NO WARRANTY; for details see LICENSE file."
    echo "         This is free software, and you are welcome to redistribute it"
    echo "      under certain conditions of the license details in the LICENSE file."
    echo
}

show_help()
{
   echo "Usage ./setup.sh [options]"
   echo "See readme.md for more information"
}

test_awsCliConfig()
{
    awsCliBaseCmd="aws"
    if [ "${profile}" != "" ] ; then
        awsCliBaseCmd="${awsCliBaseCmd} --profile=${profile}"
    fi

    echo "Checking AWS CLI credentials"
    if ! ${awsCliBaseCmd} sts get-caller-identity > /dev/null 2>&1
    then
        echo "Unable to locate credentials. You can configure credentials by running \"aws configure\""
        exit 1
    fi

    profileRegion="us-east-1"
    echo "Checking region config setting"
    if ${awsCliBaseCmd} configure list | grep "^ *region" | grep -q "not set"
    then
        echo "Unable to locate region in aws config, falling back to default \"${profileRegion}\""
        awsCliBaseCmd="${awsCliBaseCmd} --region=${profileRegion}"
    fi

}

show_options()
{
    echo "Options..."
    echo "  Profile: ${profile}"
    echo "  Region:  ${region}"
    echo "  Alias:   ${accountAlias}"
    echo "  Command: ${command}"
}

set_accountNumber()
{
    # add error handler if this command is not successful
    accountNumber=$(${awsCliBaseCmd} ec2 describe-security-groups --group-names 'Default' \
        --query 'SecurityGroups[0].OwnerId' --output text)
}

set_accountAlias()
{
    if [ "${accountAlias}" == "" ] ; then
        accountAlias=$accountNumber
    fi
}

show_settings()
{
    echo "Settings..."
    echo "  AWS CLI Base Command: ${awsCliBaseCmd}"
    echo "  Account #:            ${accountNumber}"
    echo "  Alias:                ${accountAlias}"
}

config_accountAlias()
{
    aliasFound="false"
    for aa in $(${awsCliBaseCmd} iam list-account-aliases --query 'AccountAliases[*]' --output text)
    do
        if [ "${aa}" == "${accountAlias}" ] ; then
            aliasFound="true"
        fi
    done
    # As account aliases need to be globally unique, there's no way to know if
    # one is taken other than to attempt to create it.  If there's an error, the
    # name is likely already taken.
    if [ "${aliasFound}" == "false" ] ; then
        echo 'Attempting to create IAM account alias'
        if ${awsCliBaseCmd} iam create-account-alias --account-alias "${accountAlias}"
        then
            echo 'IAM Account alias set'
        fi
    fi
}

make_bucket()
{
    for i in $(${awsCliBaseCmd} s3api list-buckets --query "Buckets[].Name" --output text)
    do
        if [ "${i}" == "${1}" ] ; then
            bucketExists=1
            break
        fi
    done
    if [ "${bucketExists}" -eq 1 ] ; then
        echo "S3 bucket ${1} already exists."
    else
        echo "Attempting to create S3 bucket ${1}"
        ${awsCliBaseCmd} s3 mb "s3://${1}"
    fi
}

create_vpc()
{
    echo "creating VPC....."
    bucketName=${accountAlias}-cloudformation-templates 
    make_bucket "${bucketName}"

    # Copy the VPC template up to the working S3 bucket.  Cloud formation needs it in S3.
    ${awsCliBaseCmd} s3 cp vpc.yaml \
        "s3://${bucketName}/vpc.template.yaml"

    #Apply the VPC cloud formation template to the account.
    ${awsCliBaseCmd} cloudformation create-stack \
        --stack-name "vpc-${accountAlias}" \
        --template-url "https://${bucketName}.s3.amazonaws.com/vpc.template.yaml"

}

config_bucketpolicy()
{
    # Generate policy file from template
    templateFile="${tempDir}/$1.json"
    #shellcheck disable=SC2002
    cat "$1BucketPolicyTemplate.json" | \
        sed "s/ACCOUNTNUMBER/${accountNumber}/g" | \
        sed "s/ACCOUNTALIAS/${accountAlias}/g" | \
        sed "s/DATE/$(date +'%Y%m%d')/" > "${templateFile}"

    # Apply policy to bucket
    echo "Applying bucket policy to $2"
    ${awsCliBaseCmd} s3api put-bucket-policy \
            --bucket "$2" \
            --policy "file://${templateFile}"
    rm -f "${templateFile}"
}

enable_cloudtrail()
{
    echo "Enabling CloudTrail....."
    bucketName=${accountAlias}-cloudtrail 
    make_bucket "${bucketName}"
    config_bucketpolicy "cloudtrail" "${bucketName}"
    #Does the trail already exist
    trailName=$(${awsCliBaseCmd} cloudtrail get-trail \
        --name "${accountAlias}-cloudtrail" \
        --query Trail.Name --output text 2> /dev/null)

    if [ "${trailName}" == "${accountAlias}-cloudtrail" ] ; then
        echo "Trail ${accountAlias}-cloudtrail already exists and will not be re-created."
    else
        echo "Creating trail ${accountAlias}-cloudtrail"
        ${awsCliBaseCmd} cloudtrail create-trail \
            --name "${accountAlias}-cloudtrail" \
            --s3-bucket-name "${bucketName}" \
            --is-multi-region-trail
        ${awsCliBaseCmd} cloudtrail start-logging --name "${accountAlias}-cloudtrail"
    fi
    echo "Finished CloudTrail setup!"
    echo -e
}

enable_config()
{
    echo "Enabling Config....."
    bucketName=${accountAlias}-config 
    make_bucket "${bucketName}"
    config_bucketpolicy "config" "${bucketName}"

    #Does the config role already exist
    existingRoleName=$(${awsCliBaseCmd} iam get-role \
        --role-name "${accountAlias}-config-role" \
        --query Role.RoleName \
        --output text 2> /dev/null)

   if [ "${existingRoleName}" == "${accountAlias}-config-role" ] ; then
        echo "Role ${accountAlias}-config-role already exists and will not be created again."
    else
        echo "Creating config role ${accountAlias}-config-role."

        templateFile=${tempDir}/configRoleTrustPolicy.json
        # shellcheck disable=SC2002
        cat configRoleTrustPolicyTemplate.json | \
            sed "s/DATE/$(date +'%Y%m%d')/" > "${templateFile}"

        # Creates config role
        ${awsCliBaseCmd} iam create-role \
            --role-name "${accountAlias}-config-role" \
            --assume-role-policy-document "file://${templateFile}"
        ${awsCliBaseCmd} iam attach-role-policy \
            --role-name "${accountAlias}-config-role" \
            --policy-arn arn:aws:iam::aws:policy/service-role/AWSConfigRole
        rm -f "${templateFile}"
    fi

    # Create SNS service for Config Service
    topicFound="false"
    topicName=""
    for i in $(${awsCliBaseCmd} sns list-topics --query Topics[*].TopicArn --output text)
    do
        searchArn="arn:aws:sns:${region}:${accountNumber}:${accountAlias}-config-topic"
        if [ "${i}" == "${searchArn}" ] ; then
            topicFound="true"
            topicName="${i}"
        fi
    done

    if [ ${topicFound} == "true" ] ; then
        echo "SNS Topic ${topicName} was found and will not be re-created."
    else
        echo "Creating SNS Topic"
        ${awsCliBaseCmd} sns create-topic --name "${accountAlias}-config-topic"

        # Set Config Service to deliver config informtion to S3 and SNS under the given IAM role
        # May have to run this again if fails on first attempt
        #sleep 10
        ${awsCliBaseCmd} configservice subscribe \
            --s3-bucket "${accountAlias}-config" \
            --sns-topic "arn:aws:sns:${region}:${accountNumber}:${accountAlias}-config-topic" \
            --iam-role "arn:aws:iam::${accountNumber}:role/${accountAlias}-config-role"
    fi

    echo "End Config setup"
    echo -e

}

create_billingbucket()
{
    bucketName=${accountAlias}-billing 
    make_bucket "${bucketName}"
    config_bucketpolicy "billing" "${bucketName}"
}

cleanup()
{
    if [ -n "${tempDir}" ] && [ -d "${tempDir}" ]
    then
        rm -rf "${tempDir}"
    fi
}

# main

# Clean up temp files when script exits, whether by successful completion
# exit signal or intgerruption.
trap cleanup EXIT

show_overview

# TODO:  Fix parsing of command line arguments.  For example
#        this works:        "./setup.sh --command vpc"
#        but this does not: "./setup.sh --command=vpc"

# read command line options
while [ "$1" != "" ]; do
    case $1 in
        -p | --profile )        shift
                                profile=$1
                                ;;
        -r | --region )         shift 
                                region=$1
                                ;;
        -a | --alias )          shift
                                accountAlias=$1
                                ;;
        -c | --command )        shift
                                command=$1
                                ;;
        -h | --help )           optionShowHelp=1
                                break
                                ;;
    esac
    shift
done

if [ "${optionShowHelp}" -eq 1 ] ; then
     show_help
     exit 1
fi

show_options

test_awsCliConfig

set_accountNumber

set_accountAlias

show_settings

if [ "${command}" == "all" ] ; then
    config_accountAlias
    enable_cloudtrail
    create_vpc
    enable_config
    exit 1
fi

if [ "${command}" == "iamAlias" ] ; then
    config_accountAlias
    exit 1
fi

if [ "${command}" == "vpc" ] ; then
    create_vpc
    exit 1
fi

if [ "${command}" == "CloudTrail" ] ; then
    enable_cloudtrail
    exit 1
fi

if [ "${command}" == "Config" ] ; then
    enable_config
    exit 1
fi

if [ "${command}" == "Billing" ] ; then
    create_billingbucket
    exit 1
fi
