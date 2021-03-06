/*
This script will identify gaps in backups and help troubleshoot RPO scores in PDB.
The second result set may help troubleshoot a poor RTO score if there hasn't been a full backup since workspace creation.

Replace all instances of PrimarySqlInstance with the name of the primary SQL instance for your Relativity environment (use Ctrl+F and do a find and replace).

If this script is taking a long time to run, consider adding the following index:

---begin index creation t-sql---
USE [msdb]
GO
CREATE NONCLUSTERED INDEX [DBName_BackupFinish]
ON [dbo].[backupset] ([database_name],[backup_finish_date])

GO
---end index creation t-sql---

The above index typically should not take long to create, and should not take up much disk space.
Environments where backup history has not been cleaned up in a long time may need some history cleanup maintenance.
*/

USE msdb
GO

CREATE TABLE #RelativityDatabases
(
	ID INT IDENTITY(1,1) PRIMARY KEY,
	DatabaseName nvarchar(20)
)

INSERT #RelativityDatabases
SELECT CASE WHEN ArtifactID = -1 THEN 'EDDS' ELSE 'EDDS' + CAST(ArtifactID AS varchar) END FROM [PrimarySqlInstance].EDDS.eddsdbo.[Case]
 
;WITH CTE AS
(
       SELECT
              database_name, [type], backup_start_date, backup_finish_date
       FROM dbo.backupset (nolock)
       WHERE backup_finish_date > DATEADD(dd, -14, getdate())  --go back two weeks to catch gaps that extended into the past week but started earlier
          
          --the next two conditions filter by database name.  the first restricts results to the Relativity case list,
          --but it is possible that gaps could have occurred in the past week and then the workspace deleted.
          --make sure to insert the primary sql server instance name in order to filter on the case list.
          --the second just makes the results database specific.
          
          AND database_name IN (SELECT DatabaseName FROM #RelativityDatabases)
          --AND database_name = 'EDDS1085231'
)
SELECT
       DBName = t1.database_name,
       InitialBackup = t1.backup_finish_date,
       SecondBackup = t2.BackupDate,
    Delta = DateDiff(minute, t1.backup_finish_date, ISNULL(t2.BackupDate, getdate()))
  FROM CTE t1 (nolock)
  OUTER APPLY (
       --Get the earliest backup that follows the first one
       SELECT MIN(backup_finish_date) BackupDate
       FROM CTE t2 (nolock)
       WHERE  t1.database_name = t2.database_name
              AND t2.backup_finish_date > t1.backup_finish_date
) t2
WHERE t2.BackupDate > DATEADD(dd, -7, getdate())
ORDER BY Delta desc, SecondBackup desc  --sort by largest gaps then by most recent.  change as needed.
 

--second result set to show databases without a full backup since workspace creation
--these don't affect RPO scores in PDB because log backups are still allowed due to case creation process that includes a full backup, but are still a concern for true RPO
-- these will affect RTO scores in PDB (estimated recovery time = time since workspace creation)
IF EXISTS(SELECT name FROM sys.databases WHERE create_date > DATEADD(DD, -7, GETDATE()) AND name LIKE 'EDDS%')
SELECT DISTINCT 'EDDS' + CAST(C.[ArtifactID] AS nvarchar) [Databases Without a Full Backup Since Workspace Creation]
      --,C.Name WorkspaceName
  FROM [PrimarySqlInstance].[EDDS].[eddsdbo].[Case] C
  WHERE C.ArtifactID IN
    (
		SELECT C.ArtifactID FROM [PrimarySqlInstance].[EDDS].[eddsdbo].[Case] C WHERE ArtifactID <> -1 AND ServerID = (SELECT ArtifactID FROM [PrimarySqlInstance].[EDDS].[eddsdbo].[ResourceServer] WHERE Name = @@SERVERNAME)
	)

	AND C.ArtifactID NOT IN

	(
		SELECT AR.ArtifactID FROM [PrimarySqlInstance].[EDDS].[eddsdbo].[AuditRecord_PrimaryPartition] AR WHERE [Action] = 9
	) --exclude workspaces that have been deleted

  AND 'EDDS' + CAST(C.[ArtifactID] AS nvarchar) NOT IN --find databases without a full backup
	(
		SELECT database_name FROM msdb.dbo.backupset
		WHERE [type] = 'D'
)

DROP TABLE #RelativityDatabases