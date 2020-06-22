function invoke-AibManagedImage {
    param (
        [cmdletbinding()]         
        
        # Name of the image to be created
        [Parameter(Mandatory)]
        [string]
        $imageName,

        #Image template name
        [Parameter(Mandatory)]
        [string]
        $imageTemplateName

        # Distribution properties object name (runOutput), i.e. this gives you the properties of the managed image on completion
        #[Parameter(Mandatory)]
        #[string]
        #$runOutputName
    )

    # Import Azure Az module
    Import-Module Az.Accounts

    # Connect to Azure subscription
    Write-Information -MessageData "Connecting you to your Azure Subscription" -InformationAction Continue
    Connect-AzAccount

    ## Get exisiting Context
    $currentAzContext = Get-AzContext

    $subscriptionID=$currentAzContext.Subscription.Id

    $imageResourceGroup = "BalticImagesRg"
    $location = "uk west"
    $runOutputName = $imageName+'RO'

    # Image resource group. Create if it does not exist
    Get-AzResourceGroup -Name $imageResourceGroup -ErrorVariable notPresent -ErrorAction SilentlyContinue
    if (!$notPresent)
    {
        Write-Warning -Message "Resource group already exists."
    } else {
        Write-Information -MessageData "Creating Image resource group $imageResourceGroup" -InformationAction Continue
        New-AzResourceGroup -Name $imageResourceGroup -Location $location
    }

    ## User identity. Create if the identity does not exist.
    # Setup role def name. this needs to be unique
    $timeInt=$(Get-Date -UFormat "ddMMYY")
    $imageRoleDefName="Azure Image Builder Image Def"+$timeInt
    $identityName="aibIdentity"+$timeInt
    
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
        
        #Assign permissions for the identity to distribute images
        $aibRoleImageCreationUrl="https://raw.githubusercontent.com/cnomadl/LngAzureImageBuilder/master/AIB_Security_Roles/aibRoleImageCreation.json"
        $aibRoleImageCreationPath = "aibRoleImageCreation.json"

        # Download config file
        Invoke-WebRequest -Uri $aibRoleImageCreationUrl -OutFile $aibRoleImageCreationPath -UseBasicParsing

        ((Get-Content -path $aibRoleImageCreationPath -Raw) -replace '<subscriptionID>',$subscriptionID) | Set-Content -Path $aibRoleImageCreationPath
        ((Get-Content -path $aibRoleImageCreationPath -Raw) -replace '<rgName>', $imageResourceGroup) | Set-Content -Path $aibRoleImageCreationPath
        ((Get-Content -path $aibRoleImageCreationPath -Raw) -replace 'Azure Image Builder Service Image Creation Role', $imageRoleDefName) | Set-Content -Path $aibRoleImageCreationPath

        # Create the role definition
        New-AzRoleDefinition -InputFile  ./aibRoleImageCreation.json

        # Grant role definition to image builder service principle
        New-AzRoleAssignment -ObjectId $idenityNamePrincipalId -RoleDefinitionName $imageRoleDefName -Scope "/subscriptions/$subscriptionID/resourceGroups/$imageResourceGroup"
    }

    # Download and configure the image template
    $templateUrl="https://raw.githubusercontent.com/cnomadl/LngAzureImageBuilder/master/armTemplateWinServerMngd.json"
    $templateFilePath = "armTemplateWinServerMngd.json"

    Invoke-WebRequest -Uri $templateUrl -OutFile $templateFilePath -UseBasicParsing

    ((Get-Content -path $templateFilePath -Raw) -replace '<subscriptionID>',$subscriptionID) | Set-Content -Path $templateFilePath
    ((Get-Content -path $templateFilePath -Raw) -replace '<rgName>',$imageResourceGroup) | Set-Content -Path $templateFilePath
    ((Get-Content -path $templateFilePath -Raw) -replace '<region>',$location) | Set-Content -Path $templateFilePath
    ((Get-Content -path $templateFilePath -Raw) -replace '<runOutputName>',$runOutputName) | Set-Content -Path $templateFilePath
    ((Get-Content -path $templateFilePath -Raw) -replace '<imageName>',$imageName) | Set-Content -Path $templateFilePath
    ((Get-Content -path $templateFilePath -Raw) -replace '<imgBuilderId>',$idenityNameResourceId) | Set-Content -Path $templateFilePath

    # Submit the template for validation, permissions check and staging
    New-AzResourceGroupDeployment -ResourceGroupName $imageResourceGroup -TemplateFile $templateFilePath -api-version "2019-05-01-preview" -imageTemplateName $imageTemplateName -svclocation $location

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

    ## Remove definitions
    Remove-AzRoleDefinition -Name "$identityNamePrincipleId" -Force -Scope "/subscriptions/$subscriptionID/resourceGroups/$imageResourceGroup"

    ## Delete identity
    Remove-AzUserAssignedIdentity -ResourceGroupName $imageResourceGroup -Name $identityName -Force
}