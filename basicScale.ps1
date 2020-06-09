﻿param(
	[Parameter(mandatory = $false)]
	[object]$WebHookData
)
# If runbook was called from Webhook, WebhookData will not be null.
if ($WebHookData) {

	# Collect properties of WebhookData
	$WebhookName = $WebHookData.WebhookName
	$WebhookHeaders = $WebHookData.RequestHeader
	$WebhookBody = $WebHookData.RequestBody

	# Collect individual headers. Input converted from JSON.
	$From = $WebhookHeaders.From
	$Input = (ConvertFrom-Json -InputObject $WebhookBody)
}
else
{
	Write-Error -Message 'Runbook was not started from Webhook' -ErrorAction stop
}
$AADTenantId = $Input.AADTenantId
$SubscriptionID = $Input.SubscriptionID
#$TenantGroupName = $Input.TenantGroupName
$ResourceGroupName = $Input.ResourceGroupName
#$TenantName = $Input.TenantName
$HostpoolName = $Input.hostpoolname
$BeginPeakTime = $Input.BeginPeakTime
$EndPeakTime = $Input.EndPeakTime
$TimeDifference = $Input.TimeDifference
$SessionThresholdPerCPU = $Input.SessionThresholdPerCPU
$MinimumNumberOfRDSH = $Input.MinimumNumberOfRDSH
$LimitSecondsToForceLogOffUser = $Input.LimitSecondsToForceLogOffUser
$LogOffMessageTitle = $Input.LogOffMessageTitle
$LogOffMessageBody = $Input.LogOffMessageBody
$MaintenanceTagName = $Input.MaintenanceTagName
$LogAnalyticsWorkspaceId = $Input.LogAnalyticsWorkspaceId
$LogAnalyticsPrimaryKey = $Input.LogAnalyticsPrimaryKey
#$RDBrokerURL = $Input.RDBrokerURL
$AutomationAccountName = $Input.AutomationAccountName
$ConnectionAssetName = $Input.ConnectionAssetName

Set-ExecutionPolicy -ExecutionPolicy Undefined -Scope Process -Force -Confirm:$false
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine -Force -Confirm:$false
# Setting ErrorActionPreference to stop script execution when error occurs
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
#Function to convert from UTC to Local time
function Convert-UTCtoLocalTime
{
	param(
		$TimeDifferenceInHours
	)

	$UniversalTime = (Get-Date).ToUniversalTime()
	$TimeDifferenceMinutes = 0
	if ($TimeDifferenceInHours -match ":") {
		$TimeDifferenceHours = $TimeDifferenceInHours.Split(":")[0]
		$TimeDifferenceMinutes = $TimeDifferenceInHours.Split(":")[1]
	}
	else {
		$TimeDifferenceHours = $TimeDifferenceInHours
	}
	#Azure is using UTC time, justify it to the local time
	$ConvertedTime = $UniversalTime.AddHours($TimeDifferenceHours).AddMinutes($TimeDifferenceMinutes)
	return $ConvertedTime
}
# With workspace
if ($LogAnalyticsWorkspaceId -and $LogAnalyticsPrimaryKey)
{
	Write-Output "in log analytics workspace"
	Write-Output "resource group name $ResourceGroupName"
	# Function for to add logs to log analytics workspace
	function Add-LogEntry
	{
		param(
			[Object]$LogMessageObj,
			[string]$LogAnalyticsWorkspaceId,
			[string]$LogAnalyticsPrimaryKey,
			[string]$LogType,
			$TimeDifferenceInHours
		)

		if ($LogAnalyticsWorkspaceId -ne $null) {

			foreach ($Key in $LogMessage.Keys) {
				switch ($Key.substring($Key.Length - 2)) {
					'_s' { $sep = '"'; $trim = $Key.Length - 2 }
					'_t' { $sep = '"'; $trim = $Key.Length - 2 }
					'_b' { $sep = ''; $trim = $Key.Length - 2 }
					'_d' { $sep = ''; $trim = $Key.Length - 2 }
					'_g' { $sep = '"'; $trim = $Key.Length - 2 }
					default { $sep = '"'; $trim = $Key.Length }
				}
				$LogData = $LogData + '"' + $Key.substring(0,$trim) + '":' + $sep + $LogMessageObj.Item($Key) + $sep + ','
			}
			$TimeStamp = Convert-UTCtoLocalTime -TimeDifferenceInHours $TimeDifferenceInHours
			$LogData = $LogData + '"TimeStamp":"' + $timestamp + '"'

			#Write-Verbose "LogData: $($LogData)"
			$json = "{$($LogData)}"

			$PostResult = Send-OMSAPIIngestionFile -customerId $LogAnalyticsWorkspaceId -sharedKey $LogAnalyticsPrimaryKey -Body "$json" -logType $LogType -TimeStampField "TimeStamp"
			#Write-Verbose "PostResult: $($PostResult)"
			if ($PostResult -ne "Accepted") {
				Write-Error "Error posting to OMS - $PostResult"
			}
		}
	}

	# Collect the credentials from Azure Automation Account Assets
	$Connection = Get-AutomationConnection -Name $ConnectionAssetName

	# Authenticating to Azure
	Clear-AzContext -Force
	$AZAuthentication = Connect-AzAccount -ApplicationId $Connection.ApplicationId -TenantId $AADTenantId -CertificateThumbprint $Connection.CertificateThumbprint -ServicePrincipal
	if ($AZAuthentication -eq $null) {
		Write-Output "Failed to authenticate Azure: $($_.exception.message)"
		$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Failed to authenticate Azure: $($_.exception.message)" }
		Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
		exit
	} else {
		$AzObj = $AZAuthentication | Out-String
		Write-Output "Authenticating as service principal for Azure. Result: `n$AzObj"
		$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Authenticating as service principal for Azure. Result: `n$AzObj" }
		Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
	}
	# Set the Azure context with Subscription
	$AzContext = Set-AzContext -SubscriptionId $SubscriptionID
	if ($AzContext -eq $null) {
		Write-Error "Please provide a valid subscription"
		exit
	} else {
		$AzSubObj = $AzContext | Out-String
		Write-Output "Sets the Azure subscription. Result: `n$AzSubObj"
		$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Sets the Azure subscription. Result: `n$AzSubObj" }
		Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
	}

	# Authenticating to WVD
	<#try {
		$WVDAuthentication = Add-RdsAccount -DeploymentUrl $RDBrokerURL -ApplicationId $Connection.ApplicationId -CertificateThumbprint $Connection.CertificateThumbprint -AADTenantId $AadTenantId
	}
	catch {
		Write-Output "Failed to authenticate WVD: $($_.exception.message)"
		$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Failed to authenticate WVD: $($_.exception.message)" }
		Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
		exit
	}
	$WVDObj = $WVDAuthentication | Out-String
	Write-Output "Authenticating as service principal for WVD. Result: `n$WVDObj"
	$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Authenticating as service principal for WVD. Result: `n$WVDObj" }
	Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference #>

	<#
	.Description
	Helper functions
	#>
	# Function to chceck and update the loadbalancer type is BreadthFirst
	function UpdateLoadBalancerTypeInPeakandOffPeakwithBredthFirst {
		param(
			[string]$HostpoolLoadbalancerType,
			[string]$ResourceGroupName,
			[string]$HostpoolName,
			[int]$MaxSessionLimitValue,
			[string]$LogAnalyticsWorkspaceId,
			[string]$LogAnalyticsPrimaryKey,
			$TimeDifference
		)
		if ($HostpoolLoadbalancerType -ne "BreadthFirst") {
			Write-Output "Changing hostpool load balancer type:'BreadthFirst' Current Date Time is: $CurrentDateTime"
			$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Changing hostpool load balancer type:'BreadthFirst' Current Date Time is: $CurrentDateTime" }
			Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
			$EditLoadBalancerType = Update-AzWvdHostPool -Name $HostpoolName -ResourceGroupName $ResourceGroupName -LoadBalancerType BreadthFirst -MaxSessionLimit $MaxSessionLimitValue
			if ($EditLoadBalancerType.LoadBalancerType -eq 'BreadthFirst') {
				Write-Output "Hostpool load balancer type in peak hours is 'BreadthFirst'"
				$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Hostpool load balancer type in peak hours is 'BreadthFirst'" }
				Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
			}
		}

	}

	# Function to Check if the session host is allowing new connections
	function Check-ForAllowNewConnections
	{
		param(
			[string]$ResourceGroupName,
			[string]$HostpoolName,
			[string]$SessionHostName
		)
		# Check if the session host is allowing new connections
		
			Write-Output " rg : $ResourceGroupName hp : $HostpoolName name : $SessionHostName"
			$StateOftheSessionHost = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName -Name $SessionHostName

			if (!($StateOftheSessionHost.AllowNewSession)) {
				
				Update-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName -Name $SessionHostName -AllowNewSession:$true
				
			}
		
		
		

	}
	# Start the Session Host 
	function Start-SessionHost
	{
		param(
			[string]$VMName,
			[string]$LogAnalyticsWorkspaceId,
			[string]$LogAnalyticsPrimaryKey,
			$TimeDifference
		)
		try {
			Get-AzVM | Where-Object { $_.Name -eq $VMName } | Start-AzVM -AsJob | Out-Null
		}
		catch {
			Write-Error "Failed to start Azure VM: $($VMName) with error: $($_.exception.message)"
			$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Failed to start Azure VM: $($VMName) with error: $($_.exception.message)" }
			Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
			exit
		}

	}
	# Stop the Session Host
	function Stop-SessionHost
	{
		param(
			[string]$VMName,
			[string]$LogAnalyticsWorkspaceId,
			[string]$LogAnalyticsPrimaryKey,
			$TimeDifference
		)
		try {
			Get-AzVM | Where-Object { $_.Name -eq $VMName } | Stop-AzVM -Force -AsJob | Out-Null
		}
		catch {
			Write-Error "Failed to stop Azure VM: $($VMName) with error: $($_.exception.message)"
			$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Failed to stop Azure VM: $($VMName) with error: $($_.exception.message)" }
			Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
			exit
		}
	}
	# Check if the Session host is available
	function Check-IfSessionHostIsAvailable
	{
		param(
			[string]$ResourceGroupName,
			[string]$HostpoolName,
			[string]$SessionHostName
		)
        Write-Output "Waiting for session host '$SessionHostName' to be available"
        $LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Waiting for session host '$SessionHostName' to be available" }
		Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
		$IsHostAvailable = $false
		while (!$IsHostAvailable) {
			$SessionHostStatus = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName -Name $SessionHostName
			if ($SessionHostStatus.Status -eq "Available" -or $SessionHostStatus.Status -eq 'NeedsAssistance') {
				$IsHostAvailable = $true
			}
		}
		return $IsHostAvailable
	}

	# Converting date time from UTC to Local
	$CurrentDateTime = Convert-UTCtoLocalTime -TimeDifferenceInHours $TimeDifference

	# Set context to the appropriate tenant group
	<#$CurrentTenantGroupName = (Get-RdsContext).TenantGroupName
	if ($TenantGroupName -ne $CurrentTenantGroupName) {
		Write-Output "Running switching to the $TenantGroupName context"
		$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Running switching to the $TenantGroupName context" }
		Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
		Set-RdsContext -TenantGroupName $TenantGroupName
	}#>

	$BeginPeakDateTime = [datetime]::Parse($CurrentDateTime.ToShortDateString() + ' ' + $BeginPeakTime)
	$EndPeakDateTime = [datetime]::Parse($CurrentDateTime.ToShortDateString() + ' ' + $EndPeakTime)

	# check the calculated end time is later than begin time in case of time zone
	<#
    if ($EndPeakDateTime -lt $BeginPeakDateTime) {
		$EndPeakDateTime = $EndPeakDateTime.AddDays(1)
	} #>
    if ($EndPeakDateTime -lt $BeginPeakDateTime) {
    if ($CurrentDateTime -lt $EndPeakDateTime) { $BeginPeakDateTime = $BeginPeakDateTime.AddDays(-1) } else { $EndPeakDateTime = $EndPeakDateTime.AddDays(1) }
    }
	# Checking givne host pool name exists in Tenant
	$HostpoolInfo = Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $HostpoolName
	if ($HostpoolInfo -eq $null) {
		Write-Output "Hostpoolname '$HostpoolName' does not exist in the tenant of '$TenantName'. Ensure that you have entered the correct values."
		$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Hostpoolname '$HostpoolName' does not exist in the tenant of '$TenantName'. Ensure that you have entered the correct values." }
		Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
		exit
	}

	# Setting up appropriate load balacing type based on PeakLoadBalancingType in Peak hours
	$HostpoolLoadbalancerType = $HostpoolInfo.LoadBalancerType
	[int]$MaxSessionLimitValue = $HostpoolInfo.MaxSessionLimit
	if ($CurrentDateTime -ge $BeginPeakDateTime -and $CurrentDateTime -le $EndPeakDateTime) {
		UpdateLoadBalancerTypeInPeakandOffPeakwithBredthFirst -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName -MaxSessionLimitValue $MaxSessionLimitValue -HostpoolLoadbalancerType $HostpoolLoadbalancerType -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -TimeDifference $TimeDifference
	}
	else {
		UpdateLoadBalancerTypeInPeakandOffPeakwithBredthFirst -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName -MaxSessionLimitValue $MaxSessionLimitValue -HostpoolLoadbalancerType $HostpoolLoadbalancerType -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -TimeDifference $TimeDifference
	}
	Write-Output "Starting WVD tenant hosts scale optimization: Current Date Time is: $CurrentDateTime"
	$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Starting WVD tenant hosts scale optimization: Current Date Time is: $CurrentDateTime" }
	Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
	# Check the after changing hostpool loadbalancer type
	$HostpoolInfo = Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $HostPoolName

	# Check if the hostpool have session hosts
	$ListOfSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName -ErrorAction Stop | Sort-Object Name
	if ($ListOfSessionHosts -eq $null) {
		Write-Output "Session hosts does not exist in the Hostpool of '$HostpoolName'. Ensure that hostpool have hosts or not?."
		$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Session hosts does not exist in the Hostpool of '$HostpoolName'. Ensure that hostpool have hosts or not?." }
		Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
		exit
	}



	# Check if it is during the peak or off-peak time
	if ($CurrentDateTime -ge $BeginPeakDateTime -and $CurrentDateTime -le $EndPeakDateTime)
	{
		Write-Output "It is in peak hours now"
		$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "It is in peak hours now" }
		Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
		Write-Output "Starting session hosts as needed based on current workloads."
		$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Starting session hosts as needed based on current workloads." }
		Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference


		# Peak hours check and remove the MinimumnoofRDSH value dynamically stored in automation variable 												   
		$AutomationAccount = Get-AzAutomationAccount -ErrorAction Stop | Where-Object { $_.AutomationAccountName -eq $AutomationAccountName }
		$OffPeakUsageMinimumNoOfRDSH = Get-AzAutomationVariable -Name "$HostpoolName-OffPeakUsage-MinimumNoOfRDSH" -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName -ErrorAction SilentlyContinue
		if ($OffPeakUsageMinimumNoOfRDSH) {
			Remove-AzAutomationVariable -Name "$HostpoolName-OffPeakUsage-MinimumNoOfRDSH" -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName
		}
		# Check the number of running session hosts
		[int]$NumberOfRunningHost = 0
		# Total of running cores
		[int]$TotalRunningCores = 0
		# Total capacity of sessions of running VMs
		$AvailableSessionCapacity = 0
		#Initialize variable for to skip the session host which is in maintenance.
		$SkipSessionhosts = 0
		$SkipSessionhosts = @()

		$HostPoolUserSessions = Get-AzWvdUserSession -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName

		foreach ($SessionHost in $ListOfSessionHosts) {
			$SessionHostName = $SessionHost.Name.Split('/')[1] 
			$VMName = $SessionHostName.Split(".")[0]

			# Check if VM is in maintenance
			$RoleInstance = Get-AzVM -Status -Name $VMName
			if ($RoleInstance.Tags.Keys -contains $MaintenanceTagName) {
				Write-Output "Session host is in maintenance: $VMName, so script will skip this VM"
				$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Session host is in maintenance: $VMName, so script will skip this VM" }
				Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
				$SkipSessionhosts += $SessionHost
				continue
			}
			#$AllSessionHosts = Compare-Object $ListOfSessionHosts $SkipSessionhosts | Where-Object { $_.SideIndicator -eq '<=' } | ForEach-Object { $_.InputObject }
            $AllSessionHosts = $ListOfSessionHosts | Where-Object { $SkipSessionhosts -notcontains $_ }
			Write-Output "Checking session host: $($SessionHost.Name | Out-String)  of sessions: $($SessionHost.Session) and status: $($SessionHost.Status)"
			$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Checking session host: $($SessionHost.SessionHostName | Out-String)  of sessions:$($SessionHost.Sessions) and status:$($SessionHost.Status)" }
			Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference

			if ($SessionHostName.ToLower().Contains($RoleInstance.Name.ToLower())) {
				# Check if the Azure vm is running       
				if ($RoleInstance.PowerState -eq "VM running") {
					[int]$NumberOfRunningHost = [int]$NumberOfRunningHost + 1
					# Calculate available capacity of sessions						
					$RoleSize = Get-AzVMSize -Location $RoleInstance.Location | Where-Object { $_.Name -eq $RoleInstance.HardwareProfile.VmSize }
					$AvailableSessionCapacity = $AvailableSessionCapacity + $RoleSize.NumberOfCores * $SessionThresholdPerCPU
					[int]$TotalRunningCores = [int]$TotalRunningCores + $RoleSize.NumberOfCores
				}

			}

		}
		Write-Output "Current number of running hosts:$NumberOfRunningHost"
		$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Current number of running hosts:$NumberOfRunningHost" }
		Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
		if ($NumberOfRunningHost -lt $MinimumNumberOfRDSH) {

			Write-Output "Current number of running session hosts is less than minimum requirements, start session host ..."
			$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Current number of running session hosts is less than minimum requirements, start session host ..." }
			Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
			foreach ($SessionHost in $AllSessionHosts) {
				#Write-Output "session host: $($SessionHost)"
				# Check whether the number of running VMs meets the minimum or not
				$SessionHostName = $SessionHost.Name.Split('/')[1]
				if ($NumberOfRunningHost -lt $MinimumNumberOfRDSH) {
					$VMName = $SessionHostName.Split(".")[0]
					$RoleInstance = Get-AzVM -Status -Name $VMName
					if ($SessionHostName.ToLower().Contains($RoleInstance.Name.ToLower())) {
						# Check if the Azure VM is running and if the session host is healthy
						$SessionHostInfo = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName -Name $SessionHostName
						if ($RoleInstance.PowerState -ne "VM running" -and $SessionHostInfo.UpdateState -eq "Succeeded") {
							# Check if the session host is allowing new connections
							Check-ForAllowNewConnections -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName -SessionHostName $SessionHostName
							# Start the Az VM
							Write-Output "Starting Azure VM: $VMName and waiting for it to complete ..."
							$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Starting Azure VM: $VMName and waiting for it to complete ..." }
							Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
							Start-SessionHost -VMName $VMName -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -TimeDifference $TimeDifference

							# Wait for the VM to Start
							$IsVMStarted = $false
							while (!$IsVMStarted) {
								$RoleInstance = Get-AzVM -Status -Name $VMName
								if ($RoleInstance.PowerState -eq "VM running") {
									$IsVMStarted = $true
									Write-Output "Azure VM has been started: $($RoleInstance.Name) ..."
									$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Azure VM has been started: $($RoleInstance.Name) ..." }
									Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
								}
							}
							# Wait for the VM to start
							$SessionHostIsAvailable = Check-IfSessionHostIsAvailable -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName -SessionHostName $SessionHostName
							if ($SessionHostIsAvailable) {
								Write-Output "'$SessionHostName' session host status is 'Available'"
								$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "'$SessionHostName' session host status is 'Available'" }
								Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
							}
							else {
								Write-Output "'$SessionHostName' session host does not configured properly with deployagent or does not started properly"
								$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "'$SessionHostName' session host does not configured properly with deployagent or does not started properly" }
								Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
							}
							# Calculate available capacity of sessions
							$RoleSize = Get-AzVMSize -Location $RoleInstance.Location | Where-Object { $_.Name -eq $RoleInstance.HardwareProfile.VmSize }
							$AvailableSessionCapacity = $AvailableSessionCapacity + $RoleSize.NumberOfCores * $SessionThresholdPerCPU
							[int]$NumberOfRunningHost = [int]$NumberOfRunningHost + 1
							[int]$TotalRunningCores = [int]$TotalRunningCores + $RoleSize.NumberOfCores
							if ($NumberOfRunningHost -ge $MinimumNumberOfRDSH) {
								break;
							}
						}
					}
				}
			}
		}
		else {
			#check if the available capacity meets the number of sessions or not
			Write-Output "Current total number of user sessions: $(($HostPoolUserSessions).Count)"
			$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Current total number of user sessions: $(($HostPoolUserSessions).Count)" }
			Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
			Write-Output "Current available session capacity is: $AvailableSessionCapacity"
			$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Current available session capacity is: $AvailableSessionCapacity" }
			Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
			if ($HostPoolUserSessions.Count -ge $AvailableSessionCapacity) {
				Write-Output "Current available session capacity is less than demanded user sessions, starting session host"
				$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Current available session capacity is less than demanded user sessions, starting session host" }
				Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
				# Running out of capacity, we need to start more VMs if there are any 
				$AllSessionHosts = $ListOfSessionHosts | Where-Object { $SkipSessionhosts -notcontains $_ }
				foreach ($SessionHost in $AllSessionHosts) {
					#Write-Output "session host: $SessionHost"
					$SessionHostName = $SessionHost.Name.Split('/')[1]
					if ($HostPoolUserSessions.Count -ge $AvailableSessionCapacity) {
						$VMName = $SessionHostName.Split(".")[0]
						$RoleInstance = Get-AzVM -Status -Name $VMName

						if ($SessionHostName.ToLower().Contains($RoleInstance.Name.ToLower())) {
							# Check if the Azure VM is running and if the session host is healthy
							$SessionHostInfo = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName -Name $SessionHostName
							if ($RoleInstance.PowerState -ne "VM running" -and $SessionHostInfo.UpdateState -eq "Succeeded") {
								# Validating session host is allowing new connections
								Check-ForAllowNewConnections -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName -SessionHostName $SessionHostName
								# Start the Az VM
								Write-Output "Starting Azure VM: $VMName and waiting for it to complete ..."
								$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Starting Azure VM: $VMName and waiting for it to complete ..." }
								Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
								Start-SessionHost -VMName $VMName -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -TimeDifference $TimeDifference
								# Wait for the VM to Start
								$IsVMStarted = $false
								while (!$IsVMStarted) {
									$RoleInstance = Get-AzVM -Status -Name $VMName
									if ($RoleInstance.PowerState -eq "VM running") {
										$IsVMStarted = $true
										Write-Output "Azure VM has been Started: $($RoleInstance.Name) ..."
										$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Azure VM has been started: $($RoleInstance.Name) ..." }
										Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
									}
								}
								$SessionHostIsAvailable = Check-IfSessionHostIsAvailable -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName -SessionHostName $SessionHostName
								if ($SessionHostIsAvailable) {
									Write-Output "'$SessionHostName' session host status is 'Available'"
									$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "'$SessionHostName' session host status is 'Available'" }
									Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
								}
								else {
									Write-Output "'$SessionHostName' session host does not configured properly with deployagent or does not started properly"
									$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "'$SessionHostName' session host does not configured properly with deployagent or does not started properly" }
									Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
								}
								# Calculate available capacity of sessions
								$RoleSize = Get-AzVMSize -Location $RoleInstance.Location | Where-Object { $_.Name -eq $RoleInstance.HardwareProfile.VmSize }
								$AvailableSessionCapacity = $AvailableSessionCapacity + $RoleSize.NumberOfCores * $SessionThresholdPerCPU
								[int]$NumberOfRunningHost = [int]$NumberOfRunningHost + 1
								[int]$TotalRunningCores = [int]$TotalRunningCores + $RoleSize.NumberOfCores
								Write-Output "New available session capacity is: $AvailableSessionCapacity"
								$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "New available session capacity is: $AvailableSessionCapacity" }
								Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
								if ($AvailableSessionCapacity -gt $HostPoolUserSessions.Count) {
									break
								}
							}
							#Break # break out of the inner foreach loop once a match is found and checked
						}
					}
				}
			}
		}
	}
	else {
		Write-Output "It is Off-peak hours"
		$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "It is Off-peak hours" }
		Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
		Write-Output "Starting to scale down WVD session hosts ..."
		$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Starting to scale down WVD session hosts ..." }
		Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
		Write-Output "Processing hostpool $($HostpoolName)"
		$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Processing hostpool $($HostpoolName)" }
		Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
		# Check the number of running session hosts
		[int]$NumberOfRunningHost = 0
		# Total number of running cores
		[int]$TotalRunningCores = 0
		#Initialize variable for to skip the session host which is in maintenance.
		$SkipSessionhosts = 0
		$SkipSessionhosts = @()
		# Check if minimum number of rdsh vm's are running in off peak hours
		$CheckMinimumNumberOfRDShIsRunning = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName | Where-Object { $_.Status -eq "Available" -or $_.Status -eq 'NeedsAssistance' }
		$ListOfSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName
		if ($CheckMinimumNumberOfRDShIsRunning -eq $null -or ($CheckMinimumNumberOfRDShIsRunning).count -lt $MinimumNumberOfRDSH) {
			foreach ($SessionHost in $ListOfSessionHosts) {
				if ($NumberOfRunningHost -lt $MinimumNumberOfRDSH) {
					$SessionHostName = $SessionHost.Name.Split("/")[1]
					$VMName = $SessionHostName.Split(".")[0]
					$RoleInstance = Get-AzVM -Status -Name $VMName
					# Check the session host is in maintenance
					if ($RoleInstance.Tags.Keys -contains $MaintenanceTagName) {
						continue
					}
					# Check if the session host is allowing new connections
					Check-ForAllowNewConnections -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName -SessionHostName $SessionHostName
                    Write-Output "Starting Azure VM: $VMName and waiting for it to complete ..."
                    $LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Starting Azure VM: $VMName and waiting for it to complete ..." }
		            Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
					Start-SessionHost -VMName $VMName
					# Wait for the VM to Start
					$IsVMStarted = $false
					while (!$IsVMStarted) {
						$RoleInstance = Get-AzVM -Status -Name $VMName
						if ($RoleInstance.PowerState -eq "VM running") {
							$IsVMStarted = $true
							Write-Output "Azure VM has been Started: $($RoleInstance.Name) ..."
                            $LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Azure VM has been Started: $($RoleInstance.Name) ..." }
						    Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference			   
						}
					}
					# Check if session host is available
					$SessionHostIsAvailable = Check-IfSessionHostIsAvailable -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName -SessionHostName $SessionHostName
					if ($SessionHostIsAvailable) {
						Write-Output "'$SessionHostName' session host status is 'Available'"
						$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "'$SessionHostName' session host status is 'Available'" }
						Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
					}
					else {
						Write-Output "'$SessionHost' session host does not configured properly with deployagent or does not started properly"
						$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "'$SessionHostName' session host does not configured properly with deployagent or does not started properly" }
						Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
					}
					[int]$NumberOfRunningHost = [int]$NumberOfRunningHost + 1
					if ($NumberOfRunningHost -ge $MinimumNumberOfRDSH) {
						break;
					}
				}
			}
		}
		$ListOfSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName | Sort-Object Session
		$NumberOfRunningHost = 0
		foreach ($SessionHost in $ListOfSessionHosts) {
			$SessionHostName = $SessionHost.Name.Split('/')[1]
			$VMName = $SessionHostName.Split(".")[0]
			$RoleInstance = Get-AzVM -Status -Name $VMName
			# Check the session host is in maintenance
			if ($RoleInstance.Tags.Keys -contains $MaintenanceTagName) {
				Write-Output "Session host is in maintenance: $VMName, so script will skip this VM"
				$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Session host is in maintenance: $VMName, so script will skip this VM" }
				Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
				$SkipSessionhosts += $SessionHost
				continue
			}
			# Maintenance VMs skipped and stored into a variable
			$AllSessionHosts = $ListOfSessionHosts | Where-Object { $SkipSessionhosts -notcontains $_ }		
			if ($SessionHostName.ToLower().Contains($RoleInstance.Name.ToLower())) {
				# Check if the Azure VM is running
				if ($RoleInstance.PowerState -eq "VM running") {
					Write-Output "Checking session host: $($SessionHost.Name | Out-String)  of sessions: $($SessionHost.Session) and status: $($SessionHost.Status)"
					$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Checking session host: $($SessionHost.Name | Out-String)  of sessions:$($SessionHost.Session) and status:$($SessionHost.Status)" }
					Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
					[int]$NumberOfRunningHost = [int]$NumberOfRunningHost + 1
					# Calculate available capacity of sessions  
					$RoleSize = Get-AzVMSize -Location $RoleInstance.Location | Where-Object { $_.Name -eq $RoleInstance.HardwareProfile.VmSize }
					[int]$TotalRunningCores = [int]$TotalRunningCores + $RoleSize.NumberOfCores
				}
			}
		}
		# Defined minimum no of rdsh value from Webhook Data
		[int]$DefinedMinimumNumberOfRDSH = [int]$MinimumNumberOfRDSH
		## Check and Collecting dynamically stored MinimumNoOfRDSH Value																 
		$AutomationAccount = Get-AzAutomationAccount -ErrorAction Stop | Where-Object { $_.AutomationAccountName -eq $AutomationAccountName }
		$OffPeakUsageMinimumNoOfRDSH = Get-AzAutomationVariable -Name "$HostpoolName-OffPeakUsage-MinimumNoOfRDSH" -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName -ErrorAction SilentlyContinue
		if ($OffPeakUsageMinimumNoOfRDSH) {
			[int]$MinimumNumberOfRDSH = $OffPeakUsageMinimumNoOfRDSH.Value
			if ($MinimumNumberOfRDSH -lt $DefinedMinimumNumberOfRDSH) {
				Write-Output "Don't enter the value of '$HostpoolName-OffPeakUsage-MinimumNoOfRDSH' manually, which is dynamically stored value by script. You have entered manually, so script will stop now."
				$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Don't enter the value of '$HostpoolName-OffPeakUsage-MinimumNoOfRDSH' manually, which is dynamically stored value by script. You have entered manually, so script will stop now." }
				Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
				exit
			}
		}
		# Breadth first session hosts shutdown in off peak hours
		write-output "number of running hosts : $NumberOfRunningHost , minimum required hosts : $MinimumNumberOfRDSH"
		if ($NumberOfRunningHost -gt $MinimumNumberOfRDSH) {
			foreach ($SessionHost in $AllSessionHosts) {
				#Check the status of the session host
				$SessionHostName = $SessionHost.Name.Split('/')[1]						
				$VMName = $SessionHostName.Split(".")[0]	
				if ($SessionHost.Status -ne "NoHeartbeat" -and $SessionHost.Status -ne "Unavailable") {
					if ($NumberOfRunningHost -gt $MinimumNumberOfRDSH) {																	
						if ($SessionHost.Session -eq 0) {
							# Shutdown the Azure VM, which session host have 0 sessions
							Write-Output "Stopping Azure VM: $VMName and waiting for it to complete ..."
							$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Stopping Azure VM: $VMName and waiting for it to complete ..." }
							Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
							Stop-SessionHost -VMName $VMName -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -TimeDifference $TimeDifference
						}
						else {
                            # Check if limitsecondsforcelogoffuser equals to zero
                            if ($LimitSecondsToForceLogOffUser -eq 0) {
								continue
							}
							# Ensure the running Azure VM is set as drain mode
							try {
							$KeepDrianMode = Update-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName -Name $SessionHostName -AllowNewSession:$false -ErrorAction Stop	
							Write-Output " Drain mode set: $($KeepDrainMode)"							
							}
							catch {
								Write-Output "Unable to set it to not allow connections on session host: $SessionHostName with error: $($_.exception.message)"
								$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Unable to set it to not allow connections on session host: $($SessionHost.SessionHost) with error: $($_.exception.message)" }
								Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
								exit
							}							
							# Notify user to log off session
							# Get the user sessions in the hostpool
							try {
								$HostPoolUserSessions = Get-AzWvdUserSession -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName | Where-Object { $_.Name.Contains($SessionHostName) }

							}
							catch {
								Write-Output "Failed to retrieve user sessions in hostpool: $($HostpoolName) with error: $($_.exception.message)"
								$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Failed to retrieve user sessions in hostpool: $($HostpoolName) with error: $($_.exception.message)" }
								Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
								exit
							}
							$HostUserSessionCount = ($HostPoolUserSessions | Where-Object -FilterScript { $_.Name.Contains($SessionHostName) }).Count
							Write-Output "Counting the current sessions on the host $SessionHostName :$HostUserSessionCount"
							$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Counting the current sessions on the host $SessionHostName :$HostUserSessionCount" }
							Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
							$ExistingSession = 0
							foreach ($session in $HostPoolUserSessions) {
								if ($session.Name.Contains($SessionHostName) -and $session.SessionState -eq "Active") {
									#if ($LimitSecondsToForceLogOffUser -ne 0) {
									# Send notification
									try {
										Send-AzWvdUserSessionMessage -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName -SessionHostName $SessionHostName -UserSessionId $session.Id.Split('/')[-1] -MessageTitle $LogOffMessageTitle -MessageBody "$($LogOffMessageBody) You will be logged off in $($LimitSecondsToForceLogOffUser) seconds." -ErrorAction Stop
									}
									catch {
										Write-Output "Failed to send message to user with error: $($_.exception.message)"
										$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Failed to send message to user with error: $($_.exception.message)" }
										Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
										exit
									}
									Write-Output "Script was sent a log off message to user: $($Session.activeDirectoryUserName)"
									$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Script was sent a log off message to user: $($Session.ActiveDirectoryUserName)" }
									#Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
									#}
								}
								$ExistingSession = $ExistingSession + 1
							}
							# Wait for n seconds to log off user
							Start-Sleep -Seconds $LimitSecondsToForceLogOffUser

							#if ($LimitSecondsToForceLogOffUser -ne 0) {
							# Force users to log off
							Write-Output "Force users to log off ..."
							$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Force users to log off ..." }
							Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
							foreach ($Session in $HostPoolUserSessions) {
								
								if ($Session.Name.Contains($SessionHostName)) {
									#Log off user
									
									try {
									
										Remove-AzWvdUserSession -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName -SessionHostName $Session.Name.Split('/')[1] -Id $Session.Id.Split('/')[-1]  -Force -ErrorAction Stop
										$ExistingSession = $ExistingSession - 1
									}
									catch {
										Write-Output "Failed to log off user with error: $($_.exception.message)"
										$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Failed to log off user with error: $($_.exception.message)" }
										Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
										exit
									}
									Write-Output "Forcibly logged off the user: $($Session.ActiveDirectoryUserName)"
									
									$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Forcibly logged off the user: $($Session.ActiveDirectoryUserName)" }	
									#Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
								}
							}
							# Check the session count before shutting down the VM
							if ($ExistingSession -eq 0) {
								# Shutdown the Azure VM
								Write-Output "Stopping Azure VM: $VMName and waiting for it to complete ..."
								$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Stopping Azure VM: $VMName and waiting for it to complete ..." }
								Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
								Stop-SessionHost -VMName $VMName -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -TimeDifference $TimeDifference
							}
						}
						if ($LimitSecondsToForceLogOffUser -ne 0 -or $SessionHost.Session -eq 0) {
							#wait for the VM to stop
							Write-Output "Waiting for VM: $VMName to stop ..."
                            $LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Waiting for VM: $VMName to stop ..." }
							Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference  
							$IsVMStopped = $false
							while (!$IsVMStopped) {
								$RoleInstance = Get-AzVM -Status -Name $VMName
								if ($RoleInstance.PowerState -eq "VM deallocated") {
									$IsVMStopped = $true
									Write-Output "Azure VM has been stopped: $($RoleInstance.Name) ..."
									$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Azure VM has been stopped: $($RoleInstance.Name) ..." }
									Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
								}
							}
							# Check if the session host status is NoHeartbeat or Unavailable
							Write-Output "Waiting for session host: $SessionHostName to be unavailable ..."
                            $LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Waiting for session host: $SessionHostName to be unavailable ..." }
							Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference			  
							$IsSessionHostNoHeartbeat = $false
							while (!$IsSessionHostNoHeartbeat) {
								$SessionHostInfo = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName -Name $SessionHostName
								if ($SessionHostInfo.UpdateState -eq "Succeeded" -and ($SessionHostInfo.Status -eq "Unavailable" -or $SessionHostInfo.Status -eq "NoHeartbeat")) {
									$IsSessionHostNoHeartbeat = $true
									# Ensure the Azure VMs that are off have allow new connections mode set to True
									if ($SessionHostInfo.AllowNewSession -eq $false) {
										write-output "a rg :  $ResourceGroupName hp: $HostpoolName sh : $SessionHostName"
										Check-ForAllowNewConnections -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName -SessionHostName $SessionHostName
									}
								}
							}
						}
						$RoleSize = Get-AzVMSize -Location $RoleInstance.Location | Where-Object { $_.Name -eq $RoleInstance.HardwareProfile.VmSize }
						#decrement number of running session host
						if ($LimitSecondsToForceLogOffUser -ne 0 -or $SessionHost.Sessions -eq 0) {
							[int]$NumberOfRunningHost = [int]$NumberOfRunningHost - 1
							[int]$TotalRunningCores = [int]$TotalRunningCores - $RoleSize.NumberOfCores
						}
					}
				}
			}
		}

		$AutomationAccount = Get-AzAutomationAccount -ErrorAction Stop | Where-Object { $_.AutomationAccountName -eq $AutomationAccountName }
		$OffPeakUsageMinimumNoOfRDSH = Get-AzAutomationVariable -Name "$HostpoolName-OffPeakUsage-MinimumNoOfRDSH" -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName -ErrorAction SilentlyContinue
		if ($OffPeakUsageMinimumNoOfRDSH) {
			[int]$MinimumNumberOfRDSH = $OffPeakUsageMinimumNoOfRDSH.Value
			$NoConnectionsofhost = 0
			if ($NumberOfRunningHost -le $MinimumNumberOfRDSH) {
				foreach ($SessionHost in $AllSessionHosts) {
					if (($SessionHost.Status -eq "Available" -or $SessionHost.Status -eq 'NeedsAssistance') -and $SessionHost.Session -eq 0) {
						$NoConnectionsofhost = $NoConnectionsofhost + 1
					}
				}
				$NoConnectionsofhost = $NoConnectionsofhost - $DefinedMinimumNumberOfRDSH
				if ($NoConnectionsofhost -gt $DefinedMinimumNumberOfRDSH) {
					[int]$MinimumNumberOfRDSH = [int]$MinimumNumberOfRDSH - $NoConnectionsofhost
					Set-AzAutomationVariable -Name "$HostpoolName-OffPeakUsage-MinimumNoOfRDSH" -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName -Encrypted $false -Value $MinimumNumberOfRDSH
				}
			}
		}
		$HostpoolMaxSessionLimit = $HostpoolInfo.MaxSessionLimit
		$HostpoolSessionCount = (Get-AzWvdUserSession -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName).Count
		if ($HostpoolSessionCount -ne 0)
		{
			# Calculate the how many sessions will allow in minimum number of RDSH VMs in off peak hours and calculate TotalAllowSessions Scale Factor
			$TotalAllowSessionsInOffPeak = [int]$MinimumNumberOfRDSH * $HostpoolMaxSessionLimit
			$SessionsScaleFactor = $TotalAllowSessionsInOffPeak * 0.90
			$ScaleFactor = [math]::Floor($SessionsScaleFactor)
			Write-Output "session count : $HostpoolSessionCount Total allow : $TotalAllowSessionsInOffPeak  factor : $SessionsScaleFactor factor2 : $ScaleFactor"

			if ($HostpoolSessionCount -ge $ScaleFactor) {
				$ListOfSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName | Where-Object { $_.Status -eq "NoHeartbeat" -or $_.Status -eq "Unavailable"}
				$AllSessionHosts = $ListOfSessionHosts | Where-Object { $SkipSessionhosts -notcontains $_.Name }
				foreach ($SessionHost in $AllSessionHosts) {
					# Check the session host status and if the session host is healthy before starting the host
					if ($SessionHost.UpdateState -eq "Succeeded") {
						Write-Output "Existing sessionhost sessions value reached near by hostpool maximumsession limit need to start the session host"
						$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Existing sessionhost sessions value reached near by hostpool maximumsession limit need to start the session host" }
						Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
						Write-Output "3"
						$SessionHostName = $SessionHost.Name.Split('/')[1]
						Write-Output "4: $SessionHostName"
						$VMName = $SessionHostName.Split(".")[0]
						Write-Output "5: $VMName"
						# Validating session host is allowing new connections
						Write-Output "1"
						try {
							Check-ForAllowNewConnections -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName -SessionHostName $SessionHostName
						}
						catch{
							Write-Output "exception when checking for allow new connections : $($_.exception.message)"
						}
						
						Write-Output "2"
						# Start the Az VM
						Write-Output "Starting Azure VM: $VMName and waiting for it to complete ..."
						$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Starting Azure VM: $VMName and waiting for it to complete ..." }
						Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
						Start-SessionHost -VMName $VMName -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -TimeDifference $TimeDifference
						#Wait for the VM to start
						$IsVMStarted = $false
						while (!$IsVMStarted) {
							$RoleInstance = Get-AzVM -Status -Name $VMName
							if ($RoleInstance.PowerState -eq "VM running") {
								$IsVMStarted = $true
								Write-Output "Azure VM has been Started: $($RoleInstance.Name) ..."
								$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "Azure VM has been started: $($RoleInstance.Name) ..." }
								Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
							}
						}

						# Wait for the sessionhost is available
						$SessionHostIsAvailable = Check-IfSessionHostIsAvailable -ResourceGroupName $ResourceGroupName -HostPoolName $HostpoolName -SessionHostName $SessionHostName
						if ($SessionHostIsAvailable) {
							Write-Output "$($SessionHostName | Out-String) session host status is 'Available'"
							$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "$($SessionHostName | Out-String) session host status is 'Available'" }
							Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
						}
						else {
							Write-Output "'$($SessionHostName | Out-String)' session host does not configured properly with deployagent or does not started properly"
							$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "'$($SessionHostName | Out-String)' session host does not configured properly with deployagent or does not started properly" }
							Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
						}

						# Increment the number of running session host
						[int]$NumberOfRunningHost = [int]$NumberOfRunningHost + 1
						# Increment the number of minimumnumberofrdsh
						[int]$MinimumNumberOfRDSH = [int]$MinimumNumberOfRDSH + 1
						$OffPeakUsageMinimumNoOfRDSH = Get-AzAutomationVariable -Name "$HostpoolName-OffPeakUsage-MinimumNoOfRDSH" -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName -ErrorAction SilentlyContinue
						if ($OffPeakUsageMinimumNoOfRDSH -eq $null) {
							New-AzAutomationVariable -Name "$HostpoolName-OffPeakUsage-MinimumNoOfRDSH" -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName -Encrypted $false -Value $MinimumNumberOfRDSH -Description "Dynamically generated minimumnumber of RDSH value"
						}
						else {
							Set-AzAutomationVariable -Name "$HostpoolName-OffPeakUsage-MinimumNoOfRDSH" -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName -Encrypted $false -Value $MinimumNumberOfRDSH
						}
						# Calculate available capacity of sessions
						$RoleSize = Get-AzVMSize -Location $RoleInstance.Location | Where-Object { $_.Name -eq $RoleInstance.HardwareProfile.VmSize }
						$AvailableSessionCapacity = $TotalAllowSessionsInOffPeak + $HostpoolInfo.MaxSessionLimit
						[int]$TotalRunningCores = [int]$TotalRunningCores + $RoleSize.NumberOfCores
						Write-Output "New available session capacity is: $AvailableSessionCapacity"
						$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "New available session capacity is: $AvailableSessionCapacity" }
						Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
						break
					}
				}
			}

		}
	}

	Write-Output "HostpoolName: $HostpoolName, TotalRunningCores: $TotalRunningCores NumberOfRunningHosts: $NumberOfRunningHost"
	$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "HostpoolName: $HostpoolName, TotalRunningCores: $TotalRunningCores NumberOfRunningHosts: $NumberOfRunningHost" }
	Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference

	Write-Output "End WVD tenant scale optimization."
	$LogMessage = @{ hostpoolName_s = $HostpoolName; logmessage_s = "End WVD tenant scale optimization." }
	Add-LogEntry -LogMessageObj $LogMessage -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType "WVDTenantScale_CL" -TimeDifferenceInHours $TimeDifference
}
# Without Workspace
else {

	Write-Output "Please enter a workspace for logging."
}