<#
.SYNOPSIS
    This cmdlet recursively discovers resources (Management Groups, Subscriptions, Resource Groups, Resources, Policies, Role Assignments) from the provided input scope.
.DESCRIPTION
    This cmdlet recursively discovers resources (Management Groups, Subscriptions, Resource Groups, Resources, Policies, Role Assignments) from the provided input scope.
.EXAMPLE
    #Discover all resources from root management group
    $TenantRootId = '/providers/Microsoft.Management/managementGroups/{0}' -f (Get-AzTenant).Id
    Get-AzOpsResourceDefinitionAtScope -scope $TenantRootId -Verbose
.EXAMPLE
    #Discover all resources from child management group, skip discovery of policies and resource groups
    Get-AzOpsResourceDefinitionAtScope -scope /providers/Microsoft.Management/managementGroups/landingzones -SkipPolicy -SkipResourceGroup
.EXAMPLE
    #Discover all resources from subscription level
    Get-AzOpsResourceDefinitionAtScope -scope /subscriptions/623625ae-cfb0-4d55-b8ab-0bab99cbf45c
.EXAMPLE
    #Discover all resources from resource group level
    Get-AzOpsResourceDefinitionAtScope -scope /subscriptions/623625ae-cfb0-4d55-b8ab-0bab99cbf45c/resourceGroups/myresourcegroup
.EXAMPLE
    #Discover a single resource
    Get-AzOpsResourceDefinitionAtScope -scope /subscriptions/623625ae-cfb0-4d55-b8ab-0bab99cbf45c/resourceGroups/contoso-global-dns/providers/Microsoft.Network/privateDnsZones/privatelink.database.windows.net
.INPUTS
    Discovery scope - supported scopes:
    - Management Groups
    - Subscriptions
    - Resource Groups
    - Resources
.OUTPUTS
    State file representing each discovered resource in the .AzState folder
    Example: .AzState\Microsoft.Network_privateDnsZones-privatelink.database.windows.net.parameters.json
#>
function Get-AzOpsResourceDefinitionAtScope {
    
    [CmdletBinding()]
    [OutputType()]
    param (
        #Discovery scope - input validation
        [Parameter(Mandatory = $true)]
        [ValidateScript( { New-AzOpsScope -scope $_ })]
        $scope,
        #Skip discovery of policies for better performance.
        [Parameter(Mandatory = $false)]
        [switch]$SkipPolicy,
        #Skip discovery of resource groups and resources for better performance.
        [Parameter(Mandatory = $false)]
        [switch]$SkipResourceGroup
    )

    begin {
        Write-Verbose -Message ("Initiating function " + $MyInvocation.MyCommand + " begin")
        #Ensure that required global variables are set.
        Test-AzOpsVariables
    }
    process {
        Write-Verbose -Message " - Processing $scope"
        Write-Verbose -Message ("Initiating function " + $MyInvocation.MyCommand + " process")
        #Get AzOpsScope for inputscope
        $scope = (New-AzOpsScope -scope $scope)

        #Scope contains subscription (subscription > resource group > resource)
        if ($scope.subscription) {
            #Define variable with AzContext for later use in -DefaultProfile parameter
            $context = Get-AzContext -ListAvailable | Where-Object { $_.Subscription.id -eq $scope.subscription }
            #Define  variable with Odatafilter to use in Get-AzResourceGroup and Get-AzResource
            $OdataFilter = '$filter=subscriptionId eq ' + "'$($scope.subscription)'"
            Write-Verbose -Message " - Odatafilter is $odatafilter"
        }
        #Process supported scopes
        switch ($scope.Type) {
            #Process resources
            'resource' {
                Write-Verbose -Message " - Retrieving resource at $scope"
                #Get resource
                $resource = Get-AzResource -ResourceId $scope.scope -ErrorAction:Continue
                if ($resource) {
                    #Convert resource to AzOpsState
                    Write-Verbose -Message " - Serializing AzOpsState for $scope at $($scope.statepath)"
                    ConvertTo-AzOpsState -resource $resource
                }
                else {
                    Write-Warning -Message " - Unable to retrieve resource at Scope $($scope.scope)"
                }
            }
            #Process resource groups
            'resourcegroups' {
                if ($null -eq $rg.ManagedBy) {
                    Write-Verbose -Message " - Retrieving resources at Scope $scope"
                    #Get resource group
                    $rg = (Get-AzResourceGroup -Name $scope.resourcegroup -DefaultProfile $context)
                    ConvertTo-AzOpsState -resourceGroup $rg
                    #Get all resources in resource groups
                    $Resources = Get-AzResource -DefaultProfile $context -ResourceGroupName $rg.ResourceGroupName -ODataQuery $OdataFilter -ExpandProperties
                    foreach ($Resource in $Resources) {
                        #Convert resources to AzOpsState
                        Write-Verbose -Message " - Exporting resource $($resource.Resourceid)"
                        ConvertTo-AzOpsState -resource $resource
                    }
                }
                else {
                    Write-Verbose -Message "- Skipping $($rg.ResourceGroupName) as it is managed by $($rg.ManagedBy)"
                }
            }
            #Process subscriptions
            'subscriptions' {
                #Skip discovery of resource groups if SkipResourceGroup switch have been used
                #Separate discovery of resource groups in subscriptions to support parallel discovery
                if ($true -eq $SkipResourceGroup) {
                    Write-Verbose -Message " - SkipResourceGroup switch used, will not discover Resource Groups"
                }
                else {
                    Write-Verbose -Message " - Iterating ResourceGroups at scope $scope"

                    #Get all resource groups in subscription
                    #$resourceGroup = Get-AzResourceGroup -DefaultProfile $context | Where-Object -Filterscript { -not($_.Managedby) }
                    #Do/until loop to retry when getting the error "Your Azure Credentials have not been set up or expired"
                    #$Resources = Get-AzResource  -ResourceGroupName $rg.ResourceGroupName -ODataQuery $OdataFilter -DefaultProfile $context -ExpandProperties -ErrorAction Stop
                    #https://github.com/Azure/azure-powershell/issues/9448
                    $Retry = 0
                    do {
                        try {
                            $Retry++
                            $ResourceError = $null
                            $resourceGroup = Get-AzResourceGroup -DefaultProfile $context | Where-Object -Filterscript { -not($_.Managedby) }
                        }
                        catch {
                            Write-Warning "Retry Count: $Retry Caught Exception for Credential Error for Get-AzResourceGroup"
                            $ResourceError = $_
                        }
                    } until ($null -eq $ResourceError -or $Retry -eq 10)
                    if ($ResourceError) {
                        Write-Error -Message "Error exporting $($rg.ResourceGroupName), please check your AzContext."
                    }

                    #Discover all resource groups in parallel
                    $resourcegroup | Foreach-Object -ThrottleLimit $env:AzOpsThrottleLimit -Parallel {
                        #region Importing module
                        #We need to import all required modules and declare variables again because of the parallel runspaces
                        #https://devblogs.microsoft.com/powershell/powershell-foreach-object-parallel-feature/
                        $RootPath = (Split-Path $using:PSScriptRoot -Parent)
                        Import-Module $RootPath/AzOps.psd1 -Force
                        Get-ChildItem -Path $RootPath\private -Include *.ps1 -Recurse -Force | ForEach-Object { . $_.FullName }

                        $global:AzOpsState = $using:global:AzOpsState
                        $global:AzOpsStateConfig = $using:global:AzOpsStateConfig
                        $global:AzOpsAzManagementGroup = $using:global:AzOpsAzManagementGroup
                        $global:AzOpsSubscriptions = $using:global:AzOpsSubscriptions
                        #endregion

                        #Convert resource group to AzOps-state.
                        $rg = $_
                        ConvertTo-AzOpsState -resourceGroup $rg
                        Write-Output " - Enumerating Resource Group at $(get-date): $($rg.ResourceId)"

                        $context = Get-AzContext -ListAvailable | Where-Object { $_.Subscription.id -eq $scope.subscription }

                        #Do/until loop to retry when getting the error "Your Azure Credentials have not been set up or expired"
                        #$Resources = Get-AzResource  -ResourceGroupName $rg.ResourceGroupName -ODataQuery $OdataFilter -DefaultProfile $context -ExpandProperties -ErrorAction Stop
                        #https://github.com/Azure/azure-powershell/issues/9448
                        $Retry = 0
                        do {
                            try {
                                $Retry++
                                $ResourceError = $null
                                $Resources = Get-AzResource -DefaultProfile $context  -ResourceGroupName $rg.ResourceGroupName -ODataQuery $using:OdataFilter -ExpandProperties -ErrorAction Stop
                            }
                            catch {
                                Write-Warning "Retry Count: $Retry Caught Exception for Credential Error for Get-AzResource for $($rg.ResourceId)"
                                $ResourceError = $_
                            }
                        } until ($null -eq $ResourceError -or $Retry -eq 10)
                        if ($ResourceError) {
                            Write-Error -Message "Error exporting $($rg.ResourceGroupName), please check your AzContext."
                        }

                        #Loop through resources and convert them to AzOpsState
                        foreach ($Resource in $Resources) {
                            #Convert resources to AzOpsState
                            Write-Verbose -Message " - Exporting resource $($resource.Resourceid)"
                            ConvertTo-AzOpsState -resource $resource
                        }
                    }
                }
                ConvertTo-AzOpsState -Resource (($global:AzOpsAzManagementGroup).children | Where-Object { $_ -ne $null -and $_.Name -eq $scope.name })
            }
            #Process management groups
            'managementGroups' {
                $ChildOfManagementGroups = ($Global:AzOpsAzManagementGroup | Where-Object { $_.Name -eq $scope.managementgroup }).Children
                if ($ChildOfManagementGroups) {

                    <#
                        Due to Credential error below, we are restricting  Thrtottle Limit to 1 instead of $env:AzOpsThrottleLimit
                        https://github.com/Azure/azure-powershell/issues/9448
                        $ChildOfManagementGroups | Foreach-Object -ThrottleLimit $env:AzOpsThrottleLimit -Parallel {
                    #>
                    $ChildOfManagementGroups | Foreach-Object -ThrottleLimit 1 -Parallel {
                        #region Importing module
                        #We need to import all required modules and declare variables again because of the parallel runspaces
                        #https://devblogs.microsoft.com/powershell/powershell-foreach-object-parallel-feature/
                        $RootPath = (Split-Path $using:PSScriptRoot -Parent)
                        Import-Module $RootPath/AzOps.psd1 -Force
                        Get-ChildItem -Path $RootPath\private -Include *.ps1 -Recurse -Force | ForEach-Object { . $_.FullName }

                        $global:AzOpsState = $using:global:AzOpsState
                        $global:AzOpsStateConfig = $using:global:AzOpsStateConfig
                        $global:AzOpsAzManagementGroup = $using:global:AzOpsAzManagementGroup
                        $global:AzOpsSubscriptions = $using:global:AzOpsSubscriptions
                        $SkipPolicy = $using:SkipPolicy
                        $SkipResourceGroup = $using:SkipResourceGroup
                        #endregion

                        $child = $_
                        #$scope = New-AzOpsScope -scope $child.id
                        Write-Verbose " - Enumerating Child Of Management Group ID: $($child.id) and name: $($child.displayName)"
                        Get-AzOpsResourceDefinitionAtScope -scope $child.Id -SkipPolicy:$SkipPolicy -SkipResourceGroup:$SkipResourceGroup -ErrorAction Stop -Verbose:$VerbosePreference
                    }
                }
                ConvertTo-AzOpsState -Resource ($Global:AzOpsAzManagementGroup | Where-Object { $_.Name -eq $scope.managementgroup })
            }
        }
        #Process policies and policy assignments for resourcegroups, subscriptions and management groups
        if ($scope.Type -in 'resourcegroups', 'subscriptions', 'managementgroups' -and -not($SkipPolicy)) {
            #Process policy definitions
            Write-Verbose " - Iterating Policy Definition at scope $scope"
            $currentPolicyDefinitionsInAzure = @()
            $serializedPolicyDefinitionsInAzure = @()
            $currentPolicyDefinitionsInAzure = Get-AzOpsPolicyDefinitionAtScope -scope $scope
            foreach ($policydefinition in $currentPolicyDefinitionsInAzure) {
                Write-Verbose -Message " - Iterating through policyset definition at scope $scope for $($policydefinition.resourceid)"
                Write-Verbose -Message " - Serializing AzOpsState for $scope at $($scope.statepath)"
                #Convert policyDefinition to AzOpsState
                ConvertTo-AzOpsState -CustomObject $policydefinition
                #Serialize policyDefinition in original format and add to variable for full export
                $serializedPolicyDefinitionsInAzure += ConvertTo-AzOpsState -Resource $policydefinition -ReturnObject -ExportRawTemplate
            }

            #Process policySetDefinitions (initiatives)
            Write-Verbose " - Iterating Policy Set Definition at scope $scope"
            $currentPolicySetDefinitionsInAzure = @()
            $serializedPolicySetDefinitionsInAzure = @()
            $currentPolicySetDefinitionsInAzure = Get-AzOpsPolicySetDefinitionAtScope -scope $scope
            foreach ($policysetdefinition in $currentPolicySetDefinitionsInAzure) {
                Write-Verbose -Message " - Iterating through policyset definition at scope $scope for $($policysetdefinition.resourceid)"
                Write-Verbose -Message " - Serializing AzOpsState for $scope at $($scope.statepath)"
                #Convert policySetDefinition to AzOpsState
                ConvertTo-AzOpsState -CustomObject $policysetdefinition
                #Serialize policySetDefinition in original format and add to variable for full export
                $serializedPolicySetDefinitionsInAzure += ConvertTo-AzOpsState -Resource $policysetdefinition -ReturnObject -ExportRawTemplate
            }

            #Process policy assignments
            Write-Verbose " - Iterating Policy Assignment at scope $scope"
            $currentPolicyAssignmentInAzure = @()
            $serializedPolicyAssignmentInAzure = @()
            $currentPolicyAssignmentInAzure = Get-AzOpsPolicyAssignmentAtScope -scope $scope
            foreach ($policyAssignment in $currentPolicyAssignmentInAzure) {
                Write-Verbose -Message " - Iterating through policy definitition at scope $scope for $($policyAssignment.resourceid)"
                #Convert policyAssignment to AzOpsState
                ConvertTo-AzOpsState -CustomObject $policyAssignment
                #Serialize policyAssignment in original format and add to variable for full export
                $serializedPolicyAssignmentInAzure += ConvertTo-AzOpsState -Resource $policyAssignment -ReturnObject -ExportRawTemplate
            }
            #For subscriptions and management groups, export all policy/policyset/policyassignments at scope in one file
            if ($scope.Type -in 'subscriptions', 'managementgroups') {
                #Get statefile from scope
                $parametersJson = Get-Content -Path $scope.statepath | ConvertFrom-Json -Depth 100
                #Create property bag and add resources at scope
                $propertyBag = [ordered]@{
                    'policyDefinitions'    = @($serializedPolicyDefinitionsInAzure)
                    'policySetDefinitions' = @($serializedPolicySetDefinitionsInAzure)
                    'policyAssignments'    = @($serializedPolicyAssignmentInAzure)
                    'roleDefinitions'      = $null
                    'roleAssignments'      = $null
                }
                #Add property bag to parameters json
                $parametersJson.parameters.input.value | Add-Member -Name 'properties' -Type NoteProperty -Value $propertyBag -force
                #Export state file with properties at scope
                ConvertTo-AzOpsState -Resource $parametersJson -ExportPath $scope.statepath -ExportRawTemplate
            }
        }

        #TEMPORARY DISABLED
        #Role definitions and role assignments
        # Write-Verbose "Iterating Role Definition at scope $scope"
        # Get-AzOpsRoleDefinitionAtScope -scope $scope

        # Write-Verbose "Iterating Role Assignment at scope $scope"
        # Get-AzOpsRoleAssignmentAtScope -scope $scope

        Write-Verbose -Message " - Finished Processing $scope"
    }

    end {
        Write-Verbose -Message ("Initiating function " + $MyInvocation.MyCommand + " end")
    }

}
