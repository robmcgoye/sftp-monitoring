# SFTP File Monitor and Downloader

This PowerShell script connects to an SFTP server, monitors a specified remote directory for new files, downloads them to a local directory, and deletes the remote files after verifying successful downloads. The script also includes logging, error handling, reconnection attempts, and customizable configurations.

## Requirements

- **PowerShell 5.1 or higher**
- **WinSCP**: This script uses the WinSCP .NET assembly for SFTP connections.
  - Download WinSCP from [WinSCP Download](https://winscp.net/eng/download.php) and ensure `WinSCPnet.dll` is accessible to the script.
    - .NET assembly / COM library is also needed
- **PowerShell Credential Manager Module**:
  - Required for secure credential storage and retrieval.
  - Install via PowerShell with:
    ```powershell
    Install-Module -Name CredentialManager
    ```
  
## Configuration

The script reads configuration values from `config.json` in the same directory as the script. Below is an example `config.json` file:

```json
{
    "HostName": "sftp.example.com",
    "RemoteDirectory": "/remote/path/",
    "LocalDirectory": "C:\\local\\path\\",
    "WinSCPDllPath": "C:\\path\\to\\WinSCPnet.dll",
    "CredentialName": "SftpCredential",
    "LogFileSizeLimitMB": 5,
    "MaxLogArchives": 3,
    "Fingerprint": "ssh-rsa 2048 xx:xx:xx:xx...",
    "PollingInterval": 30
}
```
- **HostName**: The SFTP server’s hostname or IP address.
- **RemoteDirectory**: Directory on the SFTP server to monitor.
- **LocalDirectory**: Directory on the local system to download files to.
- **WinSCPDllPath**: Path to the winSCPnet.dll (part of .NET assembly / COM library)
- **CredentialName**: Name of the stored credential in Windows Credential Manager for the SFTP server.
- **LogFileSizeLimitMB**: Maximum size in MB of the log file before archiving.
- **MaxLogArchives**: Number of archived log files to keep before deleting the oldest.
- **Fingerprint**: SFTP server’s fingerprint for security verification.
- **PollingInterval**: Time in seconds between each check for new files on the remote server.

## Script Features
1. **File Monitoring**: Continuously monitors the specified remote directory for new files at intervals defined by ==PollingInterval==.
2. **File Downloading**: Downloads files from the remote directory to the specified local directory. It will try a max of 3 times to download the file with a 10 second delay between each attempt. (However on the next query to the sftp server it will continue to try to get this file until it is downloaded or deleted.) 
3. **Remote Deletion After Verification**:
   - After downloading, waits 2 seconds and checks if the file still exists on the remote server.
   - Deletes the remote file if it exists.
4. **Reconnection Attempts**: If the connection to the SFTP server is lost, the script retries up to a maximum number of 5 attempts.
5. **Logging**: Logs actions and errors to a log file. When the file reaches the size limit, it archives the logs and maintains up to the specified number of archived logs.

## Setting Up Credentials
1. Open PowerShell and run the following command to store credentials in Windows Credential Manager:
  ```powershell
  $credentialName = "SftpCredential" 
  $credential = Get-Credential -Message "Enter your credentials"
  $credential | New-StoredCredential -Target $credentialName -Persist LocalMachine
  ```
2. Set the ==CredentialName== in ==config.json== to match the ==Target== name (e.g., =="SftpCredential"==).

## Running the Script
1. Ensure ==WinSCPnet.dll== is accessible by the script.
2. Place ==config.json== in the same directory as the script.
3. Run the script in PowerShell:
    ```powershell
    .\YourScriptName.ps1
    ```

## Logging and Archiving
- The script creates a log file in the same directory as the script.
- When the log file reaches the size specified in ==LogFileSizeLimitMB==, it archives the current log and creates a new one.
- Only the specified number of archived logs (==MaxLogArchives==) are kept.

## Running as a Windows Service (Optional)
To run this script as a Windows service:

1. Use a tool like NSSM ([Non-Sucking Service Manager](https://nssm.cc/)) to create a service for the PowerShell script.
2. Configure the service with appropriate permissions and startup settings.

## Troubleshooting
- **Unable to connect**: Check if WinSCP is installed correctly and that ==WinSCPnet.dll== is in the expected path.
- **Log file errors**: Ensure the script has write permissions for the log file directory.
- **Credential issues**: Verify that the credential name in ==config.json== matches the stored name in Credential Manager.
- **Finding the SSH Host Key Fingerprint**:
  - To find the SSH host key fingerprint of your SFTP server, you can use the WinSCP GUI:
    1. Open WinSCP and enter your SFTP server details.
    2. When you attempt to connect, WinSCP will prompt you with the server's host key fingerprint.
    3. You can accept the fingerprint, and it will be saved for future connections.
    4. Alternatively, you can obtain the fingerprint using a terminal command, such as:
      ```bash
      ssh-keygen -l -f /etc/ssh/ssh_host_rsa_key.pub

      ```
    5. Copy the displayed fingerprint and add it to your ==config.json== under the Fingerprint key.
---
This script is intended for automated file monitoring and downloading over SFTP with a focus on reliable error handling and file management. Adjust the configuration options as needed for your environment.
