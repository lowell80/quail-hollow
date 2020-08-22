#!/bin/bash

#options
optionShowHelp=0
optionAll=1

#global variables
profile=""
region=""
awsCliBaseCmd="aws "
accountNumber=""
accountAlias=""
command="all"

#functions
show_overview()
{
    echo "    Quail Hollow AWS Best Practices Setup Script"
    echo "  Copyright (C) 2020  Kintyre Solutions, Inc.  https://www.kintyre.co"
    echo "This code comes with ABSOLUTELY NO WARRANTY; for details see LICENSE file."
    echo "This is free software, and you are welcome to redistribute it"
    echo " under certain conditions of the license details in the LICENSE file."
}

show_help()
{
   echo "Usage ./setup.sh [options]"
   echo "See readme.md for more information"
}

set_awsCliBaseCmd()
{
    awsCliBaseCmd="aws "
    if [ "${profile}" != "" ] ; then
        awsCliBaseCmd=$awsCliBaseCmd" --profile="$profile
    fi
    if [ "${region}" != "" ] ; then
        awsCliBaseCmd=$awsCliBaseCmd" --region="$region
    fi
}

test_alsCliConfig()
{
    # needs to be improved.. if no profiles OR if no region on default profile or the profile requested, and no region parameter provied, then exit
    echo "Testing AWS CLI configuration..."
    aws configure list-profiles
}

show_options()
{
    echo "Options..."
    echo "  Profile: "      $profile
    echo "  Region: "       $region
    echo "  Alias: "        $accountAlias
    echo "  Command: "      $command
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
    echo "  AWS CLI Base Command: "     $awsCliBaseCmd
    echo "  Account #: "                $accountNumber
    echo "  Alias: "                    $accountAlias
}

config_accountAlias()
{
    aliasFound="false"
    for aa in $(${awsCliBaseCmd} iam list-account-aliases --query 'AccountAliases[*]' --output text)
    do
        if [ "${aa}" == "${ACCOUNTALIAS}" ] ; then
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

# main
show_overview

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
                                ;;
    esac
    shift
done

if [ "${optionShowHelp}" == 1 ] ; then
     show_help
     exit 1
fi

set_awsCliBaseCmd

show_options

test_alsCliConfig

set_accountNumber

set_accountAlias

show_settings

if [ "${command}" == "all" ] ; then
    config_accountAlias
    exit 1
fi

if [ "${command}" == "iamAlias" ] ; then
    config_accountAlias
    exit 1
fi