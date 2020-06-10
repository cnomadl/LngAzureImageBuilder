function invokeAIB {
    param (
        [cmdletbinding()]      
        
        # Destination image resource group
        [Parameter(Mandatory)]
        [string]
        $imageResourceGroup,

        # Location used for replication and the resource group
        [Parameter(Mandatory)]
        [string]
        $location,        
        
        # Name of the image to be created
        [Parameter(Mandatory)]
        [string]
        $imageName,

        #Image template name
        [Parameter(Mandatory)]
        [string]
        $imageTemplateName,

        # Distribution properties object name (runOutput), i.e. this gives you the properties of the managed image on completion
        [Parameter(Mandatory)]
        [string]
        $runOutputName
        
    )

    # Additional replication regions
    $replRegion2

    #Vnet Properties
    $vnetName=""
    # Subnet Name
    $subnetName=""
    #Vnet resource group name
    $vnetRgName=""
    # Network security group name
    $nsgName=""
    # The Vnet MUST be in the same region as the AIB service region


    # Import Azure Az module
    Import-Module Az.Accounts

    # Connect to Azure subscription
    Write-Information -MessageData "Connecting you to your Azure Subscription" -InformationAction Continue
    Connect-AzAccount

    ## Get exisiting Context
    $currentAzContext = Get-AzContext

    $subscriptionID=$currentAzContext.Subscription.Id

    # Image resorce group. Create if it does not exist
    Get-AzResourceGroup -Name $imageResourceGroup -ErrorVariable notPresent -ErrorAction SilentlyContinue
    if (!$notPresent)
    {
        Write-Warning -Message "Resource group already exists."
    } else {
        Write-Information -MessageData "Creating Image resource group $imageResourceGroup" -InformationAction Continue
        New-AzResourceGroup -Name $imageResourceGroup -Location $location
    }

    # Add NSG rule to allow the AIB deployed Azure Load Balancer to communicate with the proxy VM
    Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $vnetRgName  | Add-AzNetworkSecurityRuleConfig -Name AzureImageBuilderAccess -Description "Allow Image Builder Private Link Access to Proxy VM" -Access Allow -Protocol Tcp -Direction Inbound -Priority 400 -SourceAddressPrefix AzureLoadBalancer -SourcePortRange * -DestinationAddressPrefix VirtualNetwork -DestinationPortRange 60000-60001 | Set-AzNetworkSecurityGroup

    ## Disable Private Service Policy on subnet
    $virtualNetwork = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetRgName
    ($virtualNetwork | Select -ExpandProperty subnets | Where-Object {$_.Name -eq $subnetName} ).privateLinkServiceNetworkPolicies = "Disabled"
    $virtualNetwork | Set-AzVirtualNetwork

    # Download config files
    $templateUrl="https://raw.githubusercontent.com/cnomadl/LngAzureImageBuilder/master/armTemplateWinSIG.json"
    $templateFilePath = "armTemplateWinSIG.json"

    $aibRoleNetworkingUrl="https://raw.githubusercontent.com/cnomadl/LngAzureImageBuilder/master/AIB_Security_Roles/aibRoleNetworking.json"

    $aibRoleImageCreationUrl="https://raw.githubusercontent.com/cnomadl/LngAzureImageBuilder/master/AIB_Security_Roles/aibRoleImageCreation.json"
    $aibRoleImageCreationPath = "aibRoleImageCreation.json"

    ## Config files
    Invoke-WebRequest -Uri $templateUrl -OutFile $templateFilePath -UseBasicParsing
    Invoke-WebRequest -Uri $aibRoleNetworkingUrl -OutFile $aibRoleNetworkingPath -UseBasicParsing
    Invoke-WebRequest -Uri $aibRoleImageCreationUrl -OutFile $aibRoleImageCreationPath -UseBasicParsing

    # Update AIB image config template
    ((Get-Content -path $templateFilePath -Raw) -replace '<subscriptionID>',$subscriptionID) | Set-Content -Path $templateFilePath
    ((Get-Content -path $templateFilePath -Raw) -replace '<rgName>',$imageResourceGroup) | Set-Content -Path $templateFilePath
    ((Get-Content -path $templateFilePath -Raw) -replace '<region>',$location) | Set-Content -Path $templateFilePath
    ((Get-Content -path $templateFilePath -Raw) -replace '<runOutputName>',$runOutputName) | Set-Content -Path $templateFilePath
    ((Get-Content -path $templateFilePath -Raw) -replace '<imageName>',$imageName) | Set-Content -Path $templateFilePath

    ((Get-Content -path $templateFilePath -Raw) -replace '<vnetName>',$vnetName) | Set-Content -Path $templateFilePath
    ((Get-Content -path $templateFilePath -Raw) -replace '<subnetName>',$subnetName) | Set-Content -Path $templateFilePath
    ((Get-Content -path $templateFilePath -Raw) -replace '<vnetRgName>',$vnetRgName) | Set-Content -Path $templateFilePath

    ((Get-Content -path $templateFilePath -Raw) -replace '<imageDefName>',$imageDefName) | Set-Content -Path $templateFilePath
    ((Get-Content -path $templateFilePath -Raw) -replace '<sharedImageGalName>',$sigGalleryName) | Set-Content -Path $templateFilePath
    ((Get-Content -path $templateFilePath -Raw) -replace '<region1>',$location) | Set-Content -Path $templateFilePath
    ((Get-Content -path $templateFilePath -Raw) -replace '<region2>',$replRegion2) | Set-Content -Path $templateFilePath

    ((Get-Content -path $templateFilePath -Raw) -replace '<imgBuilderId>',$idenityNameResourceId) | Set-Content -Path $templateFilePath

    ## User identity. Create if the identity does not exist.
    # Setup role def name. this needs to be unique
    $timeInt=$(Get-Date -UFormat "%s")
    $imageRoleDefName="Azure Image Builder Image Def"
    $networkRoleDefname="Azure Image Builder Network Def"
    $identityName="aibIdentity"
    
    # Create user identity
    ## Add AZ PwoerShell module to support AzUserAssignedIdentity
    Install-Module -Name Az.ManagedServiceIdentity


    # Check if the identity exists
    Get-AzUserAssignedIdentity -ResourceGroupName $imageResourceGroup -Name $identityName -ErrorVariable notPresent -ErrorAction SilentlyContinue
    if (!$notPresent)
    {
        Write-Warning -Message "User Identity already exists."
    } else {
        Write-Information -MessageData "Creating new user identity $identityName" -InformationAction Continue
        New-AzUserAssignedIdentity -ResourceGroupName $imageResourceGroup -Name $identityName

        $idenityNameResourceId=$(Get-AzUserAssignedIdentity -ResourceGroupName $imageResourceGroup -Name $idenityName).Id
        $idenityNamePrincipalId=$(Get-AzUserAssignedIdentity -ResourceGroupName $imageResourceGroup -Name $idenityName).PrincipalId

        # Update template with identity
        ((Get-Content -path $templateFilePath -Raw) -replace '<imgBuilderId>',$idenityNameResourceId) | Set-Content -Path $templateFilePath
        
        #Assign permissions for the identity to distribute images

        # Update the role definition name
        ((Get-Content -path $aibRoleImageCreationPath -Raw) -replace 'Azure Image Builder Service Image Creation Role', $imageRoleDefName) | Set-Content -Path $aibRoleImageCreationPath
        ((Get-Content -path $aibRoleNetworkingPath -Raw) -replace 'Azure Image Builder Service Networking Role',$networkRoleDefName) | Set-Content -Path $aibRoleNetworkingPath

        # Update role definitions
        ((Get-Content -path $aibRoleNetworkingPath -Raw) -replace '<subscriptionID>',$subscriptionID) | Set-Content -Path $aibRoleNetworkingPath
        ((Get-Content -path $aibRoleNetworkingPath -Raw) -replace '<vnetRgName>',$vnetRgName) | Set-Content -Path $aibRoleNetworkingPath

        ((Get-Content -path $aibRoleImageCreationPath -Raw) -replace '<subscriptionID>',$subscriptionID) | Set-Content -Path $aibRoleImageCreationPath
        ((Get-Content -path $aibRoleImageCreationPath -Raw) -replace '<rgName>', $imageResourceGroup) | Set-Content -Path $aibRoleImageCreationPath

        # Create role definitions from role configurations, this avoids granting contributor to the SPN
        New-AzRoleDefinition -InputFile ./aibRoleImageCreation.json
        New-AzRoleDefinition -InputFile ./aibRoleNetworking.json

        # Grant role definition to image builder service principle
        New-AzRoleAssignment -ObjectId $idenityNamePrincipalId -RoleDefinitionName $imageRoleDefName -Scope "/subscriptions/$subscriptionID/resourceGroups/$imageResourceGroup"
        New-AzRoleAssignment -ObjectId $idenityNamePrincipalId -RoleDefinitionName $networkRoleDefName -Scope "/subscriptions/$subscriptionID/resourceGroups/$vnetRgName"
    }    

    # Submit the template for validation, permissions check and staging
    New-AzResourceGroupDeployment -ResourceGroupName $imageResourceGroup -TemplateFile $templateFilePath -api-version "2019-05-001-preview" -imageTemplateName $imageTemplateName -svclocation $location

    # Now we build the image
    Invoke-AzResourceAction -ResourceName $imageTemplateName -ResourceGroupName $imageResourceGroup -ResourceType Microsoft.VirtualMachineImages/imageTemplates -ApiVersion "2019-05-01-preview" -Action Run -Force -wait

    # Clean up
    ## Delete Image Template Artifact

    ### Get ResourceID of the image template
    $resTemplateId = Get-AzResource -ResourceName $imageTemplateName -ResourceGroupName $imageResourceGroup -ResourceType Microsoft.VirtualMachineImage/imageTemplate -ApiVersion "2019-05-01"

    ### Delete Image Template Artifiact
    Remove-AzResource -ResourceId $resTemplateId.ResourceId -Force

    # Delete role assignment
    ## Remove role assignment
    Remove-AzRoleAssignment -ObjectId $idenityNamePrincipalId -RoleDefinitionName $imageRoleDefName -Scope "/subscriptions/$subscriptionID/resourceGroups/$imageResourceGroup"
    Remove-AzRoleAssignment -ObjectId $idenityNamePrincipalId -RoleDefinitionName $networkRoleDefname -Scope "/subscriptions/$subscriptionID/resourceGroups/$vnetRgName"

    ## Remove definitions
    Remove-AzRoleDefinition -Id $imageRoleDefObjId -Force
    Remove-AzRoleDefinition -Id $networkRoleDefObjId -Force

    ## Delete identity
    Remove-AzUserAssignedIdentity -ResourceGroupName $imageResourceGroup -Name $identityName -Force

}