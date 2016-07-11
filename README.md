# Bitbucket Server DIY Backup #

Scripts for backing up and restoring Bitbucket data, see https://confluence.atlassian.com/display/BitbucketServer/Using+Bitbucket+Server+DIY+Backup
For AWS DIY backup, see https://confluence.atlassian.com/display/BitbucketServer/Using+Bitbucket+Server+DIY+Backup+in+AWS

## Zero Downtime Backup ##

To enable Zero Downtime Backup, you will need to set the variable 'BACKUP_ZERO_DOWNTIME' to 'true'.
If true, this variable will backup the filesystem and database without locking the application

For more information, see https://confluence.atlassian.com/display/BitbucketServer/Using+Bitbucket+Data+Center+Zero+Downtime+Backup.