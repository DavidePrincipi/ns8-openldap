*** Settings ***
Resource    keywords.resource

*** Variables ***
${MID1}    unknown

*** Test Cases ***
Remove the modules from the cluster
    Remove a module instance    ${MID1}
