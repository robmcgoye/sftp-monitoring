# Function to handle Ctrl+C signal (SIGINT)
Register-EngineEvent -SourceIdentifier ConsoleCancelEvent -Action {
  Write-Log "Ctrl+C detected. Exiting script..."
  $global:keepRunning = $false
}

# Import the CredentialManager module
Import-Module CredentialManager

# Get script directory and config file path
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configFilePath = Join-Path $scriptDir "Config.json"

# Load configuration from JSON file
$config = Get-Content -Path $configFilePath | ConvertFrom-Json

# Define configuration variables from config file
$hostName = $config.HostName
$remoteDirectory = $config.RemoteDirectory
$localDirectory = $config.LocalDirectory
$winSCPDllPath = $config.WinSCPDllPath
$credentialName = $config.CredentialName
$fingerprint = $config.Fingerprint
$pollingInterval = [int]$config.PollingInterval
$logFileSizeLimitMB = [int]$config.LogFileSizeLimitMB
$maxLogArchives = [int]$config.MaxLogArchives


# Define log file path in the same directory as the script
$logFile = Join-Path $scriptDir "sftp-transfer.log"

function New-Log {
  param (
    [string]$logFilePath
  )  
  # Ensure log file exists and write initial log entry
  if (!(Test-Path -Path $logFilePath)) {
    New-Item -ItemType File -Path $logFilePath -Force | Out-Null
  }
  Add-Content -Path $logFilePath -Value "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss") [Information] Log file created."
}

# Function to log messages to file
function Write-Log {
    param (
        [string]$message,
        [string]$type = "Information"
    )

    # Check file size
    $logFileSize = (Get-Item $logFile).Length
    $fileSizeMB = [math]::Round($logFileSize / 1MB, 2)  # Round to 2 decimal places
    if ($fileSizeMB -ge $logFileSizeLimitMB) {
        Archive-LogFile -logFilePath $logFile -maxArchives $maxLogArchives
    }
    
    # Log to file
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp [$type] $message"
    Add-Content -Path $logFile -Value $logMessage

}

function Archive-LogFile {
  param (
      [string]$logFilePath,
      [int]$maxArchives
  )

  # Get the directory and filename for the log file
  $logDir = Split-Path -Path $logFilePath
  $logFileName = [System.IO.Path]::GetFileNameWithoutExtension($logFilePath)
  $logFileExt = [System.IO.Path]::GetExtension($logFilePath)

  # Create archive filename with timestamp
  $archiveFileName = "${logDir}\${logFileName}_$(Get-Date -Format 'yyyyMMdd_HHmmss')$logFileExt"
  Rename-Item -Path $logFilePath -NewName $archiveFileName
  New-Log -logFilePath $logFilePath

  # Remove oldest archives if necessary
  $archives = Get-ChildItem -Path $logDir -Filter "${logFileName}_*${logFileExt}" | Sort-Object LastWriteTime
  if ($archives.Count -gt $maxArchives) {
      $archivesToDelete = $archives[0..($archives.Count - $maxArchives - 1)]
      foreach ($archive in $archivesToDelete) {
          Remove-Item -Path $archive.FullName -Force
          Write-Host "Deleted old archive: $($archive.FullName)"
      }
  }
}

New-Log -logFilePath $logFile

# Validate that LogFileSizeLimitMB is a positive integer
if ($logFileSizeLimitMB -le 0) {
  Write-Log "Invalid LogFileSizeLimitMB in config. Setting to default of 5 MB."
  $logFileSizeLimitMB = 5
}
if ($maxLogArchives -le 0) {
  Write-Log "Invalid MaxLogArchives in config. Setting to default of 3."
  $maxLogArchives = 3
}

# Check if the module is loaded
if (!(Get-Module -ListAvailable -Name CredentialManager)) {
    Write-Log "Error: CredentialManager module is not installed."
    exit
}

# Validate that PollingInterval is a positive integer
if ($pollingInterval -le 0) {
  Write-Log "Invalid PollingInterval in config. Setting to default of 30 seconds."
  $pollingInterval = 30
}

# Validate paths and files
if (!(Test-Path -Path $winSCPDllPath)) {
    Write-Log "Error: WinSCP DLL not found at path $winSCPDllPath" -type "Error"
    exit
} else {
    Add-Type -Path $winSCPDllPath
    Write-Log "WinSCP DLL found at $winSCPDllPath."
}

if (!(Test-Path -Path $localDirectory)) {
    Write-Log "Warning: Local directory $localDirectory does not exist. Creating it..." -type "Warning"
    New-Item -ItemType Directory -Path $localDirectory -Force | Out-Null
} else {
    Write-Log "Local directory $localDirectory exists."
}
# Ensure LocalDirectory ends with a backslash
if (-not $localDirectory.EndsWith("\")) {
  Write-Log "LocalDirectory path does not end with a backslash. Adding a backslash."
  $localDirectory = $localDirectory + "\"
}

# Check if the credential exists
$credential = Get-StoredCredential -Target $credentialName
if ($null -eq $credential) {
    Write-Log "Error: Credential '$credentialName' not found in Windows Credential Manager." -type "Error"
    exit
}

# Configure SFTP session
$sessionOptions = New-Object WinSCP.SessionOptions
$sessionOptions.Protocol = [WinSCP.Protocol]::Sftp
$sessionOptions.HostName = $hostName
$sessionOptions.UserName = $credential.UserName
$sessionOptions.Password = $credential.GetNetworkCredential().Password
$sessionOptions.SshHostKeyFingerprint = $fingerprint
#
$retryInterval = 10  # Time in seconds to wait before retrying a failed file download
$maxConnectionRetries = 5  # Maximum attempts to reconnect

# Initialize session
$session = New-Object WinSCP.Session

# Function to download a file with retry
function Download-FileWithRetry {
    param (
        [WinSCP.Session]$session,
        [string]$remotePath,
        [string]$remoteFile,
        [string]$localFilePath
    )
    
    $maxFileRetries = 3
    $fileRetryCount = 0
    $remoteFilePath = $remotePath + $remoteFile

    do {
        try {
            # Attempt to download the file
            $session.GetFiles($remoteFilePath, $localFilePath).Check()
            Write-Log "Successfully downloaded file: $($remoteFilePath) to: $($localFilePath)"
            # Wait 2 seconds after download
            Start-Sleep -Seconds 2
            # Check if file still exists on the remote server
            $remoteFilesAfterDownload = $session.ListDirectory($remotePath)
            if ($remoteFilesAfterDownload.Files | Where-Object { $_.Name -eq $remoteFile }) {
              # If the file exists, delete it
              $session.RemoveFiles($remoteFilePath).Check()
              Write-Log "Deleted file from remote server: $($remoteFile)"
            } else {
              Write-Log "File no longer exists on remote server: $($remoteFile)"
            }
            return $true
        } catch {
            # Log the error message and additional details if available
            $errorMessage = $_.Exception.Message           # Get the error message
            $errorCode = $_.Exception.HResult              # Get the error code, if available
            $errorCategory = $_.CategoryInfo.Category      # Get the error category
            $errorTarget = $_.TargetObject                 # Get the target object that caused the error

            Write-Log "An error occurred: $errorMessage"
            Write-Log "Error code: $errorCode"
            Write-Log "Error category: $errorCategory"
            Write-Log "Error target: $errorTarget"
            $fileRetryCount++
            Write-Log "Failed to download file $($remoteFilePath). Attempt $fileRetryCount of $maxFileRetries." -type "Error"
            Start-Sleep -Seconds $retryInterval
        }
    } while ($fileRetryCount -lt $maxFileRetries)

    # If all retries fail, log the error
    Write-Log "Failed to download file $($remoteFilePath) after $maxFileRetries attempts." -type "Error"
    return $false
}

# Main download loop with reconnect logic
$connectionRetries = 0
$keepRunning = $true

while ($keepRunning) {
    try {
    # Connect to the SFTP server
    if (-not $session.Opened) {
      $session.Open($sessionOptions)
      Write-Log "Connected to SFTP server."
    }
    # List files in the remote directory
    $remoteFiles = $session.ListDirectory($remoteDirectory)

    foreach ($fileInfo in $remoteFiles.Files) {
      if (-not $fileInfo.IsDirectory) {
        # Download each file with retry logic
        Download-FileWithRetry -session $session -remotePath $remoteDirectory -remoteFile $fileInfo.Name -localFilePath $localDirectory
      }
    }

    # Reset connection retry counter if successful
    $connectionRetries = 0

    # Wait for a specified interval before checking again
    Start-Sleep -Seconds $pollingInterval  # Adjust the sleep interval as needed

  } catch {
    # Log the error message and additional details if available
    $errorMessage = $_.Exception.Message           # Get the error message
    $errorCode = $_.Exception.HResult              # Get the error code, if available
    $errorCategory = $_.CategoryInfo.Category      # Get the error category
    $errorTarget = $_.TargetObject                 # Get the target object that caused the error

    Write-Log "An error occurred: $errorMessage"
    Write-Log "Error code: $errorCode"
    Write-Log "Error category: $errorCategory"
    Write-Log "Error target: $errorTarget"
    Write-Log "Connection lost. Attempting to reconnect... (Attempt $($connectionRetries+1) of $maxConnectionRetries)" -type "Error"
    $connectionRetries++
    Start-Sleep -Seconds $retryInterval

    # Exit if max reconnection attempts are exceeded
    if ($connectionRetries -ge $maxConnectionRetries) {
      Write-Log "Maximum reconnection attempts reached. Exiting script." -type "Error"
      exit
    }
  }
}
if ($session.Opened) {
  $session.Dispose()
  Write-Log "Disconnected from SFTP server."
}
