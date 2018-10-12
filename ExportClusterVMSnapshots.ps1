<#
.SYNOPSIS
Backup clustered virtual by exporting snapshots

.DESCRIPTION
This utility will export virtual machine snapshots to a target destination.

The script will delete the oldest folder once a configurable number of subfolders have been created.

This script must be run as an administrator in an elevated session on a cluser node or as cluster scheduled job.

.NOTES
Last Updated:  11/oct/2018
Version     :  1.0
Author      :  Jannik Grube <jann497f@elevcampus.dk>

- While this script may be running on a cluster node, some of the commands used will be running on the owner
  node of the VM to be backed up. This creates a problem when the output should be copied to a network share
  for backup. We can get around this issue by using powershell sessions, "pulling" the data to the host executing the
  script or running the job.

- It is not possible to name the snapshot directory when exporting.
  Therefore, the snapshot is exported locally/to a temp dir and renamed later with a date prefix
  This allows for more than one version at export/backup location

SCHEDULED TASK
To run this script as a ClusteredScheduledTask of type "any node"
see: https://blogs.msdn.microsoft.com/clustering/2012/05/31/how-to-configure-clustered-tasks-with-windows-server-2012/

Commands to register (execute on a cluster node in an elevated prompt):
  $scriptPath = "C:\ClusterStorage\Volume3\TASKS\ExportClusterVMSnapshots.ps1"
  $action = New-ScheduledTaskAction –Execute "PowerShell.exe" -Argument "-ExecutionPolicy Bypass -Noprofile -File $scriptPath"
  $trigger = New-ScheduledTaskTrigger -At 01:23 –Daily
  Register-ClusteredScheduledTask –TaskName BackupClusterVMs –TaskType AnyNode –Action $action –Trigger $trigger
#>

####################
#   VARIABLES
####################

# save current date in filename friendly format
$FileDate = Get-Date -Format FileDate
# prefix of created snapshots
$SnapshotPrefix = "Backup"
$SnapshotName = "$SnapshotPrefix-$FileDate"
# path to backup directory
$ExportDirPath = "\\10.135.74.29\clusterbackup"
# name of the directory to export to
# here: local temporary dir to avoid error when exporting directly to samba (linux) share
# maybe direct export to share on windows server is possible...
$ExportTmpDirPath = "D:/ClusterBackupTmp"
$ExportLogDirPath = "$ExportDirPath\Logs"
# log file - create cluster-local in case network not available, copy to backup location later
$LogDirPath = "C:\ClusterStorage\Volume3\LOGS"
$LogFile = "$LogDirPath\clusterbackup-$FileDate.txt"
# retain x snapshots of each vm - 1 means keep only last backup
$RetainNum = 2
# display verbose messages
$VerbosePreference = "Continue"

####################
#   BODY
####################

#TODO: Need a send-mail function

# measure elapsed time, save to variable for mail
Measure-Command -OutVariable ElapsedTime {

Write-Verbose "Starting snapshot backup of all VMs in cluster..."

# test if we have access to all needed locations, all dirs exist and are writable.
# showstopper if any fail.
Write-Verbose "Testing all locations are accessible..."
$dirs = $LogDirPath, $ExportDirPath, $ExportTmpDirPath, $ExportLogDirPath
$dirs | ForEach-Object {
    Try {
        $dir = $_

        # try to access dir, create if not there
        if (! (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -ErrorAction Stop
        }

        # try to create a file in location
        $testFile = New-Item -ItemType File -Name test.txt -Path $dir -ErrorAction Stop

        # and delete it again
        if ($testFile) {
            Remove-Item $testFile -Force
        }
    }
    Catch {
        Write-Error "Directory $dir is not accessible. Aborting. `
        Error message: $($_.Exception.Message)"

        #TODO: send mail
    }
}

# everything seems ok, let's go!

Start-Transcript -Path $LogFile -Force

# is cluster available and does it have vms?
Try {
    Write-Verbose "Enumerating cluster VMs..."
    # try to get all clustered vms, sort from highest prio to lowest
    $VMs = Get-ClusterGroup -ErrorAction Stop | Where-Object { $_.GroupType –eq 'VirtualMachine' } | Sort-Object Priority -Descending
}
Catch {
    Write-Error "Enumerating cluster VMs failed.`nError message: $($_.Exception.Message)"

    # stop logging and copy logfile to backup location
    Stop-Transcript
    Copy-Item $Logfile "$ExportDirPath\Logs\" -Force

    # TODO: send mail
}

if ($VMs.Count -eq 0) {
    Write-Warning "No VMs found, exiting."
    exit
}

# iterate through vms
foreach ($vm in $VMs) {
    Try {
        # retain some properties
        $vmName = $vm.Name
        $vmOwnerNode = $vm.OwnerNode

        Write-Verbose "--------------------n` Backing up VM $vmName n`--------------------"

        $vm = Get-VM -Name $vmName -ComputerName $vm.OwnerNode -ErrorAction Stop

        $vmExportDirPath = "$ExportDirPath\$vmName"
        # create VM export dir on remote if not exists
        # showstopper, as we need a place to export to.
        if (! (Test-Path $vmExportDirPath)) {
            New-Item -Type Directory -Path $vmExportDirPath -Force -ErrorAction Stop
        }

        # clean up target before
        if (Test-Path "$vmExportDirPath\$FileDate-$vmName") {
            Remove-Item "$vmExportDirPath\$FileDate-$vmName" -Recurse -Force
        }

        # Try to use production checkpoints, fall back to std
        if ($vm.CheckpointType -notmatch "Production") {
            Set-VM $vm -CheckpointType Production -ErrorAction SilentlyContinue
            # check to see if last command failed, fall back to std checkpoints if it did.
            # Showstopper if not possible, as we need some kind of checkpoint to export.
            if (! $?) {
                Set-VM $vm -CheckpointType Standard -ErrorAction Stop
            }
        }

        # create new snapshot/checkpoint
        # showstopper.
        Checkpoint-VM $vm -SnapshotName "$SnapshotName" -ErrorAction Stop -Verbose

        # The next command is automatically run on the OwnerNode of the VM.
        # Remote commands need to be wrapped in Invoke-Command.
        # need a pssesion for this:
        $sourceSession = New-PSSession -ComputerName $vmOwnerNode

        # clear tmp dir on backup/export storage
        # works only if remote has local disk as $ExportTmpDirPath!
        Invoke-Command -Session $sourceSession -ScriptBlock {
            if (Test-Path "$using:ExportTmpDirPath\$using:vmName") {
                Remove-Item "$using:ExportTmpDirPath\$using:vmName" -Recurse -Force
            }
        }
        # export checkpoint to backup location tmp dir.
        # showstopper.
        Export-VMSnapshot $vm -Name "$SnapshotName" -Path "$ExportTmpDirPath" -ErrorAction Stop -Verbose

        # move snapshot from tmp dir and rename with current date
        # not possible to name snapshot dir on export directly
        # cannot instruct remote node to copy to network drive without passing credentials with CredSSP,
        # therefore using copying from PSSession
        Write-Verbose "Copy export of $vmName to $vmExportDirPath..."
        Copy-Item -FromSession $sourceSession -Path "$ExportTmpDirPath\$vmName" "$vmExportDirPath\$vmName-$FileDate" -Recurse -Force

    } Catch {
        # if a stop error occurred at any of the above commands
        # inform of error and continue with next vm
        Write-Error "Error while working on VM $vmName.`nError message: $($_.Exception.Message)"

    } Finally {
        # make sure we don't stop the show by accident in this block
        $myErrorAction = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"

        # clean up temporary storage
        Invoke-Command -Session $sourceSession -ScriptBlock {
            Remove-Item "$Using:ExportTmpDirPath\$Using:vmName" -Force -Recurse
        }
        # close the pssession
        Remove-CimSession $sourceSession

        # clean up checkpoints on the VM (including the current one and automatic ones), don't care if none present
        Get-VMSnapshot $vm | Where-Object { $_.Name -match "$SnapshotPrefix*" } | Remove-VMSnapshot

        # clean up backup dir, retain only $RetainNum Snapshots
        $exportDirs = Get-ChildItem -Path "$ExportDirPath\$vmName" -Directory
        # check if any backup folders
        if ($exportDirs) {
            $exportDirsCount = $exportDirs.count
            # if there are more backups than should be retained, delete them one by one, starting with oldest
            while ($exportDirsCount -gt $RetainNum) {
                #get oldest folder based on its CreationTime property
                $oldestDir = $exportDirs | Sort-Object CreationTime | Select-Object -first 1
                $oldestDir | Remove-Item -Recurse -Force
                # decrement count
                $exportDirsCount--
            }
        }
        # return erroraction to default state
        $ErrorActionPreference = $myErrorAction

    } # /finally

}  # /foreach

} # /measure-command

# stop logging and copy logfile to backup location
Stop-Transcript
Copy-Item $Logfile "$ExportDirPath\Logs\" -Force

# TODO: mail on error
if ($error.Count -gt 0) {
    # send mail, include transcript, output $error
}
